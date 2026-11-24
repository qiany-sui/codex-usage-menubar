use std::path::Path;

use anyhow::{Context, Result, ensure};
use chrono::{Datelike, NaiveDate};
use rusqlite::{Connection, Row, TransactionBehavior, params};

use crate::model::{
    FailureSource, FileCursor, OfficialUsageDay, QuotaCycle, QuotaReading, QuotaSnapshot,
    RefreshState, Status, StoredUsageEvent, Timestamp, TokenBreakdown,
};
use crate::reconcile::reconciled_session_quota_history;

const SCHEMA_VERSION: i64 = 3;
const SWIFT_DISTANT_FUTURE: Timestamp = 64_092_211_200.0;
const FAILURE_SOURCES: [FailureSource; 4] = [
    FailureSource::AccountInitialization,
    FailureSource::RateLimits,
    FailureSource::OfficialUsage,
    FailureSource::SessionIndexing,
];

pub struct Store {
    connection: Connection,
}

impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        let connection = Connection::open(path).context("open database")?;
        schema_version(&connection)?;
        connection
            .execute_batch(
                "PRAGMA foreign_keys = ON;
             PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;",
            )
            .context("configure database")?;
        let mut store = Self { connection };
        store.migrate().context("migrate schema")?;
        Ok(store)
    }

    fn migrate(&mut self) -> Result<()> {
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let version = schema_version(&tx)?;
        tx.execute_batch(SCHEMA)?;
        let has_session_source: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info('quota_snapshots')
                           WHERE name = 'is_from_session')",
            [],
            |row| row.get(0),
        )?;
        if !has_session_source {
            tx.execute_batch(
                "ALTER TABLE quota_snapshots ADD COLUMN is_from_session INTEGER NOT NULL DEFAULT 0;
                 UPDATE file_cursors SET committed_offset = 0, previous_input_tokens = NULL,
                   previous_cached_input_tokens = NULL, previous_output_tokens = NULL;",
            )?;
        }
        if version < SCHEMA_VERSION {
            let has_model: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM pragma_table_info('usage_events') WHERE name = 'model')",
                [],
                |row| row.get(0),
            )?;
            if !has_model {
                tx.execute_batch(
                    "ALTER TABLE usage_events ADD COLUMN model TEXT;
                     ALTER TABLE file_cursors ADD COLUMN model TEXT;",
                )?;
            }
            // 重扫保留的日志以补齐旧事件，同时保留原来的去重签名。
            tx.execute_batch(
                "UPDATE file_cursors SET committed_offset = 0, previous_input_tokens = NULL,
                   previous_cached_input_tokens = NULL, previous_output_tokens = NULL, model = NULL;",
            )?;
            tx.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn checkpoint(&self) -> Result<()> {
        self.connection
            .execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;
        Ok(())
    }

    pub fn insert(&mut self, events: &[StoredUsageEvent]) -> Result<usize> {
        ensure!(events.iter().all(valid_event), "invalid usage event");
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let inserted = insert_events(&tx, events)?;
        tx.commit()?;
        Ok(inserted)
    }

    pub fn ingest(
        &mut self,
        events: &[StoredUsageEvent],
        quotas: &[QuotaSnapshot],
        cursor: &FileCursor,
    ) -> Result<usize> {
        ensure!(events.iter().all(valid_event), "invalid usage event");
        ensure!(valid_cursor(cursor), "invalid file cursor");
        ensure!(quotas.iter().all(valid_quota), "invalid session quota");
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let inserted = insert_events(&tx, events)?;
        for quota in quotas {
            save_quota(&tx, quota, true)?;
        }
        upsert_cursor(&tx, cursor)?;
        tx.commit()?;
        Ok(inserted)
    }

    pub fn events(&self, from: Timestamp, to: Timestamp) -> Result<Vec<StoredUsageEvent>> {
        ensure!(
            from.is_finite() && to.is_finite(),
            "invalid event query bounds"
        );
        let mut statement = self.connection.prepare(
            "SELECT signature, occurred_at, local_day, input_tokens,
                    cached_input_tokens, output_tokens, model
             FROM usage_events
             WHERE occurred_at >= ? AND occurred_at < ?
             ORDER BY occurred_at ASC, signature ASC;",
        )?;
        let mut rows = statement.query([from, to])?;
        let mut events = Vec::new();
        while let Some(row) = rows.next()? {
            let event = StoredUsageEvent {
                signature: row.get(0)?,
                occurred_at: row.get(1)?,
                local_day: read_day(row.get_ref(2)?.as_str()?)?,
                usage: read_usage(row, 3)?,
                model: row.get(6)?,
            };
            ensure!(valid_event(&event), "corrupt usage event");
            events.push(event);
        }
        Ok(events)
    }

    pub fn cursor(&self, path_hash: &[u8]) -> Result<Option<FileCursor>> {
        let mut statement = self.connection.prepare(
            "SELECT device_id, inode, committed_offset, previous_input_tokens,
                    previous_cached_input_tokens, previous_output_tokens, model
             FROM file_cursors WHERE path_hash = ?;",
        )?;
        let mut rows = statement.query([path_hash])?;
        let Some(row) = rows.next()? else {
            return Ok(None);
        };
        let previous_total = match (row.get(3)?, row.get(4)?, row.get(5)?) {
            (None, None, None) => None,
            (Some(input_tokens), Some(cached_input_tokens), Some(output_tokens)) => {
                Some(TokenBreakdown {
                    input_tokens,
                    cached_input_tokens,
                    output_tokens,
                })
            }
            _ => anyhow::bail!("corrupt file cursor counters"),
        };
        let cursor = FileCursor {
            path_hash: path_hash.to_vec(),
            device_id: row.get(0)?,
            inode: row.get(1)?,
            committed_offset: row.get(2)?,
            previous_total,
            model: row.get(6)?,
        };
        ensure!(valid_cursor(&cursor), "corrupt file cursor");
        Ok(Some(cursor))
    }

    pub fn save_cursor(&mut self, cursor: &FileCursor) -> Result<()> {
        ensure!(valid_cursor(cursor), "invalid file cursor");
        upsert_cursor(&self.connection, cursor)
    }

    pub fn upsert_official_days(&mut self, days: &[OfficialUsageDay]) -> Result<()> {
        ensure!(
            days.iter().all(valid_official_day),
            "invalid official usage day"
        );
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        {
            let mut statement = tx.prepare(
                "INSERT INTO official_usage_days (local_day, tokens, fetched_at)
                 VALUES (?, ?, ?)
                 ON CONFLICT(local_day) DO UPDATE SET
                   tokens = excluded.tokens, fetched_at = excluded.fetched_at;",
            )?;
            for day in days {
                statement.execute(params![day.day.to_string(), day.tokens, day.fetched_at])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn official_days(&self) -> Result<Vec<OfficialUsageDay>> {
        let mut statement = self.connection.prepare(
            "SELECT local_day, tokens, fetched_at
             FROM official_usage_days ORDER BY local_day ASC;",
        )?;
        let mut rows = statement.query([])?;
        let mut days = Vec::new();
        while let Some(row) = rows.next()? {
            let day = OfficialUsageDay {
                day: read_day(row.get_ref(0)?.as_str()?)?,
                tokens: row.get(1)?,
                fetched_at: row.get(2)?,
            };
            ensure!(valid_official_day(&day), "corrupt official usage day");
            days.push(day);
        }
        Ok(days)
    }

    pub fn save_quota(&mut self, quota: &QuotaSnapshot) -> Result<()> {
        ensure!(valid_quota(quota), "invalid quota");
        save_quota(&self.connection, quota, false)
    }

    pub fn latest_quota(&self) -> Result<Option<QuotaSnapshot>> {
        let mut statement = self.connection.prepare(
            "SELECT limit_id, used_percent, window_duration_minutes, starts_at, resets_at, fetched_at
             FROM quota_snapshots WHERE is_from_session = 0 ORDER BY fetched_at DESC LIMIT 1;",
        )?;
        let mut rows = statement.query([])?;
        rows.next()?.map(read_quota).transpose()
    }

    pub fn quota_history(
        &self,
        from: Timestamp,
        to: Timestamp,
        limit_id: &str,
    ) -> Result<Vec<QuotaSnapshot>> {
        quota_history(&self.connection, from, to, limit_id)
    }

    pub fn save_refresh_state(&mut self, state: &RefreshState) -> Result<()> {
        ensure!(valid_refresh_state(state), "invalid refresh state");
        let [account, rate_limits, official_usage, session_indexing] =
            FAILURE_SOURCES.map(|source| state.failed_sources.contains(&source));
        self.connection.execute(
            "INSERT INTO refresh_state (
               singleton_id, last_successful_quota_refresh_at, last_successful_official_usage_refresh_at,
               consecutive_failure_count, account_initialization_failed, rate_limits_failed,
               official_usage_failed, session_indexing_failed
             ) VALUES (1, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(singleton_id) DO UPDATE SET
               last_successful_quota_refresh_at = excluded.last_successful_quota_refresh_at,
               last_successful_official_usage_refresh_at = excluded.last_successful_official_usage_refresh_at,
               consecutive_failure_count = excluded.consecutive_failure_count,
               account_initialization_failed = excluded.account_initialization_failed,
               rate_limits_failed = excluded.rate_limits_failed,
               official_usage_failed = excluded.official_usage_failed,
               session_indexing_failed = excluded.session_indexing_failed;",
            params![state.last_successful_quota_refresh_at, state.last_successful_official_usage_refresh_at,
                    state.consecutive_failure_count, account, rate_limits, official_usage, session_indexing],
        )?;
        Ok(())
    }

    pub fn refresh_state(&self) -> Result<RefreshState> {
        let mut statement = self.connection.prepare(
            "SELECT last_successful_quota_refresh_at, last_successful_official_usage_refresh_at,
                    consecutive_failure_count, account_initialization_failed, rate_limits_failed,
                    official_usage_failed, session_indexing_failed
             FROM refresh_state WHERE singleton_id = 1;",
        )?;
        let mut rows = statement.query([])?;
        let Some(row) = rows.next()? else {
            return Ok(RefreshState::default());
        };
        let mut state = RefreshState {
            last_successful_quota_refresh_at: row.get(0)?,
            last_successful_official_usage_refresh_at: row.get(1)?,
            consecutive_failure_count: row.get(2)?,
            failed_sources: Default::default(),
        };
        for (column, source) in (3_usize..).zip(FAILURE_SOURCES) {
            match row.get::<_, i64>(column)? {
                0 => (),
                1 => {
                    state.failed_sources.insert(source);
                }
                _ => anyhow::bail!("corrupt refresh failure flag"),
            }
        }
        ensure!(valid_refresh_state(&state), "corrupt refresh state");
        Ok(state)
    }

    pub fn replace_cycles(&mut self, cycles: &[QuotaCycle]) -> Result<()> {
        ensure!(
            cycles.len() <= 9,
            "too many quota cycles ({})",
            cycles.len()
        );
        ensure!(cycles.iter().all(valid_cycle), "invalid quota cycle");
        let mut cycles = cycles.iter().collect::<Vec<_>>();
        cycles.sort_by(|a, b| a.starts_at.total_cmp(&b.starts_at));
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute("DELETE FROM quota_cycles;", [])?;
        {
            let mut statement = tx.prepare(
                "INSERT INTO quota_cycles (
                   starts_at, ends_at, input_tokens, cached_input_tokens, output_tokens,
                   displayed_tokens, status, boundary_is_estimated
                 ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
            )?;
            for cycle in cycles {
                let status = match cycle.status {
                    Status::LocalLive => "localLive",
                    Status::Calibrated => "calibrated",
                    Status::PartiallyCalibrated => "partiallyCalibrated",
                    Status::Stale => "stale",
                    Status::Unavailable => "unavailable",
                };
                statement.execute(params![
                    cycle.starts_at,
                    cycle.ends_at,
                    cycle.usage.input_tokens,
                    cycle.usage.cached_input_tokens,
                    cycle.usage.output_tokens,
                    cycle.displayed_tokens,
                    status,
                    cycle.boundary_is_estimated
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn cycles(&self) -> Result<Vec<QuotaCycle>> {
        let mut statement = self.connection.prepare(
            "SELECT starts_at, ends_at, input_tokens, cached_input_tokens, output_tokens,
                    displayed_tokens, status, boundary_is_estimated
             FROM quota_cycles ORDER BY starts_at ASC;",
        )?;
        let mut rows = statement.query([])?;
        let mut cycles = Vec::new();
        while let Some(row) = rows.next()? {
            let status = match row.get_ref(6)?.as_str()? {
                "localLive" => Status::LocalLive,
                "calibrated" => Status::Calibrated,
                "partiallyCalibrated" => Status::PartiallyCalibrated,
                "stale" => Status::Stale,
                "unavailable" => Status::Unavailable,
                _ => anyhow::bail!("corrupt quota cycle status"),
            };
            let cycle = QuotaCycle {
                starts_at: row.get(0)?,
                ends_at: row.get(1)?,
                usage: read_usage(row, 2)?,
                displayed_tokens: row.get(5)?,
                status,
                boundary_is_estimated: row.get(7)?,
                quota_used_percent: None,
                last_recorded_quota: None,
                daily_usage: None,
            };
            ensure!(valid_cycle(&cycle), "corrupt quota cycle");
            cycles.push(cycle);
        }
        Ok(cycles)
    }

    pub fn prune_usage(
        &mut self,
        events_before: Timestamp,
        official_days_before: NaiveDate,
    ) -> Result<()> {
        ensure!(
            events_before.is_finite() && canonical_day(official_days_before),
            "invalid usage prune cutoff"
        );
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute(
            "DELETE FROM usage_events WHERE occurred_at < ?;",
            [events_before],
        )?;
        tx.execute(
            "DELETE FROM official_usage_days WHERE local_day < ?;",
            [official_days_before.to_string()],
        )?;
        let limit_ids = {
            let mut statement = tx.prepare("SELECT DISTINCT limit_id FROM quota_snapshots;")?;
            statement
                .query_map([], |row| row.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?
        };
        let mut statement = tx.prepare_cached(
            "DELETE FROM quota_snapshots
             WHERE limit_id = ?1 AND fetched_at < ?2 AND fetched_at != ?3 AND fetched_at NOT IN (
               SELECT MAX(fetched_at) FROM quota_snapshots
               WHERE limit_id = ?1 AND fetched_at < ?2 AND is_from_session = 0
               HAVING COUNT(*) > 0
             );",
        )?;
        for limit_id in limit_ids {
            let history = quota_history(&tx, events_before, SWIFT_DISTANT_FUTURE, &limit_id)?;
            let predecessor = history
                .iter()
                .rfind(|quota| quota.fetched_at < events_before);
            // 保留有效前驱和主动读取锚点，避免下一次查询把缓存旧值重新接纳。
            statement.execute(params![
                limit_id,
                events_before,
                predecessor.map_or(events_before, |q| q.fetched_at)
            ])?;
        }
        drop(statement);
        tx.commit()?;
        Ok(())
    }
}

fn schema_version(db: &Connection) -> Result<i64> {
    let version: i64 = db.pragma_query_value(None, "user_version", |row| row.get(0))?;
    ensure!(
        version <= SCHEMA_VERSION,
        "unsupported usage database version {version}"
    );
    Ok(version)
}

fn insert_events(db: &Connection, events: &[StoredUsageEvent]) -> Result<usize> {
    let mut insert = db.prepare_cached(
        "INSERT OR IGNORE INTO usage_events (
           signature, occurred_at, local_day, input_tokens, cached_input_tokens, output_tokens, model
         ) VALUES (?, ?, ?, ?, ?, ?, ?);",
    )?;
    let mut backfill = db.prepare_cached(
        "UPDATE usage_events SET model = ? WHERE signature = ? AND model IS NULL;",
    )?;
    let mut inserted = 0;
    for event in events {
        let changes = insert.execute(params![
            event.signature,
            event.occurred_at,
            event.local_day.to_string(),
            event.usage.input_tokens,
            event.usage.cached_input_tokens,
            event.usage.output_tokens,
            event.model,
        ])?;
        inserted += changes;
        if changes == 0
            && let Some(model) = &event.model
        {
            backfill.execute(params![model, event.signature])?;
        }
    }
    Ok(inserted)
}

fn upsert_cursor(db: &Connection, cursor: &FileCursor) -> Result<()> {
    db.prepare_cached(
        "INSERT INTO file_cursors (
           path_hash, device_id, inode, committed_offset, previous_input_tokens,
           previous_cached_input_tokens, previous_output_tokens, model
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(path_hash) DO UPDATE SET
           device_id = excluded.device_id, inode = excluded.inode, committed_offset = excluded.committed_offset,
           previous_input_tokens = excluded.previous_input_tokens,
           previous_cached_input_tokens = excluded.previous_cached_input_tokens,
           previous_output_tokens = excluded.previous_output_tokens, model = excluded.model;",
    )?.execute(params![
        cursor.path_hash, cursor.device_id, cursor.inode, cursor.committed_offset,
        cursor.previous_total.map(|total| total.input_tokens),
        cursor.previous_total.map(|total| total.cached_input_tokens),
        cursor.previous_total.map(|total| total.output_tokens), cursor.model,
    ])?;
    Ok(())
}

fn save_quota(db: &Connection, quota: &QuotaSnapshot, is_from_session: bool) -> Result<()> {
    db.prepare_cached(
        "INSERT INTO quota_snapshots (
           fetched_at, limit_id, used_percent, window_duration_minutes, starts_at, resets_at, is_from_session
         ) VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(fetched_at) DO UPDATE SET
           limit_id = excluded.limit_id, used_percent = excluded.used_percent,
           window_duration_minutes = excluded.window_duration_minutes,
           starts_at = excluded.starts_at, resets_at = excluded.resets_at, is_from_session = excluded.is_from_session
         WHERE excluded.is_from_session = 0 OR (quota_snapshots.is_from_session = 1 AND (
           (excluded.limit_id = quota_snapshots.limit_id
             AND excluded.window_duration_minutes = quota_snapshots.window_duration_minutes
             AND ABS(excluded.starts_at - quota_snapshots.starts_at) <= 60
             AND NOT (quota_snapshots.used_percent = 0 AND excluded.starts_at < quota_snapshots.starts_at)
             AND excluded.used_percent >= quota_snapshots.used_percent)
           OR (excluded.limit_id = quota_snapshots.limit_id
             AND excluded.window_duration_minutes = quota_snapshots.window_duration_minutes
             AND excluded.starts_at > quota_snapshots.starts_at
             AND (excluded.starts_at - quota_snapshots.starts_at > 60 OR excluded.used_percent = 0))
           OR (excluded.limit_id = 'codex' AND quota_snapshots.limit_id != 'codex')
         ));",
    )?.execute(params![quota.fetched_at, quota.limit_id, quota.used_percent,
        quota.window_duration_minutes, quota.starts_at, quota.resets_at, is_from_session])?;
    Ok(())
}

fn quota_history(
    db: &Connection,
    from: Timestamp,
    to: Timestamp,
    limit_id: &str,
) -> Result<Vec<QuotaSnapshot>> {
    // 先用保留的完整历史过滤旧日志，再截取边界和有效前驱。
    let mut statement = db.prepare(
        "SELECT limit_id, used_percent, window_duration_minutes, starts_at, resets_at, fetched_at, is_from_session
         FROM quota_snapshots WHERE limit_id = ? AND fetched_at <= ? ORDER BY fetched_at ASC;",
    )?;
    let mut rows = statement.query(params![limit_id, to])?;
    let mut readings = Vec::new();
    while let Some(row) = rows.next()? {
        readings.push(QuotaReading {
            quota: read_quota(row)?,
            is_from_session: row.get(6)?,
        });
    }
    let mut merged = reconciled_session_quota_history(readings);
    let predecessor = merged
        .iter()
        .rfind(|quota| quota.fetched_at < from)
        .map(|quota| quota.fetched_at);
    merged.retain(|quota| quota.fetched_at >= from || Some(quota.fetched_at) == predecessor);
    Ok(merged)
}

fn read_quota(row: &Row<'_>) -> Result<QuotaSnapshot> {
    let quota = QuotaSnapshot {
        limit_id: row.get(0)?,
        used_percent: row.get(1)?,
        window_duration_minutes: row.get(2)?,
        starts_at: row.get(3)?,
        resets_at: row.get(4)?,
        fetched_at: row.get(5)?,
    };
    ensure!(valid_quota(&quota), "corrupt quota");
    Ok(quota)
}

fn read_day(text: &str) -> Result<NaiveDate> {
    let day = NaiveDate::parse_from_str(text, "%Y-%m-%d").context("corrupt local day")?;
    ensure!(
        canonical_day(day) && day.to_string() == text,
        "corrupt local day"
    );
    Ok(day)
}

fn read_usage(row: &Row<'_>, first: usize) -> rusqlite::Result<TokenBreakdown> {
    Ok(TokenBreakdown {
        input_tokens: row.get(first)?,
        cached_input_tokens: row.get(first + 1)?,
        output_tokens: row.get(first + 2)?,
    })
}

fn canonical_day(day: NaiveDate) -> bool {
    (1..=9999).contains(&day.year())
}

fn valid_event(event: &StoredUsageEvent) -> bool {
    event.occurred_at.is_finite() && canonical_day(event.local_day) && event.usage.is_valid()
}

fn valid_cursor(cursor: &FileCursor) -> bool {
    cursor.committed_offset >= 0 && cursor.previous_total.is_none_or(TokenBreakdown::is_valid)
}

fn valid_official_day(day: &OfficialUsageDay) -> bool {
    day.tokens >= 0 && day.fetched_at.is_finite() && canonical_day(day.day)
}

fn valid_quota(quota: &QuotaSnapshot) -> bool {
    quota.used_percent.is_finite()
        && quota.used_percent >= 0.0
        && quota.window_duration_minutes > 0
        && quota.starts_at.is_finite()
        && quota.resets_at.is_finite()
        && quota.fetched_at.is_finite()
}

fn valid_refresh_state(state: &RefreshState) -> bool {
    state.consecutive_failure_count >= 0
        && state
            .last_successful_quota_refresh_at
            .is_none_or(f64::is_finite)
        && state
            .last_successful_official_usage_refresh_at
            .is_none_or(f64::is_finite)
}

fn valid_cycle(cycle: &QuotaCycle) -> bool {
    cycle.starts_at.is_finite()
        && cycle.ends_at.is_finite()
        && cycle.usage.is_valid()
        && cycle.displayed_tokens >= 0
        && cycle.ends_at >= cycle.starts_at
}

const SCHEMA: &str = "
    CREATE TABLE IF NOT EXISTS file_cursors (
      path_hash BLOB PRIMARY KEY NOT NULL,
      device_id INTEGER NOT NULL,
      inode INTEGER NOT NULL,
      committed_offset INTEGER NOT NULL,
      previous_input_tokens INTEGER,
      previous_cached_input_tokens INTEGER,
      previous_output_tokens INTEGER
    );

    CREATE TABLE IF NOT EXISTS usage_events (
      signature BLOB PRIMARY KEY NOT NULL,
      occurred_at REAL NOT NULL,
      local_day TEXT NOT NULL,
      input_tokens INTEGER NOT NULL CHECK(input_tokens >= 0),
      cached_input_tokens INTEGER NOT NULL CHECK(cached_input_tokens >= 0),
      output_tokens INTEGER NOT NULL CHECK(output_tokens >= 0)
    );

    CREATE INDEX IF NOT EXISTS usage_events_occurred_at ON usage_events(occurred_at);
    CREATE INDEX IF NOT EXISTS usage_events_local_day ON usage_events(local_day);

    CREATE TABLE IF NOT EXISTS official_usage_days (
      local_day TEXT PRIMARY KEY NOT NULL,
      tokens INTEGER NOT NULL CHECK(tokens >= 0),
      fetched_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS quota_snapshots (
      fetched_at REAL PRIMARY KEY NOT NULL,
      limit_id TEXT NOT NULL,
      used_percent REAL NOT NULL,
      window_duration_minutes INTEGER NOT NULL,
      starts_at REAL NOT NULL,
      resets_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS quota_cycles (
      starts_at REAL PRIMARY KEY NOT NULL,
      ends_at REAL NOT NULL,
      input_tokens INTEGER NOT NULL,
      cached_input_tokens INTEGER NOT NULL,
      output_tokens INTEGER NOT NULL,
      displayed_tokens INTEGER NOT NULL,
      status TEXT NOT NULL,
      boundary_is_estimated INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS refresh_state (
      singleton_id INTEGER PRIMARY KEY NOT NULL CHECK(singleton_id = 1),
      last_successful_quota_refresh_at REAL,
      last_successful_official_usage_refresh_at REAL,
      consecutive_failure_count INTEGER NOT NULL CHECK(consecutive_failure_count >= 0),
      account_initialization_failed INTEGER NOT NULL CHECK(account_initialization_failed IN (0, 1)),
      rate_limits_failed INTEGER NOT NULL CHECK(rate_limits_failed IN (0, 1)),
      official_usage_failed INTEGER NOT NULL CHECK(official_usage_failed IN (0, 1)),
      session_indexing_failed INTEGER NOT NULL CHECK(session_indexing_failed IN (0, 1))
    );";

#[cfg(test)]
mod tests;
