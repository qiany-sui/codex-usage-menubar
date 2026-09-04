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
        lastUpdatedAt: Date
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

        let reconciledCycles = cycles
            .filter(hasValidInterval)
            .map {
                reconcile(
                    cycle: $0,
                    now: now,
                    todayStart: todayStart,
                    calendar: calendar,
                    events: events,
                    officialByDay: officialByDay
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

        return UsageSnapshot(
            quota: quota,
            today: today,
            currentCycle: currentCycle,
            recentDays: recentDays,
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
        officialByDay: [LocalDay: OfficialUsageDay]
    ) -> QuotaCycle {
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
                boundaryIsEstimated: cycle.boundaryIsEstimated
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
            boundaryIsEstimated: cycle.boundaryIsEstimated
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
