use crate::app_server::AppServer;
use crate::model::{
    FailureSource, QuotaSnapshot, RefreshState, Timestamp, UsageSnapshot, instant, local_day,
    unix_seconds,
};
use crate::reconcile::{self, SnapshotInput};
use crate::sessions::{SESSION_DIRECTORIES, SessionIndexer};
use crate::store::Store;
use anyhow::{Context, Result};
use chrono::{Days, Local, TimeZone};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime};

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum RefreshReason {
    Startup,
    Scheduled,
    Opened,
    Wake,
    SessionsChanged,
    Manual,
}

impl RefreshReason {
    fn full(self) -> bool {
        matches!(self, Self::Startup | Self::Wake | Self::Manual)
    }
}

pub struct UsageService {
    store: Store,
    indexer: SessionIndexer,
    server: Option<AppServer>,
    selected_home: Option<PathBuf>,
    profile: PathBuf,
    last_index: Option<Timestamp>,
    next_connect: Timestamp,
    quitting: Arc<AtomicBool>,
}

impl UsageService {
    pub fn open(database: &Path, profile: PathBuf, selected_home: Option<PathBuf>) -> Result<Self> {
        Ok(Self {
            store: Store::open(database)?,
            indexer: SessionIndexer::default(),
            server: None,
            selected_home,
            profile,
            last_index: None,
            next_connect: 0.0,
            quitting: Arc::default(),
        })
    }

    pub fn with_quit_signal(mut self, signal: Arc<AtomicBool>) -> Self {
        self.quitting = signal;
        self
    }

    pub fn valid_selected_home(path: &Path) -> bool {
        path.is_absolute()
            && SESSION_DIRECTORIES
                .iter()
                .any(|directory| path.join(directory).is_dir())
    }

    fn selected_home(&self) -> Option<&Path> {
        self.selected_home
            .as_deref()
            .filter(|path| Self::valid_selected_home(path))
    }

    pub fn codex_home(&self) -> Option<PathBuf> {
        let environment = std::env::var_os("CODEX_HOME").map(PathBuf::from);
        let profile = self.profile.join(".codex");
        [
            self.selected_home(),
            self.server.as_ref().and_then(AppServer::codex_home),
            environment.as_deref(),
            Some(profile.as_path()),
        ]
        .into_iter()
        .flatten()
        .find(|path| path.is_absolute() && path.is_dir())
        .map(Path::to_path_buf)
    }

    pub fn select_home(&mut self, path: PathBuf) -> Result<()> {
        anyhow::ensure!(Self::valid_selected_home(&path), "invalid Codex Home");
        self.selected_home = Some(path);
        self.indexer = SessionIndexer::default();
        self.server = None;
        self.next_connect = 0.0;
        self.last_index = None;
        Ok(())
    }

    pub fn has_server(&self) -> bool {
        self.server.is_some()
    }

    pub fn current(&mut self, now: Timestamp) -> Result<UsageSnapshot> {
        self.snapshot(now, false, false)
    }

    pub fn refresh(
        &mut self,
        reason: RefreshReason,
        now: Timestamp,
        mut publish: impl FnMut(UsageSnapshot),
    ) -> Result<UsageSnapshot> {
        self.ensure_running()?;
        let mut state = self.store.refresh_state()?;
        let prior_count = state.consecutive_failure_count;
        let mut failed = false;
        if self
            .server
            .as_mut()
            .is_some_and(|server| !server.is_running())
        {
            self.server = None;
        }

        let quota = self.store.latest_quota()?;
        let did_reset = quota.as_ref().is_some_and(|value| now >= value.resets_at);
        // 第一轮先展示 SQLite 中的快照，Codex CLI 启动或网络慢时仍可查看数据。
        let mut cutoff = self.history_start(now, quota.as_ref())?;
        let index_due = reason.full()
            || matches!(
                reason,
                RefreshReason::Opened | RefreshReason::SessionsChanged
            )
            || self.last_index.is_none_or(|last| now - last >= 300.0);
        let initially_indexed_home = self.codex_home();
        if index_due && initially_indexed_home.is_some() {
            self.index(&mut state, &mut failed, cutoff, now)?;
        }
        publish(self.snapshot(now, true, false)?);

        if self.server.is_none()
            && reason != RefreshReason::SessionsChanged
            && (reason == RefreshReason::Manual || now >= self.next_connect)
        {
            self.next_connect = now + 60.0;
            let connection =
                AppServer::connect_interruptible(self.selected_home(), self.quitting.clone());
            self.ensure_running()?;
            match connection {
                Ok(server) => {
                    self.server = Some(server);
                    success(&mut state, FailureSource::AccountInitialization, None);
                }
                Err(_) => failure(
                    &mut state,
                    FailureSource::AccountInitialization,
                    &mut failed,
                ),
            }
        }
        if index_due
            && (initially_indexed_home.is_none() || initially_indexed_home != self.codex_home())
        {
            self.index(&mut state, &mut failed, cutoff, now)?;
        }

        let quota_interval = match reason {
            RefreshReason::Opened => 60.0,
            _ if near_boundary(now, quota.as_ref()) => 60.0,
            _ => 300.0,
        };
        let request_quota = reason.full()
            || did_reset
            || (reason != RefreshReason::SessionsChanged
                && due(state.last_successful_quota_refresh_at, now, quota_interval));
        let request_usage = reason.full()
            || (reason != RefreshReason::SessionsChanged
                && due(state.last_successful_official_usage_refresh_at, now, 1800.0));
        if request_quota && let Some(server) = self.server.as_mut() {
            let result = server.read_quota(now);
            self.ensure_running()?;
            match result {
                Ok(Some(quota)) => {
                    self.store.save_quota(&quota)?;
                    success(&mut state, FailureSource::RateLimits, Some(now));
                    let new_cutoff = self.history_start(now, Some(&quota))?;
                    if new_cutoff < cutoff {
                        cutoff = new_cutoff;
                        self.index(&mut state, &mut failed, cutoff, now)?;
                    }
                }
                _ => failure(&mut state, FailureSource::RateLimits, &mut failed),
            }
            self.store.save_refresh_state(&state)?;
            if request_usage {
                publish(self.snapshot(now, true, false)?);
            }
        }
        if request_usage && let Some(server) = self.server.as_mut() {
            let result = server.read_official_days(now);
            self.ensure_running()?;
            match result {
                Ok(result) => {
                    self.store.upsert_official_days(&result.days)?;
                    if result.had_invalid_bucket {
                        failure(&mut state, FailureSource::OfficialUsage, &mut failed);
                    } else {
                        success(&mut state, FailureSource::OfficialUsage, Some(now));
                    }
                }
                Err(_) => failure(&mut state, FailureSource::OfficialUsage, &mut failed),
            }
        }

        state.consecutive_failure_count = if failed {
            prior_count.saturating_add(1)
        } else if state.failed_sources.is_empty() {
            0
        } else {
            prior_count
        };
        self.store.save_refresh_state(&state)?;
        self.snapshot(now, true, true)
    }

    pub fn poll_quota(&mut self, now: Timestamp) -> Result<Option<UsageSnapshot>> {
        self.ensure_running()?;
        let Some(server) = self.server.as_mut() else {
            return Ok(None);
        };
        let quotas = server.quota_notifications();
        self.ensure_running()?;
        let Some(last) = quotas.last() else {
            return Ok(None);
        };
        let mut state = self.store.refresh_state()?;
        for quota in &quotas {
            self.store.save_quota(quota)?;
        }
        success(&mut state, FailureSource::RateLimits, Some(last.fetched_at));
        if state.failed_sources.is_empty() {
            state.consecutive_failure_count = 0;
        }
        self.store.save_refresh_state(&state)?;
        Ok(Some(self.snapshot(now, true, true)?))
    }

    pub fn close(mut self) -> Result<()> {
        if let Some(server) = self.server.as_mut()
            && let Ok(Some(quota)) =
                server.capture_quota(unix_seconds(SystemTime::now()), Duration::from_secs(3))
        {
            self.store.save_quota(&quota)?;
        }
        self.server = None;
        self.store.checkpoint()
    }

    fn index(
        &mut self,
        state: &mut RefreshState,
        failed: &mut bool,
        cutoff: Timestamp,
        now: Timestamp,
    ) -> Result<()> {
        self.last_index = Some(now);
        let result = self
            .codex_home()
            .context("Codex Home unavailable")
            .and_then(|home| {
                self.indexer
                    .index(&home, cutoff, &Local, &mut self.store, &self.quitting)
            });
        self.ensure_running()?;
        match result {
            Ok(_) => success(state, FailureSource::SessionIndexing, None),
            Err(error) if error.downcast_ref::<rusqlite::Error>().is_some() => return Err(error),
            Err(_) => failure(state, FailureSource::SessionIndexing, failed),
        }
        Ok(())
    }

    fn ensure_running(&self) -> Result<()> {
        anyhow::ensure!(
            !self.quitting.load(Ordering::Acquire),
            "Codex Usage is exiting"
        );
        Ok(())
    }

    fn history_start(&self, now: Timestamp, quota: Option<&QuotaSnapshot>) -> Result<Timestamp> {
        let local = instant(now).context("invalid clock")?.with_timezone(&Local);
        let start = local
            .checked_sub_days(Days::new(56))
            .map_or(now - 56.0 * 86_400.0, |time| {
                time.timestamp_millis() as Timestamp / 1000.0
            });
        let quota_start = quota
            .filter(|q| (9000..=11000).contains(&q.window_duration_minutes))
            .map_or(start, |q| {
                q.starts_at - 8.0 * q.window_duration_minutes as Timestamp * 60.0
            });
        let oldest = self
            .store
            .cycles()?
            .first()
            .map_or(start, |cycle| cycle.starts_at);
        Ok(start.min(quota_start).min(oldest))
    }

    fn snapshot(
        &mut self,
        now: Timestamp,
        update_cycles: bool,
        persist: bool,
    ) -> Result<UsageSnapshot> {
        let quota = self.store.latest_quota()?;
        let start = self.history_start(now, quota.as_ref())?;
        let events = self.store.events(start, now.next_up())?;
        let official_days = self.store.official_days()?;
        let mut cycles = self.store.cycles()?;
        let history = match &quota {
            Some(quota) => self.store.quota_history(start, now, &quota.limit_id)?,
            None => Vec::new(),
        };
        if update_cycles && let Some(quota) = &quota {
            cycles = reconcile::update_cycles(&cycles, quota, &events, &history);
            if persist {
                self.store.replace_cycles(&cycles)?;
                if cycles.len() == 9 {
                    let recent_day = local_day(now, &Local)
                        .context("invalid local date")?
                        .checked_sub_days(Days::new(6))
                        .context("invalid retention date")?;
                    let recent_start = Local
                        .from_local_datetime(&recent_day.and_hms_opt(0, 0, 0).unwrap())
                        .earliest()
                        .map_or(now - 6.0 * 86_400.0, |time| time.timestamp() as Timestamp);
                    let cutoff = cycles[0].starts_at.min(recent_start);
                    self.store.prune_usage(
                        cutoff,
                        local_day(cutoff, &Local).context("invalid retention date")?,
                    )?;
                }
            }
        }

        let last_updated_at = quota
            .iter()
            .map(|quota| quota.fetched_at)
            .chain(events.iter().map(|event| event.occurred_at))
            .chain(official_days.iter().map(|day| day.fetched_at))
            .max_by(Timestamp::total_cmp)
            .unwrap_or(now);
        let state = self.store.refresh_state()?;
        Ok(reconcile::snapshot(
            SnapshotInput {
                now,
                quota: quota.as_ref(),
                events: &events,
                official_days: &official_days,
                cycles: &cycles,
                last_updated_at,
                quota_history: &history,
                failed_sources: &state.failed_sources,
            },
            &Local,
        ))
    }
}

fn due(last: Option<Timestamp>, now: Timestamp, interval: Timestamp) -> bool {
    last.is_none_or(|last| now - last >= interval)
}

fn near_boundary(now: Timestamp, quota: Option<&QuotaSnapshot>) -> bool {
    use chrono::Timelike;
    if instant(now).is_some_and(|time| {
        let seconds = time.with_timezone(&Local).num_seconds_from_midnight();
        !(600..85_800).contains(&seconds)
    }) {
        return true;
    }
    quota.is_some_and(|quota| (0.0..=600.0).contains(&(quota.resets_at - now)))
}

fn failure(state: &mut RefreshState, source: FailureSource, failed: &mut bool) {
    state.failed_sources.insert(source);
    *failed = true;
}

fn success(state: &mut RefreshState, source: FailureSource, time: Option<Timestamp>) {
    state.failed_sources.remove(&source);
    if let Some(time) = time {
        match source {
            FailureSource::RateLimits => state.last_successful_quota_refresh_at = Some(time),
            FailureSource::OfficialUsage => {
                state.last_successful_official_usage_refresh_at = Some(time)
            }
            _ => (),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn missing_saved_home_is_not_passed_to_codex() -> Result<()> {
        let root = tempfile::tempdir()?;
        let selected = root.path().join("selected");
        fs::create_dir_all(selected.join("sessions"))?;
        let service = UsageService::open(
            &root.path().join("usage.sqlite"),
            root.path().to_path_buf(),
            Some(selected.clone()),
        )?;
        assert_eq!(service.selected_home(), Some(selected.as_path()));
        fs::rename(&selected, root.path().join("moved"))?;
        assert_eq!(service.selected_home(), None);
        Ok(())
    }
}
