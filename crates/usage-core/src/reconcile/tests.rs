use super::*;
use crate::model::QuotaReading;
use chrono::{FixedOffset, Utc};

const DAY: f64 = 86_400.0;
const MIDNIGHT: f64 = 20_000.0 * DAY;

fn quota(start: Timestamp, used_percent: f64, fetched_at: Timestamp) -> QuotaSnapshot {
    QuotaSnapshot {
        limit_id: "codex".into(),
        used_percent,
        window_duration_minutes: 10_080,
        starts_at: start,
        resets_at: start + 7.0 * DAY,
        fetched_at,
    }
}

fn event(time: Timestamp, tokens: i64, model: Option<&str>) -> StoredUsageEvent {
    StoredUsageEvent {
        signature: Vec::new(),
        occurred_at: time,
        local_day: local_day(time, &Utc).unwrap(),
        usage: TokenBreakdown {
            input_tokens: tokens,
            ..TokenBreakdown::default()
        },
        model: model.map(str::to_owned),
    }
}

#[test]
fn coalesces_a_delayed_start_correction_without_merging_a_real_close_reset() {
    let start = MIDNIGHT + 60.0;
    let reset = start + 30.0;
    let corrected = reset + 64.0;
    let first = quota(start, 5.0, start + 15.0);
    let history = [
        first.clone(),
        quota(start, 0.0, reset - 1.0),
        quota(reset, 0.0, reset),
    ];
    let latest = quota(corrected, 2.0, corrected + 1_800.0);
    let events = [event(start + 10.0, 12, None), event(reset, 14, None)];
    let before = update_cycles(&[], &first, &events, &[]);
    let cycles = update_cycles(&before, &latest, &events, &history);
    let observed: Vec<_> = cycles
        .iter()
        .filter(|cycle| !cycle.boundary_is_estimated)
        .map(|cycle| (cycle.starts_at, cycle.displayed_tokens))
        .collect();
    assert_eq!(observed, [(start, 12), (reset, 14)]);
    assert_eq!(cycles.len(), 9);
}

#[test]
fn excludes_session_hints_beyond_their_next_official_ceiling() {
    let reading = |used, seconds, is_from_session| QuotaReading {
        quota: quota(MIDNIGHT, used, MIDNIGHT + seconds),
        is_from_session,
    };
    let readings = vec![
        reading(36.0, 0.0, false),
        reading(37.0, 60.0, true),
        reading(80.0, 90.0, true),
        reading(37.0, 120.0, false),
        reading(0.0, 180.0, false),
        reading(5.0, 240.0, false),
        reading(6.0, 300.0, true),
    ];
    let history = reconciled_session_quota_history(readings);
    assert_eq!(
        history
            .iter()
            .map(|quota| quota.used_percent)
            .collect::<Vec<_>>(),
        [36.0, 37.0, 37.0, 0.0, 5.0],
    );
}

#[test]
fn daily_quota_preserves_verified_usage_on_either_side_of_an_early_reset() {
    let reset = MIDNIGHT + 21_600.0;
    let yesterday = MIDNIGHT - 3.0 * DAY;
    let history = [
        quota(yesterday, 46.0, MIDNIGHT - 120.0),
        quota(yesterday, 98.0, reset - 300.0),
        quota(reset, 0.0, reset - 2.0),
        quota(reset + 64.0, 0.0, reset + 84.0),
    ];
    let now = MIDNIGHT + 43_200.0;
    let latest = quota(reset + 64.0, 6.0, now);
    let result = snapshot(
        SnapshotInput {
            now,
            quota: Some(&latest),
            events: &[],
            official_days: &[],
            cycles: &[],
            last_updated_at: now,
            quota_history: &history,
            failed_sources: &HashSet::new(),
        },
        &Utc,
    );
    assert_eq!(result.today.quota_consumed_percent, Some(58.0));
    let segments = result.today.quota_segments.unwrap();
    assert_eq!(segments.len(), 2);
    assert_eq!(segments[0].ends_at, reset);
    assert_eq!(segments[0].consumed_percent, Some(52.0));
    assert!(!segments[0].starts_with_reset);
    assert_eq!(segments[1].starts_at, reset);
    assert_eq!(segments[1].consumed_percent, Some(6.0));
    assert!(segments[1].starts_with_reset);
}

#[test]
fn only_full_past_days_accept_official_totals_and_keep_local_model_usage() {
    let timezone = FixedOffset::east_opt(8 * 3600).unwrap();
    let today_start = MIDNIGHT - 8.0 * 3600.0;
    let now = today_start + 3600.0;
    let start = today_start - 1.5 * DAY;
    let latest = quota(start, 3.0, now);
    let mut events = [
        event(start, 7, Some("model-b")),
        event(today_start - DAY + 60.0, 5, Some("model-a")),
        event(today_start - DAY + 120.0, 4, None),
        event(now, 3, Some("model-b")),
    ];
    for event in &mut events {
        event.local_day = local_day(event.occurred_at, &timezone).unwrap();
    }
    let [first_day, full_day, _, today] = events.clone().map(|event| event.local_day);
    let official_days = [
        OfficialUsageDay {
            day: first_day,
            tokens: 100,
            fetched_at: now,
        },
        OfficialUsageDay {
            day: full_day,
            tokens: 20,
            fetched_at: now,
        },
        OfficialUsageDay {
            day: today,
            tokens: 8,
            fetched_at: now,
        },
    ];
    let cycles = update_cycles(&[], &latest, &events, &[]);
    let result = snapshot(
        SnapshotInput {
            now,
            quota: Some(&latest),
            events: &events,
            official_days: &official_days,
            cycles: &cycles,
            last_updated_at: now,
            quota_history: &[],
            failed_sources: &HashSet::new(),
        },
        &timezone,
    );
    assert_eq!(result.recent_days.len(), 7);
    assert_eq!(result.cycle_history.len(), 8);
    assert_eq!(result.today.day, today);
    assert_eq!(result.today.displayed_tokens, 3);
    assert_eq!(result.today.official_tokens, Some(8));
    assert_eq!(result.recent_days[5].displayed_tokens, 20);
    let models = result.recent_days[5].model_usage.as_ref().unwrap();
    assert_eq!(models[0].model.as_deref(), Some("model-a"));
    assert_eq!(models[0].usage.total(), 5);
    assert_eq!(models[1].model, None);
    let cycle = result.current_cycle.unwrap();
    assert_eq!(cycle.displayed_tokens, 30);
    let slices = cycle.daily_usage.unwrap();
    assert_eq!(
        slices
            .iter()
            .map(|slice| slice.displayed_tokens)
            .collect::<Vec<_>>(),
        [7, 20, 3]
    );
    assert_eq!(result.status, Status::PartiallyCalibrated);
}

#[test]
fn latest_official_conflicts_leave_local_totals_saturated_and_do_not_mark_quota_refresh_failed() {
    let old_day = local_day(MIDNIGHT - DAY, &Utc).unwrap();
    let now = MIDNIGHT + 360.0;
    let latest = quota(MIDNIGHT - DAY, 2.0, now);
    let events = [
        event(MIDNIGHT - DAY + 20.0, i64::MAX, Some("test")),
        event(MIDNIGHT - DAY + 30.0, 150, Some("test")),
    ];
    let official_days = [
        OfficialUsageDay {
            day: old_day,
            tokens: 12,
            fetched_at: now,
        },
        OfficialUsageDay {
            day: old_day,
            tokens: 11,
            fetched_at: now - 60.0,
        },
        OfficialUsageDay {
            day: old_day,
            tokens: 14,
            fetched_at: now,
        },
    ];
    let cycles = update_cycles(&[], &latest, &events, &[]);
    let result = snapshot(
        SnapshotInput {
            now,
            quota: Some(&latest),
            events: &events,
            official_days: &official_days,
            cycles: &cycles,
            last_updated_at: now,
            quota_history: &[],
            failed_sources: &HashSet::from([FailureSource::OfficialUsage]),
        },
        &Utc,
    );
    assert_eq!(result.recent_days[5].official_tokens, None);
    assert_eq!(result.recent_days[5].displayed_tokens, i64::MAX);
    assert_eq!(result.current_cycle.unwrap().displayed_tokens, i64::MAX);
    assert_eq!(result.status, Status::Stale);
    assert!(!result.quota_refresh_failed);
}

#[test]
fn early_reset_keeps_partial_day_and_cycle_quota_separate() {
    let start = MIDNIGHT - 2.0 * DAY;
    let reset = MIDNIGHT + 21_600.0;
    let now = MIDNIGHT + 43_200.0;
    let first = quota(start, 30.0, MIDNIGHT - 120.0);
    let last = quota(start, 45.0, MIDNIGHT + 10_800.0);
    let latest = quota(reset, 20.0, now);
    let history = [first.clone(), last.clone()];
    let before = update_cycles(&[], &first, &[], &[]);
    let cycles = update_cycles(&before, &latest, &[], &history);
    let result = snapshot(
        SnapshotInput {
            now,
            quota: Some(&latest),
            events: &[],
            official_days: &[],
            cycles: &cycles,
            last_updated_at: now,
            quota_history: &history,
            failed_sources: &HashSet::new(),
        },
        &Utc,
    );
    assert_eq!(result.today.quota_consumed_percent, None);
    let segments = result.today.quota_segments.unwrap();
    assert_eq!(segments[0].consumed_percent, None);
    assert_eq!(segments[0].recorded_consumed_percent, Some(15.0));
    assert_eq!(segments[1].consumed_percent, Some(20.0));
    let completed = &result.cycle_history[0];
    assert_eq!(completed.ends_at, reset);
    assert_eq!(completed.quota_used_percent, None);
    assert_eq!(completed.last_recorded_quota.as_ref(), Some(&last));
    assert_eq!(result.current_cycle.unwrap().quota_used_percent, Some(20.0));
}

#[test]
fn cycle_preserves_tokens_when_the_ingestion_timezone_has_changed() {
    let now = MIDNIGHT + 43_200.0;
    let latest = quota(MIDNIGHT - DAY, 3.0, now);
    let events = [event(MIDNIGHT - 3_600.0, 17, None)];
    let cycles = update_cycles(&[], &latest, &events, &[]);
    let result = snapshot(
        SnapshotInput {
            now,
            quota: Some(&latest),
            events: &events,
            official_days: &[],
            cycles: &cycles,
            last_updated_at: now,
            quota_history: &[],
            failed_sources: &HashSet::new(),
        },
        &FixedOffset::east_opt(8 * 3600).unwrap(),
    );
    assert_eq!(result.recent_days[5].displayed_tokens, 17);
    assert_eq!(result.today.displayed_tokens, 0);
    let cycle = result.current_cycle.unwrap();
    assert_eq!(cycle.displayed_tokens, 17);
    assert_eq!(cycle.daily_usage, None);
}
