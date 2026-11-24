use super::cycles::{RESET_TOLERANCE_SECONDS, corrected_start, observed_reset_starts};
use super::{NEARBY_READING_SECONDS, timestamp_key};
use crate::model::{QuotaConsumptionSegment, QuotaCycle, QuotaSnapshot, Timestamp, UsageDay};
use std::collections::HashSet;

pub(super) struct QuotaObservations {
    readings: Vec<QuotaSnapshot>,
    resets: Vec<Timestamp>,
    starts: Vec<Timestamp>,
    known_cycle_starts: HashSet<u64>,
}

impl QuotaObservations {
    pub(super) fn new(
        quota: Option<&QuotaSnapshot>,
        history: &[QuotaSnapshot],
        now: Timestamp,
        cycles: &[QuotaCycle],
    ) -> Self {
        let mut readings = Vec::new();
        if let Some(quota) = quota {
            // 周期统计与每日额度使用相同的重置起点，修正记录不会产生新的分段。
            let starts = observed_reset_starts(quota, history);
            readings.extend(
                history
                    .iter()
                    .chain(std::iter::once(quota))
                    .filter(|reading| {
                        reading.limit_id == quota.limit_id && reading.fetched_at <= now
                    })
                    .map(|reading| QuotaSnapshot {
                        starts_at: corrected_start(reading.starts_at, &starts),
                        ..reading.clone()
                    }),
            );
            readings.sort_by(|left, right| left.fetched_at.total_cmp(&right.fetched_at));
        }
        let mut resets: Vec<_> = readings
            .iter()
            .filter(|reading| is_usable(reading))
            .map(|reading| reading.starts_at)
            .collect();
        resets.sort_by(f64::total_cmp);
        resets.dedup();
        let mut starts: Vec<_> = readings.iter().map(|reading| reading.starts_at).collect();
        starts.sort_by(f64::total_cmp);
        starts.dedup();
        let known_cycle_starts = cycles
            .iter()
            .filter(|cycle| !cycle.boundary_is_estimated)
            .map(|cycle| timestamp_key(cycle.starts_at))
            .collect();
        Self {
            readings,
            resets,
            starts,
            known_cycle_starts,
        }
    }

    pub(super) fn apply_to_day(&self, day: &mut UsageDay, start: Timestamp, end: Timestamp) {
        let boundaries: Vec<_> = std::iter::once(start)
            .chain(
                self.resets
                    .iter()
                    .copied()
                    .filter(|reset| start < *reset && *reset < end),
            )
            .chain(std::iter::once(end))
            .collect();
        let segments: Vec<_> = boundaries
            .windows(2)
            .map(|pair| {
                let starts_with_reset = self.resets.contains(&pair[0]);
                self.segment(
                    pair[0],
                    pair[1],
                    starts_with_reset,
                    self.resets.contains(&pair[1]),
                    None,
                )
            })
            .collect();
        day.quota_consumed_percent = segments
            .iter()
            .map(|segment| segment.consumed_percent)
            .sum::<Option<f64>>()
            .filter(|sum| sum.is_finite());
        if segments.iter().any(|segment| segment.starts_with_reset) {
            day.quota_segments = Some(segments);
        } else {
            day.recorded_quota_consumed_percent = segments
                .first()
                .and_then(|segment| segment.recorded_consumed_percent);
        }
    }

    pub(super) fn segment(
        &self,
        start: Timestamp,
        end: Timestamp,
        starts_with_reset: bool,
        ends_with_reset: bool,
        cycle_start: Option<Timestamp>,
    ) -> QuotaConsumptionSegment {
        let baseline = starts_with_reset
            .then(|| cycle_start.unwrap_or(start))
            .and_then(|reset| {
                self.readings
                    .iter()
                    .find(|reading| reading.starts_at == reset)
                    .map(|reading| zero_reading(reading, start))
            })
            .or_else(|| self.at_boundary(start));
        let consumed_percent = baseline.as_ref().and_then(|first| {
            self.consumed_percent(start, end, ends_with_reset, cycle_start, first)
        });
        let recorded_consumed_percent = if consumed_percent.is_none() {
            self.recorded_percent(
                start,
                end,
                starts_with_reset,
                cycle_start,
                baseline.as_ref(),
            )
        } else {
            None
        };
        QuotaConsumptionSegment {
            starts_at: start,
            ends_at: end,
            starts_with_reset,
            consumed_percent,
            recorded_consumed_percent,
        }
    }

    pub(super) fn matching_start(&self, cycle: &QuotaCycle, now: Timestamp) -> Option<Timestamp> {
        if cycle.boundary_is_estimated || cycle.starts_at > now {
            return None;
        }
        if self.starts.contains(&cycle.starts_at) {
            return Some(cycle.starts_at);
        }
        // 兼容已保留的秒级起点，只有一个可确认归属的候选才采用。
        let mut candidates = self.starts.iter().copied().filter(|start| {
            (*start - cycle.starts_at).abs() <= RESET_TOLERANCE_SECONDS
                && *start < cycle.ends_at
                && !self.known_cycle_starts.contains(&timestamp_key(*start))
        });
        let first = candidates.next()?;
        candidates.next().is_none().then_some(first)
    }

    pub(super) fn cycle_percent(
        &self,
        cycle: &QuotaCycle,
        now: Timestamp,
        matching_start: Timestamp,
    ) -> (Option<f64>, Option<QuotaSnapshot>) {
        let readings: Vec<_> = self
            .readings
            .iter()
            .filter(|reading| {
                reading.starts_at == matching_start && reading.fetched_at < cycle.ends_at
            })
            .collect();
        let Some(&last) = readings.last().filter(|reading| is_usable(reading)) else {
            return (None, None);
        };
        if matching_start != cycle.starts_at && last.fetched_at < cycle.starts_at {
            return (None, None);
        }
        if now < cycle.ends_at {
            if !self
                .readings
                .last()
                .is_some_and(|reading| reading.starts_at == matching_start)
            {
                return (None, None);
            }
        } else {
            // 服务端可能先清零再改起点，旧周期的最后一次零读数不能当作完整消耗。
            if !readings
                .windows(2)
                .all(|pair| is_increasing(pair[0], pair[1]))
            {
                return (None, None);
            }
            if cycle.ends_at - last.fetched_at > NEARBY_READING_SECONDS {
                return (None, Some(last.clone()));
            }
        }
        (Some(last.used_percent), None)
    }

    fn consumed_percent(
        &self,
        start: Timestamp,
        end: Timestamp,
        ends_with_reset: bool,
        cycle_start: Option<Timestamp>,
        first: &QuotaSnapshot,
    ) -> Option<f64> {
        if !is_usable(first) || cycle_start.is_some_and(|required| first.starts_at != required) {
            return None;
        }
        let last = if ends_with_reset {
            // 采用重置前同周期的近邻记录，保留当时实际剩余的额度。
            self.readings
                .iter()
                .rev()
                .find(|reading| reading.fetched_at < end && is_same_cycle(first, reading))
                .filter(|reading| end - reading.fetched_at <= NEARBY_READING_SECONDS)?
                .clone()
        } else {
            self.at_boundary(end)?
        };
        if !is_usable(&last) || !is_same_cycle(first, &last) {
            return None;
        }
        let between = self.readings.iter().filter(|reading| {
            start < reading.fetched_at && reading.fetched_at < end && is_same_cycle(first, reading)
        });
        let (_, consumed) = between.chain(std::iter::once(&last)).try_fold(
            (first, 0.0),
            |(previous, consumed), reading| {
                is_increasing(previous, reading).then_some((
                    reading,
                    consumed + (reading.used_percent - previous.used_percent),
                ))
            },
        )?;
        consumed.is_finite().then_some(consumed)
    }

    fn recorded_percent(
        &self,
        start: Timestamp,
        end: Timestamp,
        starts_with_reset: bool,
        cycle_start: Option<Timestamp>,
        baseline: Option<&QuotaSnapshot>,
    ) -> Option<f64> {
        // 部分消耗只能使用本时间段及本周期内确实观察到的增量。
        let mut in_range = self.readings.iter().filter(|reading| {
            start <= reading.fetched_at
                && reading.fetched_at <= end
                && (reading.starts_at <= start
                    || (starts_with_reset && cycle_start == Some(reading.starts_at)))
                && cycle_start.is_none_or(|required| reading.starts_at == required)
        });
        let first = baseline.or_else(|| in_range.next())?;
        if !is_usable(first) || cycle_start.is_some_and(|required| first.starts_at != required) {
            return None;
        }
        let last = in_range.try_fold(first, |previous, reading| {
            (is_same_cycle(first, reading) && is_increasing(previous, reading)).then_some(reading)
        })?;
        (last.fetched_at > start.max(first.fetched_at))
            .then_some(last.used_percent - first.used_percent)
    }

    fn at_boundary(&self, boundary: Timestamp) -> Option<QuotaSnapshot> {
        let index = self
            .readings
            .partition_point(|reading| reading.fetched_at <= boundary);
        let before = index
            .checked_sub(1)
            .and_then(|index| self.readings.get(index));
        let after = self.readings.get(index);
        if let Some(before) = before.filter(|reading| {
            is_usable(reading) && reading.starts_at <= boundary && boundary <= reading.resets_at
        }) {
            if after
                .is_some_and(|after| !is_same_cycle(before, after) && after.starts_at < boundary)
            {
                return None;
            }
            let recent = boundary - before.fetched_at <= NEARBY_READING_SECONDS;
            // 跨越较长空档时，两侧属于同一周期且数值相同，才可确定边界读数。
            let unchanged = after.is_some_and(|after| {
                is_usable(after)
                    && is_same_cycle(before, after)
                    && before.used_percent == after.used_percent
            });
            if recent || unchanged {
                return Some(before.clone());
            }
        }
        after
            .filter(|after| is_usable(after) && after.starts_at == boundary)
            .map(|after| zero_reading(after, boundary))
    }
}

fn is_same_cycle(left: &QuotaSnapshot, right: &QuotaSnapshot) -> bool {
    left.limit_id == right.limit_id
        && left.window_duration_minutes == right.window_duration_minutes
        && left.starts_at == right.starts_at
}

fn is_usable(reading: &QuotaSnapshot) -> bool {
    reading.used_percent.is_finite()
        && reading.used_percent >= 0.0
        && reading.window_duration_minutes > 0
        && reading.starts_at < reading.resets_at
        && reading.starts_at - reading.fetched_at <= RESET_TOLERANCE_SECONDS
        && reading.fetched_at <= reading.resets_at
}

fn is_increasing(previous: &QuotaSnapshot, current: &QuotaSnapshot) -> bool {
    is_usable(previous) && is_usable(current) && current.used_percent >= previous.used_percent
}

fn zero_reading(reading: &QuotaSnapshot, boundary: Timestamp) -> QuotaSnapshot {
    QuotaSnapshot {
        used_percent: 0.0,
        fetched_at: boundary,
        ..reading.clone()
    }
}
