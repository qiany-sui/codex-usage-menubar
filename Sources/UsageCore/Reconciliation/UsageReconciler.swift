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
            if day < todayDay, let official {
                return UsageDay(
                    day: day,
                    localUsage: localUsage,
                    officialTokens: official.tokens,
                    displayedTokens: official.tokens,
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
        officialDays.reduce(into: [:]) { result, day in
            if let existing = result[day.day],
               existing.fetchedAt >= day.fetchedAt {
                return
            }
            result[day.day] = day
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
        let localByDay = events.reduce(into: [LocalDay: TokenBreakdown]()) {
            result,
            event in
            guard cycle.startsAt <= event.occurredAt,
                  event.occurredAt < cycle.endsAt else {
                return
            }
            result[event.localDay] = addingClamped(
                result[event.localDay] ?? .zero,
                event.usage
            )
        }
        let completeDays = completeNaturalDays(
            in: cycle,
            before: min(todayStart, calendar.startOfDay(for: now)),
            calendar: calendar
        )
        var displayedTokens = totalTokensClamped(cycle.usage)
        var replacedDayCount = 0
        for day in completeDays {
            guard let official = officialByDay[day] else { continue }
            displayedTokens = subtractingClamped(
                displayedTokens,
                totalTokensClamped(localByDay[day] ?? .zero)
            )
            displayedTokens = addingClamped(displayedTokens, official.tokens)
            replacedDayCount += 1
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
        guard age.isFinite, age <= 600 else { return .stale }

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

private func subtractingClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (difference, overflow) = lhs.subtractingReportingOverflow(rhs)
    guard overflow else { return difference }
    return rhs >= 0 ? .min : .max
}

private func addingClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    guard overflow else { return sum }
    return rhs >= 0 ? .max : .min
}
