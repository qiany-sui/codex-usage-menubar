import Foundation

public struct WeeklyQuotaSelector: Sendable {
    public init() {}

    public func select(
        from response: RateLimitsResponse,
        fetchedAt: Date
    ) -> QuotaSnapshot? {
        selection(from: response, fetchedAt: fetchedAt, patch: nil)?.quota
    }

    func selection(
        from response: RateLimitsResponse, fetchedAt: Date, patch: RateLimitBucketPatch?
    ) -> (quota: QuotaSnapshot, hasUsageReading: Bool)? {
        let buckets: [(key: String?, bucket: RateLimitBucket)]
        if let byID = response.rateLimitsByLimitId, !byID.isEmpty {
            buckets = byID.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        } else {
            buckets = [(nil, response.rateLimits)]
        }

        let candidates = buckets.flatMap { key, bucket in
            let applies = patch?.applies(to: bucket, mapKey: key, rootID: response.rateLimits.limitId)
            let bucketPatch = applies == true ? patch : nil
            let windows = [(bucket.primary, bucketPatch?.primary), (bucket.secondary, bucketPatch?.secondary)]
            return windows.compactMap { window, windowPatch -> Candidate? in
                guard
                    let window,
                    let duration = window.windowDurationMins,
                    let resetSeconds = window.resetsAt,
                    (9_000...11_000).contains(duration)
                else {
                    return nil
                }
                return Candidate(
                    limitID: bucket.limitId ?? "unknown",
                    window: window,
                    duration: duration,
                    resetSeconds: resetSeconds,
                    hasUsageReading: windowPatch?.value?.usedPercent.value != nil
                )
            }
        }

        guard let selected = candidates.min(by: Candidate.isPreferred) else {
            return nil
        }

        let resetsAt = Date(
            timeIntervalSince1970: TimeInterval(selected.resetSeconds)
        )
        let quota = QuotaSnapshot(
            limitID: selected.limitID,
            usedPercent: selected.window.usedPercent,
            windowDurationMinutes: selected.duration,
            startsAt: resetsAt.addingTimeInterval(
                -TimeInterval(selected.duration * 60)
            ),
            resetsAt: resetsAt,
            fetchedAt: fetchedAt
        )
        return (quota, selected.hasUsageReading)
    }
}

private struct Candidate {
    let limitID: String
    let window: RateLimitWindow
    let duration: Int
    let resetSeconds: Int64
    let hasUsageReading: Bool

    static func isPreferred(
        _ lhs: Candidate,
        _ rhs: Candidate
    ) -> Bool {
        let lhsCodexRank = lhs.limitID == "codex" ? 0 : 1
        let rhsCodexRank = rhs.limitID == "codex" ? 0 : 1
        if lhsCodexRank != rhsCodexRank {
            return lhsCodexRank < rhsCodexRank
        }
        let lhsDistance = abs(lhs.duration - 10_080)
        let rhsDistance = abs(rhs.duration - 10_080)
        if lhsDistance != rhsDistance {
            return lhsDistance < rhsDistance
        }
        if lhs.limitID != rhs.limitID {
            return lhs.limitID < rhs.limitID
        }
        return lhs.resetSeconds < rhs.resetSeconds
    }
}
