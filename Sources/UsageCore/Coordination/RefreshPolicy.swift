import Foundation

public enum RefreshReason: Sendable {
    case startup
    case scheduled
    case popoverOpened
    case wake
    case sessionFilesChanged
    case manual
}

public struct RefreshDecision: Equatable, Sendable {
    public let refreshQuota: Bool
    public let refreshOfficialUsage: Bool
    public let indexSessions: Bool

    public init(
        refreshQuota: Bool,
        refreshOfficialUsage: Bool,
        indexSessions: Bool
    ) {
        self.refreshQuota = refreshQuota
        self.refreshOfficialUsage = refreshOfficialUsage
        self.indexSessions = indexSessions
    }
}

public struct RefreshPolicy: Sendable {
    public init() {}

    public func decision(
        now: Date,
        reason: RefreshReason,
        lastQuotaRefresh: Date?,
        lastOfficialRefresh: Date?,
        consecutiveFailures: Int
    ) -> RefreshDecision {
        _ = consecutiveFailures
        switch reason {
        case .startup, .wake, .manual:
            return RefreshDecision(
                refreshQuota: true,
                refreshOfficialUsage: true,
                indexSessions: true
            )
        case .sessionFilesChanged:
            return RefreshDecision(
                refreshQuota: false,
                refreshOfficialUsage: false,
                indexSessions: true
            )
        case .scheduled:
            return RefreshDecision(
                refreshQuota: isDue(
                    now: now,
                    lastRefresh: lastQuotaRefresh,
                    interval: 300
                ),
                refreshOfficialUsage: isDue(
                    now: now,
                    lastRefresh: lastOfficialRefresh,
                    interval: 1_800
                ),
                indexSessions: true
            )
        case .popoverOpened:
            return RefreshDecision(
                refreshQuota: isDue(
                    now: now,
                    lastRefresh: lastQuotaRefresh,
                    interval: 60
                ),
                refreshOfficialUsage: isDue(
                    now: now,
                    lastRefresh: lastOfficialRefresh,
                    interval: 1_800
                ),
                indexSessions: true
            )
        }
    }

    public func retryDelay(consecutiveFailures: Int) -> Duration {
        let exponent = min(max(consecutiveFailures, 0), 5)
        return .seconds(min(30 * (1 << exponent), 900))
    }

    private func isDue(
        now: Date,
        lastRefresh: Date?,
        interval: TimeInterval
    ) -> Bool {
        guard let lastRefresh else { return true }
        let age = now.timeIntervalSince(lastRefresh)
        return age.isFinite && age >= interval
    }
}
