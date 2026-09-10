import Foundation

public struct CycleTracker: Sendable {
    // 重置时间可能有秒级修正，避免将同一周期拆成短历史记录。
    private static let boundaryTolerance: TimeInterval = 60

    public init() {}

    public func update(
        existing: [QuotaCycle],
        quota: QuotaSnapshot,
        events: [StoredUsageEvent],
        quotaHistory: [QuotaSnapshot] = []
    ) -> [QuotaCycle] {
        let resetStarts = observedResetStarts(quota: quota, history: quotaHistory)
        let quotaStart = resetStarts[quota.startsAt] ?? quota.startsAt
        var cycles = normalized(existing, resetStarts: resetStarts)

        if let current = cycles.last {
            let startDifference = quotaStart.timeIntervalSince(
                current.startsAt
            )
            if sameReset(current.startsAt, quotaStart, resetStarts: resetStarts) {
                cycles[cycles.count - 1] = QuotaCycle(
                    startsAt: current.startsAt,
                    endsAt: quota.resetsAt,
                    usage: current.usage,
                    displayedTokens: current.displayedTokens,
                    status: current.status,
                    boundaryIsEstimated: false
                )
            } else if startDifference > 0 {
                cycles[cycles.count - 1] = QuotaCycle(
                    startsAt: current.startsAt,
                    endsAt: min(current.endsAt, quotaStart),
                    usage: current.usage,
                    displayedTokens: current.displayedTokens,
                    status: current.status,
                    boundaryIsEstimated: current.boundaryIsEstimated
                )
                cycles.append(
                    QuotaCycle(
                        startsAt: quotaStart,
                        endsAt: quota.resetsAt,
                        usage: .zero,
                        displayedTokens: 0,
                        status: .localLive,
                        boundaryIsEstimated: false
                    )
                )
            }
        } else {
            cycles.append(
                QuotaCycle(
                    startsAt: quotaStart,
                    endsAt: quota.resetsAt,
                    usage: .zero,
                    displayedTokens: 0,
                    status: .localLive,
                    boundaryIsEstimated: false
                )
            )
        }

        if (9_000...11_000).contains(quota.windowDurationMinutes) {
            let duration = TimeInterval(quota.windowDurationMinutes) * 60
            while cycles.count < 9, let earliest = cycles.first {
                let startsAt = earliest.startsAt.addingTimeInterval(-duration)
                guard startsAt.timeIntervalSince1970.isFinite else { break }
                cycles.insert(
                    QuotaCycle(
                        startsAt: startsAt,
                        endsAt: earliest.startsAt,
                        usage: .zero,
                        displayedTokens: 0,
                        status: .localLive,
                        boundaryIsEstimated: true
                    ),
                    at: 0
                )
            }
        }

        cycles = cycles.map { cycle in
            let usage = events.reduce(into: TokenBreakdown.zero) {
                aggregate,
                event in
                guard event.occurredAt >= cycle.startsAt,
                      event.occurredAt < cycle.endsAt else {
                    return
                }
                aggregate = addingClamped(aggregate, event.usage)
            }
            return QuotaCycle(
                startsAt: cycle.startsAt,
                endsAt: cycle.endsAt,
                usage: usage,
                displayedTokens: totalTokensClamped(usage),
                status: .localLive,
                boundaryIsEstimated: cycle.boundaryIsEstimated
            )
        }

        return Array(cycles.sorted { $0.startsAt < $1.startsAt }.suffix(9))
    }

    func observedResetStarts(
        quota: QuotaSnapshot,
        history: [QuotaSnapshot]
    ) -> [Date: Date] {
        let observations = (history + [quota]).filter {
            $0.limitID == quota.limitID && $0.fetchedAt <= quota.fetchedAt
                && $0.usedPercent.isFinite && $0.usedPercent >= 0
        }.sorted { $0.fetchedAt < $1.fetchedAt }
        var starts: [Date: Date] = [:]
        var previous: QuotaSnapshot?
        var resetStart = quota.startsAt
        var hasConsumedQuota = false
        for observation in observations {
            var continuesReset = false
            if let previous,
               previous.windowDurationMinutes == observation.windowDurationMinutes {
                let difference = observation.startsAt.timeIntervalSince(previous.startsAt)
                // 服务端可能先清零、再更新起点，因此检查整个周期是否曾消耗额度。
                let consumedThenReset = difference > 0
                    && hasConsumedQuota && observation.usedPercent == 0
                // 重置后已用额度仍为 0 时，起点还会随首次使用修正；这些读数属于同一次重置。
                // 不跨越离线空档推断两次重置属于同一次。
                let pendingStartCorrection = !hasConsumedQuota && difference > 0
                    && observation.startsAt < previous.resetsAt
                    && observation.fetchedAt.timeIntervalSince(previous.fetchedAt) <= 600
                continuesReset = !consumedThenReset
                    && (abs(difference) <= Self.boundaryTolerance || pendingStartCorrection)
            }
            if !continuesReset {
                resetStart = observation.startsAt
                hasConsumedQuota = false
            }
            starts[observation.startsAt] = resetStart
            hasConsumedQuota = hasConsumedQuota || observation.usedPercent > 0
            previous = observation
        }
        return starts
    }

    private func sameReset(
        _ lhs: Date,
        _ rhs: Date,
        resetStarts: [Date: Date]
    ) -> Bool {
        if let left = resetStarts[lhs], let right = resetStarts[rhs] {
            return left == right
        }
        return abs(lhs.timeIntervalSince(rhs)) <= Self.boundaryTolerance
    }

    private func normalized(
        _ existing: [QuotaCycle],
        resetStarts: [Date: Date]
    ) -> [QuotaCycle] {
        let sorted = existing.map { cycle in
            QuotaCycle(
                startsAt: resetStarts[cycle.startsAt] ?? cycle.startsAt,
                endsAt: cycle.endsAt,
                usage: cycle.usage,
                displayedTokens: cycle.displayedTokens,
                status: cycle.status,
                boundaryIsEstimated: cycle.boundaryIsEstimated
            )
        }.sorted {
            if $0.startsAt != $1.startsAt {
                return $0.startsAt < $1.startsAt
            }
            if $0.endsAt != $1.endsAt {
                return $0.endsAt < $1.endsAt
            }
            return !$0.boundaryIsEstimated && $1.boundaryIsEstimated
        }
        var merged: [QuotaCycle] = []
        for candidate in sorted {
            if let current = merged.last,
               sameReset(current.startsAt, candidate.startsAt, resetStarts: resetStarts) {
                merged[merged.count - 1] = QuotaCycle(
                    startsAt: current.startsAt,
                    endsAt: max(current.endsAt, candidate.endsAt),
                    usage: .zero,
                    displayedTokens: 0,
                    status: .localLive,
                    boundaryIsEstimated: current.boundaryIsEstimated
                        && candidate.boundaryIsEstimated
                )
            } else {
                merged.append(
                    QuotaCycle(
                        startsAt: candidate.startsAt,
                        endsAt: candidate.endsAt,
                        usage: .zero,
                        displayedTokens: 0,
                        status: .localLive,
                        boundaryIsEstimated: candidate.boundaryIsEstimated
                    )
                )
            }
        }

        guard merged.count > 1 else { return merged }
        for index in merged.indices.dropLast() {
            let nextStart = merged[merged.index(after: index)].startsAt
            guard merged[index].endsAt > nextStart else { continue }
            let cycle = merged[index]
            merged[index] = QuotaCycle(
                startsAt: cycle.startsAt,
                endsAt: nextStart,
                usage: .zero,
                displayedTokens: 0,
                status: .localLive,
                boundaryIsEstimated: cycle.boundaryIsEstimated
            )
        }
        return merged
    }
}

func addingClamped(
    _ lhs: TokenBreakdown,
    _ rhs: TokenBreakdown
) -> TokenBreakdown {
    TokenBreakdown(
        inputTokens: addingClamped(lhs.inputTokens, rhs.inputTokens),
        cachedInputTokens: addingClamped(
            lhs.cachedInputTokens,
            rhs.cachedInputTokens
        ),
        outputTokens: addingClamped(lhs.outputTokens, rhs.outputTokens)
    )
}

func totalTokensClamped(_ usage: TokenBreakdown) -> Int64 {
    addingClamped(usage.inputTokens, usage.outputTokens)
}

private func addingClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    guard overflow else { return sum }
    return rhs >= 0 ? .max : .min
}
