use crate::model::{
    FileCursor, QuotaSnapshot, StoredUsageEvent, Timestamp, TokenBreakdown, local_day, unix_seconds,
};
use crate::store::Store;
use anyhow::{Context, Result};
use chrono::{DateTime, TimeZone};
use serde::Deserialize;
use serde_json::value::RawValue;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::ffi::OsStr;
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use walkdir::WalkDir;

pub const SESSION_DIRECTORIES: [&str; 2] = ["sessions", "archived_sessions"];

#[derive(Default)]
pub struct SessionIndexer {
    indexed: HashMap<PathBuf, FileSnapshot>,
}

impl SessionIndexer {
    pub fn index(
        &mut self,
        home: &Path,
        cutoff: Timestamp,
        timezone: &impl TimeZone,
        store: &mut Store,
        quitting: &AtomicBool,
    ) -> Result<usize> {
        let mut files = Vec::new();
        for directory in SESSION_DIRECTORIES {
            let root = home.join(directory);
            match fs::symlink_metadata(&root) {
                Ok(metadata) if metadata.is_dir() && !is_link(&metadata) => {}
                Ok(_) => continue,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => return Err(error.into()),
            }
            for entry in WalkDir::new(&root)
                .follow_links(false)
                .into_iter()
                .filter_entry(|entry| {
                    !entry.file_type().is_symlink()
                        && (!entry.file_type().is_dir()
                            || entry
                                .metadata()
                                .map_or(true, |metadata| !is_link(&metadata)))
                })
            {
                anyhow::ensure!(!quitting.load(Ordering::Acquire), "session scan cancelled");
                let entry = entry?;
                if entry.file_type().is_file()
                    && entry.path().extension() == Some(OsStr::new("jsonl"))
                {
                    let metadata = entry.metadata()?;
                    if !is_link(&metadata) && unix_seconds(metadata.modified()?) >= cutoff {
                        files.push(entry.into_path());
                    }
                }
            }
        }
        files.sort_unstable();
        let present: HashSet<_> = files.iter().collect();
        self.indexed.retain(|path, _| present.contains(path));
        let mut inserted = 0;
        for path in files {
            anyhow::ensure!(!quitting.load(Ordering::Acquire), "session scan cancelled");
            inserted += self.index_file(&path, timezone, store, quitting)?;
        }
        Ok(inserted)
    }

    fn index_file(
        &mut self,
        path: &Path,
        timezone: &impl TimeZone,
        store: &mut Store,
        quitting: &AtomicBool,
    ) -> Result<usize> {
        let before = match fs::symlink_metadata(path) {
            Ok(metadata) if metadata.is_file() && !is_link(&metadata) => metadata,
            Ok(_) => return Ok(0),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(0),
            Err(error) => return Err(error.into()),
        };
        let mut options = OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            use windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT;
            options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
        }
        let mut file = match options.open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(0),
            Err(error) => return Err(error.into()),
        };
        let opened = FileSnapshot::new(&file)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            if (before.dev() as i64, before.ino() as i64) != (opened.device_id, opened.inode) {
                return Ok(0);
            }
        }
        #[cfg(windows)]
        let _ = before;
        if self.indexed.get(path) == Some(&opened) {
            return Ok(0);
        }

        let path_hash = Sha256::digest(swift_path(path).as_bytes()).to_vec();
        let previous = store.cursor(&path_hash)?;
        let same_file = previous
            .as_ref()
            .filter(|cursor| cursor.device_id == opened.device_id && cursor.inode == opened.inode);
        let resume =
            same_file.filter(|cursor| (0..=opened.size).contains(&cursor.committed_offset));
        let mut cursor = FileCursor {
            path_hash,
            device_id: opened.device_id,
            inode: opened.inode,
            committed_offset: 0,
            previous_total: None,
            model: None,
        };
        // 如果读取中途文件被改写，下次从头重读，签名仍对旧事件去重。
        if same_file.is_some_and(|old| old.committed_offset > 0) {
            store.save_cursor(&cursor)?;
        }
        if let Some(previous) = resume {
            cursor.committed_offset = previous.committed_offset;
            cursor.previous_total = previous.previous_total;
            cursor.model.clone_from(&previous.model);
        }

        file.seek(SeekFrom::Start(cursor.committed_offset as u64))?;
        let expected = (opened.size - cursor.committed_offset) as u64;
        let mut reader = BufReader::new((&mut file).take(expected));
        let mut read_bytes = 0;
        let mut line = Vec::new();
        let mut events = Vec::new();
        let mut quotas = Vec::new();
        loop {
            anyhow::ensure!(!quitting.load(Ordering::Acquire), "session scan cancelled");
            line.clear();
            let count = reader.read_until(b'\n', &mut line)?;
            if count == 0 {
                break;
            }
            read_bytes += count as u64;
            if line.last() != Some(&b'\n') {
                break;
            }
            cursor.committed_offset += count as i64;
            match parse(&line) {
                Some(Entry::Model(model)) => cursor.model = model,
                Some(Entry::Token(record)) => {
                    if let Some(quota) = record.quota.clone() {
                        quotas.push(quota);
                    }
                    if let Some(usage) = record.ingest(&mut cursor.previous_total) {
                        let day = local_day(record.occurred_at, timezone)
                            .context("invalid local date")?;
                        events.push(StoredUsageEvent {
                            signature: record.signature(),
                            occurred_at: record.occurred_at,
                            local_day: day,
                            usage,
                            model: cursor.model.clone(),
                        });
                    }
                }
                None => {}
            }
        }

        if read_bytes != expected || FileSnapshot::new(&file)? != opened {
            return Ok(0);
        }
        let inserted = store.ingest(&events, &quotas, &cursor)?;
        self.indexed.insert(path.to_path_buf(), opened);
        Ok(inserted)
    }
}

fn is_link(metadata: &Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;
        metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
    }
    #[cfg(not(windows))]
    {
        metadata.file_type().is_symlink()
    }
}

fn swift_path(path: &Path) -> String {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::ParentDir => {
                normalized.pop();
            }
            Component::CurDir => {}
            _ => normalized.push(component),
        }
    }
    normalized.to_string_lossy().into_owned()
}

#[derive(Debug, PartialEq, Eq)]
struct FileSnapshot {
    device_id: i64,
    inode: i64,
    size: i64,
    modified: std::time::SystemTime,
    changed: (i64, i64),
}

impl FileSnapshot {
    fn new(file: &File) -> Result<Self> {
        let metadata = file.metadata()?;
        anyhow::ensure!(
            metadata.is_file() && !is_link(&metadata),
            "invalid session file"
        );
        #[cfg(unix)]
        let (device_id, inode, changed) = {
            use std::os::unix::fs::MetadataExt;
            (
                metadata.dev() as i64,
                metadata.ino() as i64,
                (metadata.ctime(), metadata.ctime_nsec()),
            )
        };
        #[cfg(windows)]
        let (device_id, inode, changed) = windows_identity(file)?;
        Ok(Self {
            device_id,
            inode,
            changed,
            size: metadata.len().try_into()?,
            modified: metadata.modified()?,
        })
    }
}

#[cfg(windows)]
fn windows_identity(file: &File) -> Result<(i64, i64, (i64, i64))> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{
        BY_HANDLE_FILE_INFORMATION, FILE_BASIC_INFO, FileBasicInfo, GetFileInformationByHandle,
        GetFileInformationByHandleEx,
    };

    let mut info = BY_HANDLE_FILE_INFORMATION::default();
    let mut basic = FILE_BASIC_INFO::default();
    let handle = file.as_raw_handle();
    // 两个 Win32 API 都只填充调用方提供的结构。
    unsafe {
        if GetFileInformationByHandle(handle, &mut info) == 0
            || GetFileInformationByHandleEx(
                handle,
                FileBasicInfo,
                (&mut basic as *mut FILE_BASIC_INFO).cast(),
                std::mem::size_of::<FILE_BASIC_INFO>() as u32,
            ) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
    }
    let inode = (u64::from(info.nFileIndexHigh) << 32) | u64::from(info.nFileIndexLow);
    Ok((
        i64::from(info.dwVolumeSerialNumber),
        inode as i64,
        (basic.ChangeTime, 0),
    ))
}

#[derive(Deserialize)]
struct Envelope<'a> {
    #[serde(rename = "type")]
    kind: Option<String>,
    timestamp: Option<&'a RawValue>,
    #[serde(borrow)]
    payload: Option<&'a RawValue>,
}

#[derive(Deserialize)]
struct PayloadType {
    #[serde(rename = "type")]
    kind: Option<String>,
}

#[derive(Deserialize)]
struct TokenPayload<'a> {
    info: Option<TokenInfo>,
    #[serde(borrow)]
    rate_limits: Option<&'a RawValue>,
}

#[derive(Deserialize)]
struct TokenInfo {
    last_token_usage: Option<TokenCount>,
    total_token_usage: Option<TokenCount>,
}

#[derive(Deserialize)]
struct TokenCount {
    input_tokens: i64,
    cached_input_tokens: i64,
    output_tokens: i64,
    reasoning_output_tokens: Option<i64>,
}

impl TokenCount {
    fn validated(&self) -> Option<TokenBreakdown> {
        let usage = TokenBreakdown {
            input_tokens: self.input_tokens,
            cached_input_tokens: self.cached_input_tokens,
            output_tokens: self.output_tokens,
        };
        (usage.is_valid() && self.reasoning_output_tokens.unwrap_or(0) >= 0).then_some(usage)
    }
}

#[derive(Deserialize)]
struct LogQuota {
    limit_id: Option<String>,
    primary: Option<LogWindow>,
    secondary: Option<LogWindow>,
}

#[derive(Deserialize)]
struct LogWindow {
    used_percent: f64,
    window_minutes: i64,
    resets_at: i64,
}

impl LogQuota {
    fn snapshot(self, time: Timestamp) -> Option<QuotaSnapshot> {
        let window = [self.primary, self.secondary]
            .into_iter()
            .flatten()
            .filter(|window| {
                window.used_percent >= 0.0 && (9000..=11000).contains(&window.window_minutes)
            })
            .min_by_key(|window| ((window.window_minutes - 10080).abs(), window.resets_at))?;
        let resets_at = window.resets_at as Timestamp;
        let starts_at = resets_at - (window.window_minutes * 60) as Timestamp;
        if starts_at - time > 60.0 || time > resets_at {
            return None;
        }
        Some(QuotaSnapshot {
            limit_id: self.limit_id.unwrap_or_else(|| "codex".to_string()),
            used_percent: window.used_percent,
            window_duration_minutes: window.window_minutes,
            starts_at,
            resets_at,
            fetched_at: time,
        })
    }
}

enum Entry {
    Model(Option<String>),
    Token(TokenRecord),
}

fn parse(line: &[u8]) -> Option<Entry> {
    let envelope: Envelope<'_> = serde_json::from_slice(line).ok()?;
    let payload = envelope.payload.map_or("null", RawValue::get);
    let routing: Option<PayloadType> = serde_json::from_str(payload).ok()?;
    match (
        envelope.kind.as_deref()?,
        routing.as_ref().and_then(|route| route.kind.as_deref()),
    ) {
        ("turn_context", _) => {
            #[derive(Deserialize)]
            struct Context {
                model: Option<String>,
            }
            let model = serde_json::from_str::<Context>(payload)
                .ok()
                .and_then(|value| value.model)
                .filter(|model| {
                    (1..=128).contains(&model.len())
                        && model
                            .bytes()
                            .all(|byte| byte.is_ascii_alphanumeric() || b"._:/-".contains(&byte))
                });
            Some(Entry::Model(model))
        }
        (
            "event_msg",
            Some(
                "task_started" | "task_complete" | "turn_started" | "turn_completed"
                | "turn_aborted",
            ),
        ) => Some(Entry::Model(None)),
        ("event_msg", Some("token_count")) => {
            let timestamp: &str = serde_json::from_str(envelope.timestamp?.get()).ok()?;
            let datetime = DateTime::parse_from_rfc3339(timestamp).ok()?;
            // ISO8601DateFormatter 保留到毫秒，去重签名必须沿用同一精度。
            let occurred_at = datetime.timestamp_millis() as Timestamp / 1000.0;
            let payload: TokenPayload<'_> = serde_json::from_str(payload).ok()?;
            let (last, total) = match payload.info {
                Some(info) => (
                    match info.last_token_usage {
                        Some(value) => Some(value.validated()?),
                        None => None,
                    },
                    match info.total_token_usage {
                        Some(value) => Some(value.validated()?),
                        None => None,
                    },
                ),
                None => (None, None),
            };
            let quota = payload
                .rate_limits
                .and_then(|value| serde_json::from_str::<LogQuota>(value.get()).ok())
                .and_then(|value| value.snapshot(occurred_at));
            Some(Entry::Token(TokenRecord {
                occurred_at,
                last,
                total,
                quota,
            }))
        }
        _ => None,
    }
}

struct TokenRecord {
    occurred_at: Timestamp,
    last: Option<TokenBreakdown>,
    total: Option<TokenBreakdown>,
    quota: Option<QuotaSnapshot>,
}

impl TokenRecord {
    fn ingest(&self, previous: &mut Option<TokenBreakdown>) -> Option<TokenBreakdown> {
        let difference = match (self.total, *previous) {
            (Some(total), Some(prior)) => {
                if total == prior {
                    return None;
                }
                if total.input_tokens < prior.input_tokens
                    || total.cached_input_tokens < prior.cached_input_tokens
                    || total.output_tokens < prior.output_tokens
                {
                    Some(total)
                } else {
                    let delta = TokenBreakdown {
                        input_tokens: total.input_tokens - prior.input_tokens,
                        cached_input_tokens: total.cached_input_tokens - prior.cached_input_tokens,
                        output_tokens: total.output_tokens - prior.output_tokens,
                    };
                    if !delta.is_valid() {
                        return None;
                    }
                    Some(delta)
                }
            }
            (total, _) => total,
        };
        let usage = self.last.or(difference)?;
        *previous = self.total.or(*previous);
        Some(usage)
    }

    fn signature(&self) -> Vec<u8> {
        fn stable(usage: Option<TokenBreakdown>) -> String {
            match usage {
                None => "none".to_string(),
                Some(value) => format!(
                    "{},{},{}",
                    value.input_tokens, value.cached_input_tokens, value.output_tokens
                ),
            }
        }
        let variant = match (self.last, self.total) {
            (Some(_), Some(_)) => "last+total",
            (Some(_), None) => "last",
            (None, Some(_)) => "total",
            (None, None) => "none",
        };
        let milliseconds = (self.occurred_at * 1000.0).round() as i64;
        Sha256::digest(format!(
            "timestampMs={milliseconds}|schema={variant}|last={}|total={}",
            stable(self.last),
            stable(self.total),
        ))
        .to_vec()
    }
}

#[cfg(test)]
mod tests;
