import Foundation

public struct UsageReconciler: Sendable {
    public init() {}

    public func snapshot(
        now: Date,
        calendar: Calendar,
        quota: QuotaSnapshot?,
        events: [StoredUsageEvent],
        officialDays: [OfficialUsageDay],
        cycles: [QuotaCycle],
        lastUpdatedAt: Date,
        quotaHistory: [QuotaSnapshot] = []
    ) -> UsageSnapshot {
        let todayStart = calendar.startOfDay(for: now)
        let todayDay = localDay(for: todayStart, calendar: calendar)
        let localUsageByDay = aggregateEventsByStoredDay(events)
        let officialByDay = latestOfficialDays(officialDays)
        let officialRange = officialByDay.keys.min().flatMap { firstDay in
            officialByDay.keys.max().map { firstDay...$0 }
        }

        let recentDays = (-6...0).compactMap { offset -> UsageDay? in
            guard let dayDate = calendar.date(
                byAdding: .day,
                value: offset,
                to: todayStart
            ) else {
                return nil
            }
            let day = localDay(for: dayDate, calendar: calendar)
            let localUsage = localUsageByDay[day] ?? .zero
            let official = officialByDay[day]
            let isOfficiallyCovered = official != nil
                || officialRange?.contains(day) == true
            if day < todayDay, isOfficiallyCovered {
                let officialTokens = official?.tokens ?? 0
                return UsageDay(
                    day: day,
                    localUsage: localUsage,
                    officialTokens: officialTokens,
                    displayedTokens: officialTokens,
                    status: .calibrated
                )
            }
            return UsageDay(
                day: day,
                localUsage: localUsage,
                officialTokens: official?.tokens,
                displayedTokens: totalTokensClamped(localUsage),
                status: .localLive
            )
        }
        let today = recentDays.last ?? UsageDay(
            day: todayDay,
            localUsage: localUsageByDay[todayDay] ?? .zero,
            officialTokens: officialByDay[todayDay]?.tokens,
            displayedTokens: totalTokensClamped(
                localUsageByDay[todayDay] ?? .zero
            ),
            status: .localLive
        )

        let observations = quotaObservations(quota: quota, history: quotaHistory, now: now)
        let knownCycleStarts = Set(cycles.filter { !$0.boundaryIsEstimated }.map(\.startsAt))
        let reconciledCycles = cycles
            .filter(hasValidInterval)
            .map {
                reconcile(
                    cycle: $0,
                    now: now,
                    todayStart: todayStart,
                    calendar: calendar,
                    events: events,
                    officialByDay: officialByDay,
                    observations: observations,
                    knownCycleStarts: knownCycleStarts
                )
            }
        let currentCycle = reconciledCycles
            .filter { $0.startsAt <= now && now < $0.endsAt }
            .max { $0.startsAt < $1.startsAt }
        let cycleHistory = Array(
            reconciledCycles
                .filter { $0.endsAt <= now }
                .sorted { $0.startsAt > $1.startsAt }
                .prefix(8)
        )

        let daysWithQuotaConsumption = recentDays.map { day in
            let consumption = quotaConsumption(
                for: day, now: now, calendar: calendar, observations: observations
            )
            return UsageDay(
                day: day.day,
                localUsage: day.localUsage,
                officialTokens: day.officialTokens,
                displayedTokens: day.displayedTokens,
                status: day.status,
                quotaConsumedPercent: consumption.percent,
                quotaSegments: consumption.segments
            )
        }

        return UsageSnapshot(
            quota: quota,
            today: daysWithQuotaConsumption.last ?? today,
            currentCycle: currentCycle,
            recentDays: daysWithQuotaConsumption,
            cycleHistory: cycleHistory,
            lastUpdatedAt: lastUpdatedAt,
            status: snapshotStatus(
                now: now,
                quota: quota,
                today: today,
                currentCycle: currentCycle
            )
        )
    }

    private func quotaObservations(
        quota: QuotaSnapshot?, history: [QuotaSnapshot], now: Date
    ) -> [QuotaSnapshot] {
        guard let quota else { return [] }
        // 与历史周期共用重置识别，起点修正不能变成新的展示分段。
        let resetStarts = CycleTracker().observedResetStarts(quota: quota, history: history)
        return (history + [quota]).filter {
            $0.limitID == quota.limitID && $0.fetchedAt <= now
        }.sorted { $0.fetchedAt < $1.fetchedAt }.map {
            QuotaSnapshot(
                limitID: $0.limitID, usedPercent: $0.usedPercent,
                windowDurationMinutes: $0.windowDurationMinutes,
                startsAt: resetStarts[$0.startsAt] ?? $0.startsAt,
                resetsAt: $0.resetsAt, fetchedAt: $0.fetchedAt
            )
        }
    }

    private func quotaConsumption(
        for day: UsageDay,
        now: Date,
        calendar: Calendar,
        observations: [QuotaSnapshot]
    ) -> (percent: Double?, segments: [QuotaConsumptionSegment]?) {
        guard let start = calendar.date(from: DateComponents(
            year: day.day.year, month: day.day.month, day: day.day.day
        )), let nextDay = calendar.date(byAdding: .day, value: 1, to: start)
        else { return (nil, nil) }
        let end = min(nextDay, now)
        let resets = Set(observations.filter(isUsableQuota).map(\.startsAt))
        let boundaries = [start] + resets.filter { start < $0 && $0 < end }.sorted() + [end]
        let segments = zip(boundaries, boundaries.dropFirst()).map { from, to in
            QuotaConsumptionSegment(
                startsAt: from, endsAt: to,
                consumedPercent: consumedPercent(
                    from: from, to: to,
                    startsWithReset: resets.contains(from),
                    endsWithReset: resets.contains(to),
                    observations: observations
                ),
                startsWithReset: resets.contains(from)
            )
        }
        let values = segments.compactMap(\.consumedPercent)
        let total = values.reduce(0, +)
        let hasReset = segments.contains(where: \.startsWithReset)
        return (
            values.count == segments.count && total.isFinite ? total : nil,
            hasReset ? segments : nil
        )
    }

    private func consumedPercent(
        from start: Date,
        to end: Date,
        startsWithReset: Bool,
        endsWithReset: Bool,
        observations: [QuotaSnapshot]
    ) -> Double? {
        let first: QuotaSnapshot?
        if startsWithReset, let reading = observations.first(where: { $0.startsAt == start }) {
            first = QuotaSnapshot(
                limitID: reading.limitID, usedPercent: 0,
                windowDurationMinutes: reading.windowDurationMinutes,
                startsAt: start, resetsAt: reading.resetsAt, fetchedAt: start
            )
        } else {
            first = quotaAtBoundary(start, observations: observations)
        }
        guard let first, isUsableQuota(first) else { return nil }

        let last: QuotaSnapshot?
        if endsWithReset {
            // 重置前只采用同周期的最后一条近邻记录，不把剩余额度补成已消耗。
            last = observations.last {
                $0.fetchedAt < end && isSameQuotaCycle(first, $0)
            }
            guard let last, end.timeIntervalSince(last.fetchedAt) <= 600 else { return nil }
        } else {
            last = quotaAtBoundary(end, observations: observations)
        }
        guard let last, isUsableQuota(last), isSameQuotaCycle(first, last) else { return nil }
        let readings = [first] + observations.filter {
            start < $0.fetchedAt && $0.fetchedAt < end && isSameQuotaCycle(first, $0)
        } + [last]
        var consumed = 0.0
        for (previous, current) in zip(readings, readings.dropFirst()) {
            guard isUsableQuota(previous), isUsableQuota(current),
                  current.usedPercent >= previous.usedPercent else { return nil }
            consumed += current.usedPercent - previous.usedPercent
        }
        return consumed.isFinite ? consumed : nil
    }

    private func quotaAtBoundary(
        _ boundary: Date,
        observations: [QuotaSnapshot]
    ) -> QuotaSnapshot? {
        let before = observations.last { $0.fetchedAt <= boundary }
        let after = observations.first { $0.fetchedAt > boundary }
        if let before, isUsableQuota(before),
           before.startsAt <= boundary, boundary <= before.resetsAt {
            if let after, !isSameQuotaCycle(before, after), after.startsAt < boundary {
                return nil
            }
            let recent = boundary.timeIntervalSince(before.fetchedAt) <= 600
            // 跨夜两侧同周期且读数相同，才能用较远的记录确定零点读数。
            let unchanged = after.map {
                isUsableQuota($0) && isSameQuotaCycle(before, $0)
                    && before.usedPercent == $0.usedPercent
            } ?? false
            if recent || unchanged {
                return before
            }
        }
        if let after, isUsableQuota(after), after.startsAt == boundary {
            return QuotaSnapshot(
                limitID: after.limitID, usedPercent: 0,
                windowDurationMinutes: after.windowDurationMinutes,
                startsAt: after.startsAt, resetsAt: after.resetsAt, fetchedAt: boundary
            )
        }
        return nil
    }

    private func isSameQuotaCycle(_ lhs: QuotaSnapshot, _ rhs: QuotaSnapshot) -> Bool {
        lhs.limitID == rhs.limitID
            && lhs.windowDurationMinutes == rhs.windowDurationMinutes
            && lhs.startsAt == rhs.startsAt
    }

    private func isUsableQuota(_ quota: QuotaSnapshot) -> Bool {
        quota.usedPercent.isFinite && quota.usedPercent >= 0
            && quota.windowDurationMinutes > 0
            && quota.startsAt < quota.resetsAt
            && quota.startsAt.timeIntervalSince(quota.fetchedAt) <= 60
            && quota.fetchedAt <= quota.resetsAt
    }

    private func cycleQuotaUsedPercent(
        _ cycle: QuotaCycle, now: Date, observations: [QuotaSnapshot], knownCycleStarts: Set<Date>
    ) -> Double? {
        guard !cycle.boundaryIsEstimated, cycle.startsAt <= now else { return nil }
        let starts = Set(observations.map(\.startsAt))
        let matchingStart: Date
        if starts.contains(cycle.startsAt) {
            matchingStart = cycle.startsAt
        } else {
            // 兼容已保留的秒级边界；存在多个候选时不猜测归属。
            let candidates = starts.filter {
                abs($0.timeIntervalSince(cycle.startsAt)) <= 60 && $0 < cycle.endsAt
                    && !knownCycleStarts.contains($0)
            }
            guard candidates.count == 1, let candidate = candidates.first else { return nil }
            matchingStart = candidate
        }
        let readings = observations.filter {
            $0.startsAt == matchingStart && $0.fetchedAt < cycle.endsAt
        }
        guard let last = readings.last, isUsableQuota(last) else { return nil }
        if matchingStart != cycle.startsAt, last.fetchedAt < cycle.startsAt { return nil }
        if now < cycle.endsAt {
            guard observations.last?.startsAt == matchingStart else { return nil }
        } else {
            guard cycle.endsAt.timeIntervalSince(last.fetchedAt) <= 600 else { return nil }
            // 先清零、后更新重置时间时，旧周期的末条 0 不能当成完整周期消耗。
            for (previous, current) in zip(readings, readings.dropFirst()) {
                guard isUsableQuota(previous), isUsableQuota(current),
                      current.usedPercent >= previous.usedPercent else { return nil }
            }
        }
        return last.usedPercent
    }

    private func aggregateEventsByStoredDay(
        _ events: [StoredUsageEvent]
    ) -> [LocalDay: TokenBreakdown] {
        events.reduce(into: [:]) { result, event in
            result[event.localDay] = addingClamped(
                result[event.localDay] ?? .zero,
                event.usage
            )
        }
    }

    private func latestOfficialDays(
        _ officialDays: [OfficialUsageDay]
    ) -> [LocalDay: OfficialUsageDay] {
        Dictionary(grouping: officialDays, by: \.day).reduce(into: [:]) {
            result,
            entry in
            let (day, candidates) = entry
            guard let latestFetchedAt = candidates.map(\.fetchedAt).max()
            else {
                return
            }
            let latestTokens = Set(
                candidates
                    .filter { $0.fetchedAt == latestFetchedAt }
                    .map(\.tokens)
            )
            guard latestTokens.count == 1,
                  let tokens = latestTokens.first else {
                return
            }
            result[day] = OfficialUsageDay(
                day: day,
                tokens: tokens,
                fetchedAt: latestFetchedAt
            )
        }
    }

    private func reconcile(
        cycle: QuotaCycle,
        now: Date,
        todayStart: Date,
        calendar: Calendar,
        events: [StoredUsageEvent],
        officialByDay: [LocalDay: OfficialUsageDay],
        observations: [QuotaSnapshot],
        knownCycleStarts: Set<Date>
    ) -> QuotaCycle {
        let quotaPercent = cycleQuotaUsedPercent(
            cycle, now: now, observations: observations, knownCycleStarts: knownCycleStarts
        )
        let cycleEvents = events.filter {
            cycle.startsAt <= $0.occurredAt && $0.occurredAt < cycle.endsAt
        }
        let localByDay = cycleEvents.reduce(
            into: [LocalDay: TokenBreakdown]()
        ) {
            result,
            event in
            result[event.localDay] = addingClamped(
                result[event.localDay] ?? .zero,
                event.usage
            )
        }
        let aggregate = cycleEvents.reduce(into: TokenBreakdown.zero) {
            result,
            event in
            result = addingClamped(result, event.usage)
        }
        guard aggregate == cycle.usage else {
            return QuotaCycle(
                startsAt: cycle.startsAt,
                endsAt: cycle.endsAt,
                usage: cycle.usage,
                displayedTokens: totalTokensClamped(cycle.usage),
                status: .partiallyCalibrated,
                boundaryIsEstimated: cycle.boundaryIsEstimated,
                quotaUsedPercent: quotaPercent
            )
        }

        let completeDays = completeNaturalDays(
            in: cycle,
            before: min(todayStart, calendar.startOfDay(for: now)),
            calendar: calendar
        )
        let completeDaySet = Set(completeDays)
        let accumulatedDays = Set(localByDay.keys).union(
            completeDays.filter { officialByDay[$0] != nil }
        )
        var displayedTokens: Int64 = 0
        var replacedDayCount = 0
        for day in accumulatedDays.sorted() {
            if completeDaySet.contains(day),
               let official = officialByDay[day] {
                displayedTokens = addingClamped(
                    displayedTokens,
                    official.tokens
                )
                replacedDayCount += 1
            } else {
                displayedTokens = addingClamped(
                    displayedTokens,
                    totalTokensClamped(localByDay[day] ?? .zero)
                )
            }
        }

        let hasPartialBoundary = cycle.startsAt != calendar.startOfDay(
            for: cycle.startsAt
        ) || cycle.endsAt != calendar.startOfDay(for: cycle.endsAt)
        let status: UsageCalibrationStatus
        if hasPartialBoundary {
            status = .partiallyCalibrated
        } else if replacedDayCount == 0 {
            status = .localLive
        } else if replacedDayCount < completeDays.count {
            status = .partiallyCalibrated
        } else {
            status = .calibrated
        }

        return QuotaCycle(
            startsAt: cycle.startsAt,
            endsAt: cycle.endsAt,
            usage: cycle.usage,
            displayedTokens: displayedTokens,
            status: status,
            boundaryIsEstimated: cycle.boundaryIsEstimated,
            quotaUsedPercent: quotaPercent
        )
    }

    private func completeNaturalDays(
        in cycle: QuotaCycle,
        before todayStart: Date,
        calendar: Calendar
    ) -> [LocalDay] {
        var result: [LocalDay] = []
        var dayStart = calendar.startOfDay(for: cycle.startsAt)
        while dayStart < cycle.endsAt, dayStart < todayStart {
            guard let nextDayStart = calendar.date(
                byAdding: .day,
                value: 1,
                to: dayStart
            ), nextDayStart > dayStart else {
                break
            }
            if cycle.startsAt <= dayStart,
               nextDayStart <= cycle.endsAt,
               nextDayStart <= todayStart {
                result.append(localDay(for: dayStart, calendar: calendar))
            }
            dayStart = nextDayStart
        }
        return result
    }

    private func localDay(
        for date: Date,
        calendar: Calendar
    ) -> LocalDay {
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return LocalDay(
            year: components.year ?? 1,
            month: components.month ?? 1,
            day: components.day ?? 1
        )
    }

    private func hasValidInterval(_ cycle: QuotaCycle) -> Bool {
        cycle.startsAt.timeIntervalSinceReferenceDate.isFinite
            && cycle.endsAt.timeIntervalSinceReferenceDate.isFinite
            && cycle.startsAt < cycle.endsAt
    }

    private func snapshotStatus(
        now: Date,
        quota: QuotaSnapshot?,
        today: UsageDay,
        currentCycle: QuotaCycle?
    ) -> UsageCalibrationStatus {
        guard let quota else { return .unavailable }
        let age = now.timeIntervalSince(quota.fetchedAt)
        guard age.isFinite, abs(age) <= 600 else { return .stale }

        let statuses = [today.status, currentCycle?.status].compactMap { $0 }
        return statuses.min { statusStrength($0) < statusStrength($1) }
            ?? .localLive
    }

    private func statusStrength(_ status: UsageCalibrationStatus) -> Int {
        switch status {
        case .partiallyCalibrated:
            0
        case .localLive:
            1
        case .calibrated:
            2
        case .stale:
            -1
        case .unavailable:
            -2
        }
    }
}

private func addingClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    guard overflow else { return sum }
    return rhs >= 0 ? .max : .min
}
