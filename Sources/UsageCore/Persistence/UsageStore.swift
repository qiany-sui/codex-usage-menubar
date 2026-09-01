import Foundation

public struct StoredUsageEvent: Codable, Equatable, Sendable {
    public let signature: Data
    public let occurredAt: Date
    public let localDay: LocalDay
    public let usage: TokenBreakdown

    public init(
        signature: Data,
        occurredAt: Date,
        localDay: LocalDay,
        usage: TokenBreakdown
    ) {
        self.signature = signature
        self.occurredAt = occurredAt
        self.localDay = localDay
        self.usage = usage
    }
}

public struct FileCursor: Codable, Equatable, Sendable {
    public let pathHash: Data
    public let deviceID: Int64
    public let inode: Int64
    public let committedOffset: Int64
    public let counterState: SessionCounterState

    public init(
        pathHash: Data,
        deviceID: Int64,
        inode: Int64,
        committedOffset: Int64,
        counterState: SessionCounterState
    ) {
        self.pathHash = pathHash
        self.deviceID = deviceID
        self.inode = inode
        self.committedOffset = committedOffset
        self.counterState = counterState
    }
}

public struct OfficialUsageDay: Codable, Equatable, Sendable {
    public let day: LocalDay
    public let tokens: Int64
    public let fetchedAt: Date

    public init(day: LocalDay, tokens: Int64, fetchedAt: Date) {
        self.day = day
        self.tokens = tokens
        self.fetchedAt = fetchedAt
    }
}

public enum UsageRefreshFailureSource: String, Codable, Hashable, Sendable {
    case accountInitialization
    case rateLimits
    case officialUsage
    case sessionIndexing
}

public struct UsageRefreshState: Codable, Equatable, Sendable {
    public let lastSuccessfulQuotaRefreshAt: Date?
    public let lastSuccessfulOfficialUsageRefreshAt: Date?
    public let consecutiveFailureCount: Int
    public let failedSources: Set<UsageRefreshFailureSource>

    public init(
        lastSuccessfulQuotaRefreshAt: Date?,
        lastSuccessfulOfficialUsageRefreshAt: Date?,
        consecutiveFailureCount: Int,
        failedSources: Set<UsageRefreshFailureSource>
    ) {
        self.lastSuccessfulQuotaRefreshAt = lastSuccessfulQuotaRefreshAt
        self.lastSuccessfulOfficialUsageRefreshAt = lastSuccessfulOfficialUsageRefreshAt
        self.consecutiveFailureCount = consecutiveFailureCount
        self.failedSources = failedSources
    }

    public static let empty = UsageRefreshState(
        lastSuccessfulQuotaRefreshAt: nil,
        lastSuccessfulOfficialUsageRefreshAt: nil,
        consecutiveFailureCount: 0,
        failedSources: []
    )
}

public protocol UsageStore: Actor {
    func close() throws
    func migrate() throws
    func insert(events: [StoredUsageEvent]) throws -> Int
    func ingest(events: [StoredUsageEvent], cursor: FileCursor) throws -> Int
    func events(from: Date, to: Date) throws -> [StoredUsageEvent]
    func cursor(for pathHash: Data) throws -> FileCursor?
    func save(cursor: FileCursor) throws
    func upsert(officialDays: [OfficialUsageDay]) throws
    func officialDays() throws -> [OfficialUsageDay]
    func save(quota: QuotaSnapshot) throws
    func latestQuota() throws -> QuotaSnapshot?
    func save(refreshState: UsageRefreshState) throws
    func refreshState() throws -> UsageRefreshState
    func replace(cycles: [QuotaCycle]) throws
    func cycles() throws -> [QuotaCycle]
    func pruneUsage(
        eventsBefore: Date,
        officialDaysBefore: LocalDay
    ) throws
}

public enum SQLiteStoreError: Error, Equatable, Sendable {
    case operationFailed(operation: String, code: Int32)
    case closed
    case tooManyCycles(Int)
}
