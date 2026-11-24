use crate::model::{OfficialUsageDay, QuotaSnapshot, unix_seconds};
use anyhow::{Context, Result, bail};
use chrono::{Datelike, NaiveDate};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

mod executable;
mod rate_limits;
#[cfg(test)]
mod tests;

use executable::{absolute_path, find_executable};
use rate_limits::{BucketPatch, RateLimits};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const CANCELLATION_POLL_INTERVAL: Duration = Duration::from_millis(100);
const MAX_PENDING_MESSAGES: usize = 128;
const MAX_MESSAGE_BYTES: u64 = 16 * 1024 * 1024;

pub struct OfficialDays {
    pub days: Vec<OfficialUsageDay>,
    pub had_invalid_bucket: bool,
}

pub struct AppServer {
    child: Option<Child>,
    stdin: Option<ChildStdin>,
    messages: Receiver<Incoming>,
    next_id: u64,
    timeout: Duration,
    cancellation: Option<Arc<AtomicBool>>,
    codex_home: Option<PathBuf>,
    last_rate_limits: Option<RateLimits>,
    updates: VecDeque<RateLimitsUpdate>,
}

impl AppServer {
    pub fn available() -> bool {
        find_executable().is_some()
    }

    pub fn connect(codex_home: Option<&Path>) -> Result<Self> {
        Self::connect_with_cancellation(codex_home, None)
    }

    pub fn connect_interruptible(
        codex_home: Option<&Path>,
        cancellation: Arc<AtomicBool>,
    ) -> Result<Self> {
        Self::connect_with_cancellation(codex_home, Some(cancellation))
    }

    fn connect_with_cancellation(
        codex_home: Option<&Path>,
        cancellation: Option<Arc<AtomicBool>>,
    ) -> Result<Self> {
        check_cancelled(cancellation.as_deref())?;
        let executable = find_executable().context("Codex CLI was not found")?;
        let mut command = Command::new(executable);
        command.arg("app-server");
        Self::start(command, codex_home, REQUEST_TIMEOUT, cancellation)
    }

    fn start(
        mut command: Command,
        codex_home: Option<&Path>,
        timeout: Duration,
        cancellation: Option<Arc<AtomicBool>>,
    ) -> Result<Self> {
        check_cancelled(cancellation.as_deref())?;
        if let Some(codex_home) = codex_home {
            command.env("CODEX_HOME", codex_home);
        }
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            const CREATE_NO_WINDOW: u32 = 0x08000000;
            command.creation_flags(CREATE_NO_WINDOW);
        }
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .context("Could not start the Codex app-server")?;
        let stdin = child.stdin.take();
        let stdout = child
            .stdout
            .take()
            .expect("stdout was configured as a pipe");
        let (sender, messages) = mpsc::sync_channel(MAX_PENDING_MESSAGES);
        let mut server = Self {
            child: Some(child),
            stdin,
            messages,
            next_id: 1,
            timeout,
            cancellation,
            codex_home: None,
            last_rate_limits: None,
            updates: VecDeque::new(),
        };
        thread::Builder::new()
            .name("codex-app-server-stdout".into())
            .spawn(move || receive_stdout(BufReader::new(stdout), sender))
            .context("Could not start reading Codex app-server responses")?;

        let initialized = server.request(
            "initialize",
            Some(json!({
                "clientInfo": {
                    "name": "codex_usage_menubar",
                    "title": "Codex Usage",
                    "version": env!("CARGO_PKG_VERSION"),
                },
            })),
            timeout,
            true,
        )?;
        check_cancelled(server.cancellation.as_deref())?;
        if !initialized.is_object() {
            bail!("Invalid Codex app-server initialization response");
        }
        server.codex_home = initialized["codexHome"].as_str().and_then(absolute_path);
        server.send(&json!({"jsonrpc": "2.0", "method": "initialized", "params": {}}))?;
        Ok(server)
    }

    pub fn codex_home(&self) -> Option<&Path> {
        self.codex_home.as_deref()
    }

    pub fn is_running(&mut self) -> bool {
        self.child
            .as_mut()
            .is_some_and(|child| matches!(child.try_wait(), Ok(None)))
    }

    pub fn read_quota(&mut self, fetched_at: f64) -> Result<Option<QuotaSnapshot>> {
        self.read_quota_with_timeout(fetched_at, self.timeout)
    }

    pub fn read_quota_with_timeout(
        &mut self,
        fetched_at: f64,
        timeout: Duration,
    ) -> Result<Option<QuotaSnapshot>> {
        self.read_quota_request(fetched_at, timeout, true)
    }

    pub fn capture_quota(
        &mut self,
        fetched_at: f64,
        timeout: Duration,
    ) -> Result<Option<QuotaSnapshot>> {
        self.read_quota_request(fetched_at, timeout, false)
    }

    fn read_quota_request(
        &mut self,
        fetched_at: f64,
        timeout: Duration,
        interruptible: bool,
    ) -> Result<Option<QuotaSnapshot>> {
        let response = self.request("account/rateLimits/read", None, timeout, interruptible)?;
        let rate_limits: RateLimits = serde_json::from_value(response)
            .map_err(|_| anyhow::anyhow!("Invalid Codex rate limits response"))?;
        let quota = rate_limits.select(fetched_at, None).map(|(quota, _)| quota);
        self.last_rate_limits = Some(rate_limits);
        // A full response supersedes patches delivered before it on the same stream.
        self.updates.clear();
        Ok(quota)
    }

    pub fn read_official_days(&mut self, fetched_at: f64) -> Result<OfficialDays> {
        let response = self.request("account/usage/read", None, self.timeout, true)?;
        official_days(response, fetched_at)
    }

    pub fn quota_notifications(&mut self) -> Vec<QuotaSnapshot> {
        let mut updates = std::mem::take(&mut self.updates);
        for message in self.messages.try_iter().take(MAX_PENDING_MESSAGES) {
            if let Incoming::RateLimits(update) = message {
                updates.push_back(update);
            }
        }

        let mut quotas = Vec::new();
        let mut needs_full_read = None;
        for update in updates {
            let Some(previous) = self.last_rate_limits.as_ref() else {
                needs_full_read = Some(update.received_at);
                continue;
            };
            let next = previous.applying(&update.patch);
            match next.select(update.received_at, Some((previous, &update.patch))) {
                Some((quota, true)) => {
                    quotas.push(quota);
                    needs_full_read = None;
                }
                Some((quota, false))
                    if previous
                        .select(update.received_at, None)
                        .map(|(quota, _)| quota)
                        == Some(quota.clone()) => {}
                _ => needs_full_read = Some(update.received_at),
            }
            self.last_rate_limits = Some(next);
        }
        if let Some(received_at) = needs_full_read
            && let Ok(Some(quota)) = self.read_quota(received_at)
        {
            quotas.push(quota);
        }
        quotas
    }

    fn request(
        &mut self,
        method: &str,
        params: Option<Value>,
        timeout: Duration,
        interruptible: bool,
    ) -> Result<Value> {
        let cancellation = if interruptible {
            self.cancellation.clone()
        } else {
            None
        };
        check_cancelled(cancellation.as_deref())?;
        let id = self.next_id;
        self.next_id += 1;
        let mut message = json!({"jsonrpc": "2.0", "id": id, "method": method});
        if let Some(params) = params {
            message["params"] = params;
        }
        let deadline = Instant::now() + timeout;
        if let Err(error) = self.send(&message) {
            self.stop();
            return Err(error);
        }
        loop {
            // 丢弃已取消请求的应答，保留连接供退出前的额度读取使用。
            check_cancelled(cancellation.as_deref())?;
            let received = match deadline.checked_duration_since(Instant::now()) {
                Some(remaining) if cancellation.is_some() => self
                    .messages
                    .recv_timeout(remaining.min(CANCELLATION_POLL_INTERVAL)),
                Some(remaining) => self.messages.recv_timeout(remaining),
                None => Err(mpsc::RecvTimeoutError::Timeout),
            };
            match received {
                Ok(Incoming::Response {
                    id: received_id,
                    response,
                }) if id == received_id => {
                    return response
                        .with_context(|| format!("Codex app-server request {method} failed"));
                }
                Ok(Incoming::RateLimits(update)) => {
                    if self.updates.len() == MAX_PENDING_MESSAGES {
                        self.updates.pop_front();
                    }
                    self.updates.push_back(update);
                }
                Ok(Incoming::Response { .. }) => {}
                Err(mpsc::RecvTimeoutError::Timeout) if Instant::now() < deadline => {}
                Err(error) => {
                    self.stop();
                    match error {
                        mpsc::RecvTimeoutError::Timeout => {
                            bail!("Codex app-server request {method} timed out")
                        }
                        mpsc::RecvTimeoutError::Disconnected => {
                            bail!("Codex app-server closed during {method}")
                        }
                    }
                }
            }
        }
    }

    fn send(&mut self, message: &Value) -> Result<()> {
        let stdin = self.stdin.as_mut().context("Codex app-server is closed")?;
        let mut line = serde_json::to_vec(message)?;
        line.push(b'\n');
        stdin
            .write_all(&line)
            .context("Could not write to Codex app-server stdin")
    }

    fn stop(&mut self) {
        self.stdin.take();
        if let Some(mut child) = self.child.take()
            && child.kill().is_ok()
        {
            let _ = child.wait();
        }
    }
}

fn check_cancelled(cancellation: Option<&AtomicBool>) -> Result<()> {
    if cancellation.is_some_and(|flag| flag.load(Ordering::Acquire)) {
        bail!("Codex app-server request cancelled");
    }
    Ok(())
}

impl Drop for AppServer {
    fn drop(&mut self) {
        self.stop();
    }
}

enum Incoming {
    Response { id: u64, response: Result<Value> },
    RateLimits(RateLimitsUpdate),
}

struct RateLimitsUpdate {
    patch: BucketPatch,
    received_at: f64,
}

fn receive_stdout(mut stdout: impl BufRead, sender: SyncSender<Incoming>) {
    let mut line = Vec::new();
    loop {
        line.clear();
        match (&mut stdout)
            .take(MAX_MESSAGE_BYTES)
            .read_until(b'\n', &mut line)
        {
            Ok(0) | Err(_) => return,
            Ok(size) if size as u64 == MAX_MESSAGE_BYTES && !line.ends_with(b"\n") => return,
            Ok(_) => {}
        }
        let Ok(mut message) = serde_json::from_slice::<Value>(&line) else {
            continue;
        };
        let incoming = if let Some(id) = message["id"].as_u64() {
            let response = if let Some(error) = message.get("error") {
                match error["code"].as_i64() {
                    Some(code) => Err(anyhow::anyhow!("RPC error {code}")),
                    None => Err(anyhow::anyhow!("Invalid RPC error")),
                }
            } else if let Some(result) = message.get_mut("result") {
                Ok(result.take())
            } else {
                continue;
            };
            Incoming::Response { id, response }
        } else if message["method"] == "account/rateLimits/updated" {
            let Some(patch) = message
                .get_mut("params")
                .and_then(|params| params.get_mut("rateLimits"))
            else {
                continue;
            };
            let Ok(patch) = serde_json::from_value(patch.take()) else {
                continue;
            };
            Incoming::RateLimits(RateLimitsUpdate {
                patch,
                received_at: unix_seconds(SystemTime::now()),
            })
        } else {
            continue;
        };
        if sender.send(incoming).is_err() {
            return;
        }
    }
}

fn official_days(value: Value, fetched_at: f64) -> Result<OfficialDays> {
    let buckets = value["dailyUsageBuckets"]
        .as_array()
        .context("Codex account response has no daily usage buckets")?;
    let mut days = Vec::with_capacity(buckets.len());
    let mut had_invalid_bucket = false;
    for bucket in buckets {
        match (
            bucket["startDate"].as_str().and_then(strict_day),
            bucket["tokens"].as_i64(),
        ) {
            (Some(day), Some(tokens)) if tokens >= 0 => days.push(OfficialUsageDay {
                day,
                tokens,
                fetched_at,
            }),
            _ => had_invalid_bucket = true,
        }
    }
    Ok(OfficialDays {
        days,
        had_invalid_bucket,
    })
}

fn strict_day(value: &str) -> Option<NaiveDate> {
    let day = NaiveDate::parse_from_str(value, "%Y-%m-%d").ok()?;
    ((1..=9999).contains(&day.year()) && day.format("%Y-%m-%d").to_string() == value).then_some(day)
}
