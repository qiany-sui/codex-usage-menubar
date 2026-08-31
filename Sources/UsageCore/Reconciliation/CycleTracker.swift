import Foundation

public struct CycleTracker: Sendable {
    public init() {}

    public func update(
        existing: [QuotaCycle],
        quota: QuotaSnapshot,
        events: [StoredUsageEvent]
    ) -> [QuotaCycle] {
        var cycles = existing.sorted { $0.startsAt < $1.startsAt }

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
                    boundaryIsEstimated: current.boundaryIsEstimated
                )
            } else if startDifference > 1 {
                cycles[cycles.count - 1] = QuotaCycle(
                    startsAt: current.startsAt,
                    endsAt: quota.startsAt,
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
