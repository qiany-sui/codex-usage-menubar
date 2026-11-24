use crate::model::{
    CycleUsageDay, FailureSource, ModelTokenUsage, OfficialUsageDay, QuotaCycle, QuotaSnapshot,
    Status, StoredUsageEvent, Timestamp, TokenBreakdown, UsageDay, UsageSnapshot, local_day,
};
use chrono::{LocalResult, NaiveDate, NaiveTime, TimeDelta, TimeZone};
use std::collections::{BTreeMap, HashMap, HashSet, hash_map::Entry};

mod cycles;
mod quota;
#[cfg(test)]
mod tests;

pub use cycles::{reconciled_session_quota_history, update_cycles};
use quota::QuotaObservations;

const CYCLE_HISTORY_COUNT: usize = 8;
const NEARBY_READING_SECONDS: f64 = 600.0;

pub struct SnapshotInput<'a> {
    pub now: Timestamp,
    pub quota: Option<&'a QuotaSnapshot>,
    pub events: &'a [StoredUsageEvent],
    pub official_days: &'a [OfficialUsageDay],
    pub cycles: &'a [QuotaCycle],
    pub last_updated_at: Timestamp,
    pub quota_history: &'a [QuotaSnapshot],
    pub failed_sources: &'a HashSet<FailureSource>,
}

pub fn snapshot(input: SnapshotInput<'_>, timezone: &impl TimeZone) -> UsageSnapshot {
    let today =
        local_day(input.now, timezone).unwrap_or_else(|| NaiveDate::from_ymd_opt(1, 1, 1).unwrap());
    let today_start = day_start(today, timezone).unwrap_or(input.now);
    let usage_by_day = aggregate_by_day_and_model(input.events);
    let official_by_day = latest_official_days(input.official_days);
    let observations =
        QuotaObservations::new(input.quota, input.quota_history, input.now, input.cycles);
    let mut recent_days = Vec::new();
    let dates = today
        .iter_days()
        .rev()
        .filter_map(|date| day_start(date, timezone).map(|start| (date, start)));
    let mut next_start = next_day_start(today, timezone).map(|(_, start)| start);
    for (date, start) in dates.take(7) {
        let mut day = usage_day(
            date,
            today,
            usage_by_day.get(&date),
            official_by_day.get(&date).copied(),
        );
        if let Some(next) = next_start {
            observations.apply_to_day(&mut day, start, next.min(input.now));
        }
        next_start = Some(start);
        recent_days.push(day);
    }
    recent_days.reverse();
    let today = recent_days.last().cloned().unwrap_or_else(|| {
        usage_day(
            today,
            today,
            usage_by_day.get(&today),
            official_by_day.get(&today).copied(),
        )
    });

    let mut current_cycle: Option<QuotaCycle> = None;
    let mut cycle_history = Vec::new();
    for cycle in input.cycles.iter().filter(|cycle| {
        cycle.starts_at.is_finite() && cycle.ends_at.is_finite() && cycle.starts_at < cycle.ends_at
    }) {
        if cycle.starts_at > input.now {
            continue;
        }
        let reconciled = reconcile_cycle(
            cycle,
            input.events,
            input.now,
            today_start,
            timezone,
            &official_by_day,
            &observations,
        );
        if reconciled.ends_at <= input.now {
            cycle_history.push(reconciled);
        } else if reconciled.starts_at <= input.now
            && input.now < reconciled.ends_at
            && current_cycle
                .as_ref()
                .is_none_or(|current| current.starts_at < reconciled.starts_at)
        {
            current_cycle = Some(reconciled);
        }
    }
    cycle_history.sort_by(|left, right| right.starts_at.total_cmp(&left.starts_at));
    cycle_history.truncate(CYCLE_HISTORY_COUNT);
    let status = if input.failed_sources.is_empty() {
        match input.quota {
            None => Status::Unavailable,
            Some(quota) if quota.is_stale(input.now) => Status::Stale,
            Some(_)
                if current_cycle
                    .as_ref()
                    .is_some_and(|cycle| cycle.status == Status::PartiallyCalibrated) =>
            {
                Status::PartiallyCalibrated
            }
            Some(_) => Status::LocalLive,
        }
    } else {
        Status::Stale
    };
    UsageSnapshot {
        quota: input.quota.cloned(),
        today,
        current_cycle,
        recent_days,
        cycle_history,
        last_updated_at: input.last_updated_at,
        status,
        quota_refresh_failed: input.failed_sources.contains(&FailureSource::RateLimits)
            || input
                .failed_sources
                .contains(&FailureSource::AccountInitialization),
    }
}

type UsageByModel<'a> = HashMap<Option<&'a str>, TokenBreakdown>;

fn aggregate_by_day_and_model(events: &[StoredUsageEvent]) -> HashMap<NaiveDate, UsageByModel<'_>> {
    let mut days: HashMap<NaiveDate, UsageByModel<'_>> = HashMap::new();
    for event in events
        .iter()
        .filter(|event| event.usage != TokenBreakdown::default())
    {
        let usage = days
            .entry(event.local_day)
            .or_default()
            .entry(event.model.as_deref())
            .or_default();
        *usage = usage.saturating_add(event.usage);
    }
    days
}

fn usage_day(
    date: NaiveDate,
    today: NaiveDate,
    by_model: Option<&UsageByModel<'_>>,
    official_tokens: Option<i64>,
) -> UsageDay {
    let mut model_usage: Vec<_> = by_model
        .into_iter()
        .flatten()
        .map(|(&model, &usage)| ModelTokenUsage {
            model: model.map(str::to_owned),
            usage,
        })
        .collect();
    model_usage.sort_by(|left, right| {
        left.model
            .is_none()
            .cmp(&right.model.is_none())
            .then_with(|| right.usage.total().cmp(&left.usage.total()))
            .then_with(|| left.model.cmp(&right.model))
    });
    let local_usage = model_usage
        .iter()
        .fold(TokenBreakdown::default(), |total, model| {
            total.saturating_add(model.usage)
        });
    let calibrated = if date < today { official_tokens } else { None };
    UsageDay {
        day: date,
        local_usage,
        official_tokens,
        displayed_tokens: calibrated.unwrap_or_else(|| local_usage.total()),
        status: if calibrated.is_some() {
            Status::Calibrated
        } else {
            Status::LocalLive
        },
        quota_consumed_percent: None,
        quota_segments: None,
        recorded_quota_consumed_percent: None,
        model_usage: (!model_usage.is_empty()).then_some(model_usage),
    }
}

fn latest_official_days(days: &[OfficialUsageDay]) -> HashMap<NaiveDate, i64> {
    let mut latest: HashMap<_, (_, Option<_>)> = HashMap::new();
    for day in days.iter().filter(|day| day.fetched_at.is_finite()) {
        match latest.entry(day.day) {
            Entry::Vacant(entry) => {
                entry.insert((day.fetched_at, Some(day.tokens)));
            }
            Entry::Occupied(mut entry) => {
                let (fetched_at, tokens) = entry.get_mut();
                if day.fetched_at > *fetched_at {
                    *fetched_at = day.fetched_at;
                    *tokens = Some(day.tokens);
                } else if day.fetched_at == *fetched_at && *tokens != Some(day.tokens) {
                    *tokens = None;
                }
            }
        }
    }
    latest
        .into_iter()
        .filter_map(|(day, (_, tokens))| tokens.map(|tokens| (day, tokens)))
        .collect()
}

fn reconcile_cycle(
    original: &QuotaCycle,
    events: &[StoredUsageEvent],
    now: Timestamp,
    today_start: Timestamp,
    timezone: &impl TimeZone,
    official_by_day: &HashMap<NaiveDate, i64>,
    observations: &QuotaObservations,
) -> QuotaCycle {
    let matching_start = observations.matching_start(original, now);
    let (quota_used_percent, last_recorded_quota) = matching_start
        .map(|start| observations.cycle_percent(original, now, start))
        .unwrap_or_default();
    let mut cycle = QuotaCycle {
        displayed_tokens: original.usage.total(),
        status: Status::LocalLive,
        quota_used_percent,
        last_recorded_quota,
        daily_usage: None,
        ..original.clone()
    };
    let mut local_by_day = BTreeMap::new();
    let mut local_total = TokenBreakdown::default();
    let mut stored_days_match_calendar = true;
    for event in cycle_events(original, events) {
        let usage = local_by_day
            .entry(event.local_day)
            .or_insert_with(TokenBreakdown::default);
        *usage = usage.saturating_add(event.usage);
        local_total = local_total.saturating_add(event.usage);
        stored_days_match_calendar &=
            local_day(event.occurred_at, timezone) == Some(event.local_day);
    }
    if local_total != cycle.usage {
        return cycle;
    }

    let mut displayed_by_day: BTreeMap<_, _> = local_by_day
        .into_iter()
        .map(|(day, usage)| (day, usage.total()))
        .collect();
    let mut daily_usage = Vec::new();
    let mut replaced_days = 0;
    let usage_end = cycle.ends_at.min(now);
    let mut day_boundary = local_day(cycle.starts_at, timezone)
        .and_then(|date| day_start(date, timezone).map(|start| (date, start)));
    while let Some((date, start)) = day_boundary.filter(|(_, start)| *start < usage_end) {
        let Some(next @ (_, next_start)) = next_day_start(date, timezone) else {
            break;
        };
        let slice_start = start.max(cycle.starts_at);
        let slice_end = next_start.min(usage_end);
        if slice_start >= slice_end {
            break;
        }
        let mut status = Status::LocalLive;
        if cycle.starts_at <= start
            && next_start <= cycle.ends_at
            && next_start <= today_start
            && let Some(&official_tokens) = official_by_day.get(&date)
        {
            displayed_by_day.insert(date, official_tokens);
            replaced_days += 1;
            status = Status::Calibrated;
        }
        let consumption = matching_start.map(|_| {
            observations.segment(
                slice_start,
                slice_end,
                slice_start == cycle.starts_at,
                slice_end == cycle.ends_at,
                matching_start,
            )
        });
        daily_usage.push(CycleUsageDay {
            day: date,
            starts_at: slice_start,
            ends_at: slice_end,
            displayed_tokens: displayed_by_day.get(&date).copied().unwrap_or(0),
            status,
            quota_consumed_percent: consumption
                .as_ref()
                .and_then(|segment| segment.consumed_percent),
            recorded_quota_consumed_percent: consumption
                .and_then(|segment| segment.recorded_consumed_percent),
        });
        day_boundary = Some(next);
    }

    cycle.displayed_tokens = displayed_by_day
        .values()
        .copied()
        .fold(0, i64::saturating_add);
    // 原记录的日期可能来自旧时区，无法按当天时区分配时保留汇总。
    let has_daily_usage = stored_days_match_calendar
        && daily_usage
            .iter()
            .map(|day| day.displayed_tokens)
            .fold(0, i64::saturating_add)
            == cycle.displayed_tokens;
    if replaced_days > 0 {
        cycle.status = if has_daily_usage
            && daily_usage
                .iter()
                .all(|day| day.status == Status::Calibrated)
        {
            Status::Calibrated
        } else {
            Status::PartiallyCalibrated
        };
    }
    cycle.daily_usage = has_daily_usage.then_some(daily_usage);
    cycle
}

fn cycle_events<'a>(
    cycle: &QuotaCycle,
    events: &'a [StoredUsageEvent],
) -> impl Iterator<Item = &'a StoredUsageEvent> + use<'a> {
    let starts_at = cycle.starts_at;
    let ends_at = cycle.ends_at;
    events
        .iter()
        .filter(move |event| starts_at <= event.occurred_at && event.occurred_at < ends_at)
}

fn day_start(day: NaiveDate, timezone: &impl TimeZone) -> Option<Timestamp> {
    let midnight = day.and_time(NaiveTime::MIN);
    let at = |seconds| {
        let local = midnight + TimeDelta::seconds(seconds);
        // 整天被跳过时，时区库也可能返回偏移，需往返确认日期和时间。
        let matches =
            |instant: &chrono::DateTime<_>| instant.with_timezone(timezone).naive_local() == local;
        match timezone.from_local_datetime(&local) {
            LocalResult::None => None,
            LocalResult::Single(instant) => Some(instant).filter(matches),
            LocalResult::Ambiguous(earliest, latest) => Some(earliest)
                .filter(matches)
                .or_else(|| Some(latest).filter(matches)),
        }
    };
    if let Some(start) = at(0) {
        return Some(start.timestamp() as Timestamp);
    }
    // 遇到跨午夜的 DST 时，使用本地日期内第一秒有效时间。
    let minute = (60..86_400)
        .step_by(60)
        .find(|&seconds| at(seconds).is_some());
    let end = minute.unwrap_or(86_399);
    (end - 59..=end)
        .find_map(at)
        .map(|start| start.timestamp() as Timestamp)
}

fn next_day_start(day: NaiveDate, timezone: &impl TimeZone) -> Option<(NaiveDate, Timestamp)> {
    day.iter_days()
        .skip(1)
        .find_map(|date| day_start(date, timezone).map(|start| (date, start)))
}

fn timestamp_key(time: Timestamp) -> u64 {
    if time == 0.0 { 0 } else { time.to_bits() }
}
