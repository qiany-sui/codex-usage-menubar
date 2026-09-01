import Foundation

public struct CycleTracker: Sendable {
    public init() {}

    public func update(
        existing: [QuotaCycle],
        quota: QuotaSnapshot,
        events: [StoredUsageEvent]
    ) -> [QuotaCycle] {
        var cycles = normalized(existing)

        if let current = cycles.last {
            let startDifference = quota.startsAt.timeIntervalSince(
                current.startsAt
            )
            if abs(startDifference) <= 1 {
                cycles[cycles.count - 1] = QuotaCycle(
                    startsAt: current.startsAt,
                    endsAt: quota.resetsAt,
                    usage: current.usage,
                    displayedTokens: current.displayedTokens,
                    status: current.status,
                    boundaryIsEstimated: false
                )
            } else if startDifference > 1 {
                cycles[cycles.count - 1] = QuotaCycle(
                    startsAt: current.startsAt,
                    endsAt: min(current.endsAt, quota.startsAt),
                    usage: current.usage,
                    displayedTokens: current.displayedTokens,
                    status: current.status,
                    boundaryIsEstimated: current.boundaryIsEstimated
                )
                cycles.append(
                    QuotaCycle(
                        startsAt: quota.startsAt,
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
                    startsAt: quota.startsAt,
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

    private func normalized(_ existing: [QuotaCycle]) -> [QuotaCycle] {
        let sorted = existing.sorted {
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
               candidate.startsAt.timeIntervalSince(current.startsAt) <= 1 {
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
