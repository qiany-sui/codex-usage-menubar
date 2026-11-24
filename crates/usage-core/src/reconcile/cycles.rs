use super::{CYCLE_HISTORY_COUNT, NEARBY_READING_SECONDS, cycle_events, timestamp_key};
use crate::model::{QuotaCycle, QuotaReading, QuotaSnapshot, Status, StoredUsageEvent, Timestamp};
use std::collections::{BTreeMap, HashMap};

pub(super) const RESET_TOLERANCE_SECONDS: f64 = 60.0;

pub fn update_cycles(
    existing: &[QuotaCycle],
    quota: &QuotaSnapshot,
    events: &[StoredUsageEvent],
    quota_history: &[QuotaSnapshot],
) -> Vec<QuotaCycle> {
    let reset_starts = observed_reset_starts(quota, quota_history);
    let quota_start = corrected_start(quota.starts_at, &reset_starts);
    let mut cycles = normalize(existing, &reset_starts);

    if let Some(current) = cycles.last_mut() {
        if same_reset(current.starts_at, quota_start, &reset_starts) {
            current.ends_at = quota.resets_at;
            current.boundary_is_estimated = false;
        } else if quota_start > current.starts_at {
            current.ends_at = current.ends_at.min(quota_start);
            cycles.push(empty_cycle(quota_start, quota.resets_at, false));
        }
    } else {
        cycles.push(empty_cycle(quota_start, quota.resets_at, false));
    }

    let max_cycles = CYCLE_HISTORY_COUNT + 1;
    if (9_000..=11_000).contains(&quota.window_duration_minutes) {
        let duration = quota.window_duration_minutes as f64 * 60.0;
        while cycles.len() < max_cycles {
            let end = cycles[0].starts_at;
            let start = end - duration;
            if !start.is_finite() {
                break;
            }
            cycles.insert(0, empty_cycle(start, end, true));
        }
    }

    cycles.drain(..cycles.len().saturating_sub(max_cycles));
    for cycle in &mut cycles {
        cycle.usage = cycle_events(cycle, events).fold(Default::default(), |usage, event| {
            usage.saturating_add(event.usage)
        });
        cycle.displayed_tokens = cycle.usage.total();
    }
    cycles
}

pub(super) fn observed_reset_starts(
    quota: &QuotaSnapshot,
    history: &[QuotaSnapshot],
) -> HashMap<u64, Timestamp> {
    let mut observations: Vec<_> = history
        .iter()
        .chain(std::iter::once(quota))
        .filter(|reading| {
            reading.limit_id == quota.limit_id
                && reading.fetched_at <= quota.fetched_at
                && reading.used_percent.is_finite()
                && reading.used_percent >= 0.0
        })
        .collect();
    observations.sort_by(|left, right| left.fetched_at.total_cmp(&right.fetched_at));

    let mut starts = HashMap::new();
    let mut previous: Option<&QuotaSnapshot> = None;
    let mut reset_start = quota.starts_at;
    let mut has_consumed_quota = false;
    for reading in observations {
        let key = timestamp_key(reading.starts_at);
        // 迟到的旧周期记录不能回退已经确认的重置状态。
        if starts.get(&key).is_some_and(|known| *known < reset_start) {
            continue;
        }
        let continues_reset = previous.is_some_and(|previous| {
            if previous.window_duration_minutes != reading.window_duration_minutes {
                return false;
            }
            let difference = reading.starts_at - previous.starts_at;
            // 服务端可能先清零、再更新起点，所以查看整个周期是否曾消耗额度。
            let consumed_then_reset =
                difference > 0.0 && has_consumed_quota && reading.used_percent == 0.0;
            let boundary_gap = reading.starts_at - previous.fetched_at;
            // 起点紧接上一笔零读数时，采集延迟也不会把一次重置分成两次。
            let pending_correction = !has_consumed_quota
                && difference > 0.0
                && reading.starts_at < previous.resets_at
                && (reading.fetched_at - previous.fetched_at <= NEARBY_READING_SECONDS
                    || (0.0..=NEARBY_READING_SECONDS).contains(&boundary_gap));
            !consumed_then_reset
                && (difference.abs() <= RESET_TOLERANCE_SECONDS || pending_correction)
        });
        if !continues_reset {
            reset_start = reading.starts_at;
            has_consumed_quota = false;
        }
        starts.insert(key, reset_start);
        has_consumed_quota |= reading.used_percent > 0.0;
        previous = Some(reading);
    }
    starts
}

pub(super) fn corrected_start(
    start: Timestamp,
    reset_starts: &HashMap<u64, Timestamp>,
) -> Timestamp {
    reset_starts
        .get(&timestamp_key(start))
        .copied()
        .unwrap_or(start)
}

fn same_reset(left: Timestamp, right: Timestamp, reset_starts: &HashMap<u64, Timestamp>) -> bool {
    match (
        reset_starts.get(&timestamp_key(left)),
        reset_starts.get(&timestamp_key(right)),
    ) {
        (Some(left), Some(right)) => left == right,
        _ => (left - right).abs() <= RESET_TOLERANCE_SECONDS,
    }
}

fn normalize(existing: &[QuotaCycle], reset_starts: &HashMap<u64, Timestamp>) -> Vec<QuotaCycle> {
    let mut sorted: Vec<_> = existing
        .iter()
        .map(|cycle| {
            empty_cycle(
                corrected_start(cycle.starts_at, reset_starts),
                cycle.ends_at,
                cycle.boundary_is_estimated,
            )
        })
        .collect();
    sorted.sort_by(|left, right| {
        left.starts_at
            .total_cmp(&right.starts_at)
            .then_with(|| left.ends_at.total_cmp(&right.ends_at))
            .then_with(|| left.boundary_is_estimated.cmp(&right.boundary_is_estimated))
    });

    let mut merged: Vec<QuotaCycle> = Vec::new();
    for candidate in sorted {
        if let Some(current) = merged.last_mut()
            && same_reset(current.starts_at, candidate.starts_at, reset_starts)
        {
            current.ends_at = current.ends_at.max(candidate.ends_at);
            current.boundary_is_estimated &= candidate.boundary_is_estimated;
        } else {
            merged.push(candidate);
        }
    }
    for index in 1..merged.len() {
        let next_start = merged[index].starts_at;
        let cycle = &mut merged[index - 1];
        cycle.ends_at = cycle.ends_at.min(next_start);
    }
    merged
}

fn empty_cycle(
    starts_at: Timestamp,
    ends_at: Timestamp,
    boundary_is_estimated: bool,
) -> QuotaCycle {
    QuotaCycle {
        starts_at,
        ends_at,
        usage: Default::default(),
        displayed_tokens: 0,
        status: Status::LocalLive,
        boundary_is_estimated,
        quota_used_percent: None,
        last_recorded_quota: None,
        daily_usage: None,
    }
}

pub fn reconciled_session_quota_history(readings: Vec<QuotaReading>) -> Vec<QuotaSnapshot> {
    let official: Vec<_> = readings
        .iter()
        .filter(|reading| !reading.is_from_session)
        .map(|reading| reading.quota.clone())
        .collect();
    let Some(latest) = official.last() else {
        return Vec::new();
    };
    let reset_starts = observed_reset_starts(latest, &official);
    let mut starts: Vec<_> = reset_starts.values().copied().collect();
    starts.sort_by(f64::total_cmp);
    starts.dedup();
    let next_starts: HashMap<_, _> = starts
        .windows(2)
        .map(|pair| (timestamp_key(pair[0]), pair[1]))
        .collect();
    let mut groups: BTreeMap<u64, Vec<QuotaReading>> = BTreeMap::new();
    let mut session_starts = HashMap::new();

    for reading in readings {
        let quota = &reading.quota;
        let start = if reading.is_from_session {
            // 会话日志只补充主动读取确认的周期和时间范围。
            if quota.fetched_at > latest.fetched_at {
                continue;
            }
            let key = timestamp_key(quota.starts_at);
            if let Some(start) = session_starts.get(&key) {
                *start
            } else {
                let Some(anchor) = official.iter().min_by(|left, right| {
                    (left.starts_at - quota.starts_at)
                        .abs()
                        .total_cmp(&(right.starts_at - quota.starts_at).abs())
                }) else {
                    continue;
                };
                let anchored = anchor.window_duration_minutes == quota.window_duration_minutes
                    && (anchor.starts_at - quota.starts_at).abs() <= RESET_TOLERANCE_SECONDS;
                if !anchored {
                    continue;
                }
                let start = corrected_start(anchor.starts_at, &reset_starts);
                session_starts.insert(key, start);
                start
            }
        } else {
            corrected_start(quota.starts_at, &reset_starts)
        };
        let key = timestamp_key(start);
        if reading.is_from_session {
            let in_range = start - quota.fetched_at <= RESET_TOLERANCE_SECONDS
                && next_starts
                    .get(&key)
                    .is_none_or(|end| quota.fetched_at < *end);
            if !in_range {
                continue;
            }
        }
        groups.entry(key).or_default().push(reading);
    }

    let mut result = Vec::new();
    for (start, mut group) in groups {
        group.sort_by(|left, right| left.quota.fetched_at.total_cmp(&right.quota.fetched_at));
        let mut upper_bounds = vec![None; group.len()];
        let mut next_official = None;
        let mut last_official_start = None;
        // 使用最近的后续主动读取作上界，之后的清零不会否定此前确认过的历史。
        for (index, reading) in group.iter().enumerate().rev() {
            if !reading.is_from_session {
                next_official = Some((reading.quota.starts_at, reading.quota.used_percent));
                last_official_start.get_or_insert(reading.quota.starts_at);
            }
            upper_bounds[index] = next_official;
        }
        let mut high_water: Option<f64> = None;
        for (reading, upper_bound) in group.into_iter().zip(upper_bounds) {
            let mut quota = reading.quota;
            if reading.is_from_session {
                let confirmed = quota.used_percent >= high_water.unwrap_or(0.0)
                    && upper_bound.is_none_or(|(_, limit)| quota.used_percent <= limit);
                if !confirmed {
                    continue;
                }
                // 使用后续主动读取的原始起点，首次消耗可以与起点修正一起识别。
                quota.starts_at = upper_bound
                    .map(|(start, _)| start)
                    .or(last_official_start)
                    .unwrap_or_else(|| f64::from_bits(start));
            }
            // 保留官方读数的真实下降，统计层会将其识别为异常。
            high_water = Some(
                high_water
                    .unwrap_or(quota.used_percent)
                    .max(quota.used_percent),
            );
            result.push(quota);
        }
    }
    result.sort_by(|left, right| left.fetched_at.total_cmp(&right.fetched_at));
    result
}
