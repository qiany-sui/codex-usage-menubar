use chrono::{DateTime, NaiveDate, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::time::{SystemTime, UNIX_EPOCH};

pub type Timestamp = f64;

pub fn unix_seconds(time: SystemTime) -> Timestamp {
    match time.duration_since(UNIX_EPOCH) {
        Ok(elapsed) => elapsed.as_secs_f64(),
        Err(error) => -error.duration().as_secs_f64(),
    }
}

pub fn instant(time: Timestamp) -> Option<DateTime<Utc>> {
    if !time.is_finite() {
        return None;
    }
    let whole = time.floor();
    let nanos = ((time - whole) * 1_000_000_000.0).floor() as u32;
    DateTime::from_timestamp(whole as i64, nanos)
}

pub fn local_day(time: Timestamp, timezone: &impl TimeZone) -> Option<NaiveDate> {
    Some(instant(time)?.with_timezone(timezone).date_naive())
}

#[derive(Debug, Copy, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenBreakdown {
    pub input_tokens: i64,
    pub cached_input_tokens: i64,
    pub output_tokens: i64,
}

impl TokenBreakdown {
    pub fn saturating_add(self, other: Self) -> Self {
        Self {
            input_tokens: self.input_tokens.saturating_add(other.input_tokens),
            cached_input_tokens: self
                .cached_input_tokens
                .saturating_add(other.cached_input_tokens),
            output_tokens: self.output_tokens.saturating_add(other.output_tokens),
        }
    }

    pub fn total(self) -> i64 {
        self.input_tokens.saturating_add(self.output_tokens)
    }

    pub fn is_valid(self) -> bool {
        self.cached_input_tokens >= 0
            && self.cached_input_tokens <= self.input_tokens
            && self.output_tokens >= 0
    }
}

#[derive(Debug, Copy, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Status {
    LocalLive,
    Calibrated,
    PartiallyCalibrated,
    Stale,
    Unavailable,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaSnapshot {
    pub limit_id: String,
    pub used_percent: f64,
    pub window_duration_minutes: i64,
    pub starts_at: Timestamp,
    pub resets_at: Timestamp,
    pub fetched_at: Timestamp,
}

impl QuotaSnapshot {
    pub fn is_stale(&self, now: Timestamp) -> bool {
        let age = now - self.fetched_at;
        now >= self.resets_at || !age.is_finite() || age.abs() > 600.0
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct QuotaReading {
    pub quota: QuotaSnapshot,
    pub is_from_session: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelTokenUsage {
    pub model: Option<String>,
    pub usage: TokenBreakdown,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaConsumptionSegment {
    pub starts_at: Timestamp,
    pub ends_at: Timestamp,
    pub consumed_percent: Option<f64>,
    pub starts_with_reset: bool,
    pub recorded_consumed_percent: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageDay {
    pub day: NaiveDate,
    pub local_usage: TokenBreakdown,
    pub official_tokens: Option<i64>,
    pub displayed_tokens: i64,
    pub status: Status,
    pub quota_consumed_percent: Option<f64>,
    pub quota_segments: Option<Vec<QuotaConsumptionSegment>>,
    pub recorded_quota_consumed_percent: Option<f64>,
    pub model_usage: Option<Vec<ModelTokenUsage>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CycleUsageDay {
    pub day: NaiveDate,
    pub starts_at: Timestamp,
    pub ends_at: Timestamp,
    pub displayed_tokens: i64,
    pub status: Status,
    pub quota_consumed_percent: Option<f64>,
    pub recorded_quota_consumed_percent: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaCycle {
    pub starts_at: Timestamp,
    pub ends_at: Timestamp,
    pub usage: TokenBreakdown,
    pub displayed_tokens: i64,
    pub status: Status,
    pub boundary_is_estimated: bool,
    pub quota_used_percent: Option<f64>,
    pub last_recorded_quota: Option<QuotaSnapshot>,
    pub daily_usage: Option<Vec<CycleUsageDay>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageSnapshot {
    pub quota: Option<QuotaSnapshot>,
    pub today: UsageDay,
    pub current_cycle: Option<QuotaCycle>,
    pub recent_days: Vec<UsageDay>,
    pub cycle_history: Vec<QuotaCycle>,
    pub last_updated_at: Timestamp,
    pub status: Status,
    pub quota_refresh_failed: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct StoredUsageEvent {
    pub signature: Vec<u8>,
    pub occurred_at: Timestamp,
    pub local_day: NaiveDate,
    pub usage: TokenBreakdown,
    pub model: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FileCursor {
    pub path_hash: Vec<u8>,
    pub device_id: i64,
    pub inode: i64,
    pub committed_offset: i64,
    pub previous_total: Option<TokenBreakdown>,
    pub model: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct OfficialUsageDay {
    pub day: NaiveDate,
    pub tokens: i64,
    pub fetched_at: Timestamp,
}

#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash)]
pub enum FailureSource {
    AccountInitialization,
    RateLimits,
    OfficialUsage,
    SessionIndexing,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct RefreshState {
    pub last_successful_quota_refresh_at: Option<Timestamp>,
    pub last_successful_official_usage_refresh_at: Option<Timestamp>,
    pub consecutive_failure_count: i64,
    pub failed_sources: HashSet<FailureSource>,
}
