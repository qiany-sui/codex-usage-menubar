import Foundation
import XCTest
@testable import UsageCore

actor FakeAccountUsageClient: AccountUsageReading {
    let initialized: InitializeResult
    private var limits: RateLimitsResponse
    private var usage: AccountUsageResponse
    private var rateLimitsFailure: (any Error & Sendable)?
    private var usageFailure: (any Error & Sendable)?
    private var queuedNotifications: [AppServerNotification] = []
    private var initializeCallCount = 0
    private var rateLimitsCallCount = 0
    private var usageCallCount = 0
    private var notificationCallCount = 0

    init(
        initialized: InitializeResult,
        limits: RateLimitsResponse,
        usage: AccountUsageResponse
    ) {
        self.initialized = initialized
        self.limits = limits
        self.usage = usage
    }

    func initialize() async throws -> InitializeResult {
        initializeCallCount += 1
        return initialized
    }

    func readRateLimits() async throws -> RateLimitsResponse {
        rateLimitsCallCount += 1
        if let rateLimitsFailure { throw rateLimitsFailure }
        return limits
    }

    func readAccountUsage() async throws -> AccountUsageResponse {
        usageCallCount += 1
        if let usageFailure { throw usageFailure }
        return usage
    }

    func nextNotification() async -> AppServerNotification? {
        notificationCallCount += 1
        guard !queuedNotifications.isEmpty else { return nil }
        return queuedNotifications.removeFirst()
    }

    func setFailure(_ value: RPCErrorPayload?) {
        rateLimitsFailure = value
        usageFailure = value
    }

    func setRateLimitsFailure(_ value: RPCErrorPayload?) {
        rateLimitsFailure = value
    }

    func setUsageFailure(_ value: RPCErrorPayload?) {
        usageFailure = value
    }

    func setRateLimitsError(_ value: (any Error & Sendable)?) {
        rateLimitsFailure = value
    }

    func setUsageError(_ value: (any Error & Sendable)?) {
        usageFailure = value
    }

    func setLimits(_ value: RateLimitsResponse) {
        limits = value
    }

    func setUsage(_ value: AccountUsageResponse) {
        usage = value
    }

    func enqueue(_ value: AppServerNotification) {
        queuedNotifications.append(value)
    }

    func callCounts() -> (initialize: Int, limits: Int, usage: Int, notification: Int) {
        (
            initializeCallCount,
            rateLimitsCallCount,
            usageCallCount,
            notificationCallCount
        )
    }
}

actor CountingSessionIndexer: SessionUsageIndexing {
    private var callCount = 0

    func index(
        codexHome: URL,
        modifiedSince: Date,
        calendar: Calendar
    ) async throws -> SessionIndexResult {
        callCount += 1
        return SessionIndexResult(scannedFileCount: 0, insertedEventCount: 0)
    }

    func calls() -> Int { callCount }
}

private enum TestIndexerFailure: Error {
    case unavailable
}

actor FailingSessionIndexer: SessionUsageIndexing {
    func index(
        codexHome: URL,
        modifiedSince: Date,
        calendar: Calendar
    ) async throws -> SessionIndexResult {
        throw TestIndexerFailure.unavailable
    }
}

actor RecordingSessionIndexer: SessionUsageIndexing {
    private var recordedModifiedSince: Date?

    func index(
        codexHome: URL,
        modifiedSince: Date,
        calendar: Calendar
    ) async throws -> SessionIndexResult {
        recordedModifiedSince = modifiedSince
        return SessionIndexResult(scannedFileCount: 0, insertedEventCount: 0)
    }

    func modifiedSince() -> Date? { recordedModifiedSince }
}

struct StoreSideEffectCounts: Equatable, Sendable {
    let migrations: Int
    let writes: Int
}

actor ReadOnlyUsageStoreSpy: UsageStore {
    private let storedEvents: [StoredUsageEvent]
    private let storedOfficialDays: [OfficialUsageDay]
    private let storedQuota: QuotaSnapshot?
    private let storedCycles: [QuotaCycle]
    private var storedRefreshState: UsageRefreshState
    private var migrationCount = 0
    private var writeCount = 0

    init(
        events: [StoredUsageEvent] = [],
        officialDays: [OfficialUsageDay] = [],
        quota: QuotaSnapshot? = nil,
        cycles: [QuotaCycle] = [],
        refreshState: UsageRefreshState = .empty
    ) {
        storedEvents = events
        storedOfficialDays = officialDays
        storedQuota = quota
        storedCycles = cycles
        storedRefreshState = refreshState
    }

    func close() throws {}

    func migrate() throws { migrationCount += 1 }

    func insert(events: [StoredUsageEvent]) throws -> Int {
        writeCount += 1
        return events.count
    }

    func ingest(
        events: [StoredUsageEvent],
        cursor: FileCursor
    ) throws -> Int {
        writeCount += 1
        return events.count
    }

    func events(from: Date, to: Date) throws -> [StoredUsageEvent] {
        storedEvents.filter { from <= $0.occurredAt && $0.occurredAt < to }
    }

    func cursor(for pathHash: Data) throws -> FileCursor? { nil }

    func save(cursor: FileCursor) throws { writeCount += 1 }

    func upsert(officialDays: [OfficialUsageDay]) throws {
        writeCount += 1
    }

    func officialDays() throws -> [OfficialUsageDay] { storedOfficialDays }

    func save(quota: QuotaSnapshot) throws { writeCount += 1 }

    func latestQuota() throws -> QuotaSnapshot? { storedQuota }

    func save(refreshState: UsageRefreshState) throws {
        writeCount += 1
        storedRefreshState = refreshState
    }

    func refreshState() throws -> UsageRefreshState { storedRefreshState }

    func replace(cycles: [QuotaCycle]) throws { writeCount += 1 }

    func cycles() throws -> [QuotaCycle] { storedCycles }

    func pruneUsage(
        eventsBefore: Date,
        officialDaysBefore: LocalDay
    ) throws {
        writeCount += 1
    }

    func sideEffectCounts() -> StoreSideEffectCounts {
        StoreSideEffectCounts(
            migrations: migrationCount,
            writes: writeCount
        )
    }
}

actor InitializationGateAccountClient: AccountUsageReading {
    private let initialized: InitializeResult
    private let limits: RateLimitsResponse
    private let usage: AccountUsageResponse
    private var initializeCalls = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var gateIsOpen = false

    init(
        initialized: InitializeResult,
        limits: RateLimitsResponse,
        usage: AccountUsageResponse
    ) {
        self.initialized = initialized
        self.limits = limits
        self.usage = usage
    }

    func initialize() async throws -> InitializeResult {
        initializeCalls += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !gateIsOpen {
            await withCheckedContinuation { gateWaiters.append($0) }
        }
        return initialized
    }

    func readRateLimits() async throws -> RateLimitsResponse { limits }
    func readAccountUsage() async throws -> AccountUsageResponse { usage }
    func nextNotification() async -> AppServerNotification? { nil }

    func waitUntilInitializationStarts() async {
        guard initializeCalls == 0 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func openInitializationGate() {
        gateIsOpen = true
        let waiters = gateWaiters
        gateWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func initializationCount() -> Int { initializeCalls }
}

actor NotificationGateAccountClient: AccountUsageReading {
    private let initialized: InitializeResult
    private var limits: RateLimitsResponse
    private let usage: AccountUsageResponse
    private var notifications: [AppServerNotification] = []
    private var shouldBlockFirstNotification = false
    private var notificationCalls = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        initialized: InitializeResult,
        limits: RateLimitsResponse,
        usage: AccountUsageResponse
    ) {
        self.initialized = initialized
        self.limits = limits
        self.usage = usage
    }

    func initialize() async throws -> InitializeResult { initialized }
    func readRateLimits() async throws -> RateLimitsResponse { limits }
    func readAccountUsage() async throws -> AccountUsageResponse { usage }

    func nextNotification() async -> AppServerNotification? {
        notificationCalls += 1
        guard !notifications.isEmpty else { return nil }
        let notification = notifications.removeFirst()
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if shouldBlockFirstNotification, notificationCalls == 1 {
            await withCheckedContinuation { gateWaiters.append($0) }
        }
        return notification
    }

    func prepareBlockedNotifications(_ values: [AppServerNotification]) {
        notifications = values
        notificationCalls = 0
        shouldBlockFirstNotification = true
    }

    func waitUntilNotificationStarts() async {
        guard notificationCalls == 0 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstNotification() {
        shouldBlockFirstNotification = false
        let waiters = gateWaiters
        gateWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func notificationCount() -> Int { notificationCalls }
}

actor ParkedNotificationAccountClient: AccountUsageReading {
    private let initialized: InitializeResult
    private let limits: RateLimitsResponse
    private let usage: AccountUsageResponse
    private var initializeCalls = 0
    private var notificationCalls = 0
    private var notificationStartedAfterInitialization = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var notificationWaiter: CheckedContinuation<AppServerNotification?, Never>?

    init(
        initialized: InitializeResult,
        limits: RateLimitsResponse,
        usage: AccountUsageResponse
    ) {
        self.initialized = initialized
        self.limits = limits
        self.usage = usage
    }

    func initialize() async throws -> InitializeResult {
        initializeCalls += 1
        return initialized
    }

    func readRateLimits() async throws -> RateLimitsResponse { limits }
    func readAccountUsage() async throws -> AccountUsageResponse { usage }

    func nextNotification() async -> AppServerNotification? {
        notificationCalls += 1
        notificationStartedAfterInitialization = initializeCalls > 0
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { notificationWaiter = $0 }
    }

    func waitUntilNotificationStarts() async {
        guard notificationCalls == 0 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func enqueue(_ notification: AppServerNotification) {
        let waiter = notificationWaiter
        notificationWaiter = nil
        waiter?.resume(returning: notification)
    }

    func didInitializeBeforeListening() -> Bool {
        notificationStartedAfterInitialization
    }
}

struct ServiceFixture {
    let service: UsageService
    let store: SQLiteUsageStore
    let accountClient: FakeAccountUsageClient
    let codexHome: URL

    static func make() async throws -> ServiceFixture {
        let codexHome = try temporaryCodexHome()
        let session = codexHome
            .appendingPathComponent("sessions")
            .appendingPathComponent("service.jsonl")
        try Data(
            (
                tokenLine(
                    timestamp: "2026-08-31T01:00:00.000Z",
                    input: 100,
                    cached: 40,
                    output: 20
                ) + "\n"
            ).utf8
        ).write(to: session)
        let store = try SQLiteUsageStore(
            databaseURL: try temporaryDatabaseURL()
        )
        let client = FakeAccountUsageClient(
            initialized: InitializeResult(
                codexHome: codexHome.path,
                platformFamily: "unix",
                platformOs: "macos",
                userAgent: "test"
            ),
            limits: Self.fullLimits,
            usage: Self.fullUsage
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let service = UsageService(
            accountClient: client,
            indexer: SessionUsageIndexer(store: store),
            store: store,
            environment: [:],
            homeDirectory: codexHome.deletingLastPathComponent(),
            calendar: calendar
        )
        return ServiceFixture(
            service: service,
            store: store,
            accountClient: client,
            codexHome: codexHome
        )
    }

    static let fullLimits = RateLimitsResponse(
        rateLimits: RateLimitBucket(
            limitId: "codex",
            limitName: nil,
            primary: RateLimitWindow(
                usedPercent: 25,
                windowDurationMins: 10_080,
                resetsAt: 1_788_753_600
            ),
            secondary: nil
        ),
        rateLimitsByLimitId: nil
    )

    static let fullUsage = AccountUsageResponse(
        summary: AccountUsageSummary(
            lifetimeTokens: 1_234,
            peakDailyTokens: 500,
            longestRunningTurnSec: 30,
            currentStreakDays: 2,
            longestStreakDays: 4
        ),
        dailyUsageBuckets: [
            AccountTokenUsageDailyBucket(
                startDate: "2026-08-30",
                tokens: 400
            )
        ]
    )
}

final class UsageServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_148_800)

    func testConcurrentRefreshesInitializeOnlyOnce() async throws {
        let baselineNow = now
        let codexHome = try temporaryCodexHome()
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        let client = InitializationGateAccountClient(
            initialized: InitializeResult(
                codexHome: codexHome.path,
                platformFamily: "unix",
                platformOs: "macos",
                userAgent: "test"
            ),
            limits: ServiceFixture.fullLimits,
            usage: ServiceFixture.fullUsage
        )
        let service = makeService(
            accountClient: client,
            indexer: SessionUsageIndexer(store: store),
            store: store,
            codexHome: codexHome
        )
        let first = Task {
            try await service.refresh(reason: .startup, now: baselineNow)
        }
        await client.waitUntilInitializationStarts()
        let secondLaunched = expectation(description: "second refresh launched")
        let second = Task {
            secondLaunched.fulfill()
            return try await service.refresh(
                reason: .startup,
                now: baselineNow.addingTimeInterval(1)
            )
        }
        await fulfillment(of: [secondLaunched], timeout: 1)
        for _ in 0..<200 { await Task.yield() }
        let countWhileBlocked = await client.initializationCount()

        XCTAssertEqual(countWhileBlocked, 1)

        await client.openInitializationGate()
        _ = try await first.value
        _ = try await second.value
        let finalCount = await client.initializationCount()
        XCTAssertEqual(finalCount, 1)
    }

    func testCancelledQueuedRefreshReleasesNextWaiter() async throws {
        let baselineNow = now
        let codexHome = try temporaryCodexHome()
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        let client = InitializationGateAccountClient(
            initialized: InitializeResult(
                codexHome: codexHome.path,
                platformFamily: "unix",
                platformOs: "macos",
                userAgent: "test"
            ),
            limits: ServiceFixture.fullLimits,
            usage: ServiceFixture.fullUsage
        )
        let service = makeService(
            accountClient: client,
            indexer: SessionUsageIndexer(store: store),
            store: store,
            codexHome: codexHome
        )
        let first = Task {
            try await service.refresh(reason: .startup, now: baselineNow)
        }
        await client.waitUntilInitializationStarts()
        let second = Task {
            try await service.refresh(
                reason: .manual,
                now: baselineNow.addingTimeInterval(1)
            )
        }
        await waitUntilOperationQueueDepth(1, service: service)
        let depthBeforeCancellation = await service.operationQueueDepth()
        XCTAssertEqual(depthBeforeCancellation, 1)
        second.cancel()
        let thirdCompleted = expectation(description: "third refresh completes")
        let third = Task {
            let snapshot = try await service.refresh(
                reason: .manual,
                now: baselineNow.addingTimeInterval(2)
            )
            thirdCompleted.fulfill()
            return snapshot
        }
        await waitUntilOperationQueueDepth(2, service: service)
        let depthBeforeRelease = await service.operationQueueDepth()
        XCTAssertEqual(depthBeforeRelease, 2)

        await client.openInitializationGate()
        _ = try await first.value
        await XCTAssertThrowsErrorAsync(try await second.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        await fulfillment(of: [thirdCompleted], timeout: 2)
        _ = try await third.value
        let finalDepth = await service.operationQueueDepth()
        XCTAssertEqual(finalDepth, 0)
    }

    func testConcurrentNotificationsMergeInQueueOrder() async throws {
        let baselineNow = now
        let codexHome = try temporaryCodexHome()
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        let client = NotificationGateAccountClient(
            initialized: InitializeResult(
                codexHome: codexHome.path,
                platformFamily: "unix",
                platformOs: "macos",
                userAgent: "test"
            ),
            limits: ServiceFixture.fullLimits,
            usage: ServiceFixture.fullUsage
        )
        let service = makeService(
            accountClient: client,
            indexer: SessionUsageIndexer(store: store),
            store: store,
            codexHome: codexHome
        )
        _ = try await service.refresh(reason: .startup, now: baselineNow)
        let firstUpdate = try rateLimitUpdate(usedPercent: 31)
        let secondUpdate = try rateLimitUpdate(usedPercent: 42)
        await client.prepareBlockedNotifications([
            .rateLimitsUpdated(firstUpdate),
            .rateLimitsUpdated(secondUpdate)
        ])
        let first = Task {
            try await service.processNextAccountNotification(
                now: baselineNow.addingTimeInterval(1)
            )
        }
        await client.waitUntilNotificationStarts()
        let secondLaunched = expectation(description: "second notification launched")
        let second = Task {
            secondLaunched.fulfill()
            return try await service.processNextAccountNotification(
                now: baselineNow.addingTimeInterval(2)
            )
        }
        await fulfillment(of: [secondLaunched], timeout: 1)
        for _ in 0..<200 { await Task.yield() }
        let countWhileBlocked = await client.notificationCount()

        XCTAssertEqual(countWhileBlocked, 1)

        await client.releaseFirstNotification()
        _ = try await first.value
        _ = try await second.value
        let snapshot = try await service.currentSnapshot(
            now: baselineNow.addingTimeInterval(2)
        )
        let finalCount = await client.notificationCount()
        XCTAssertEqual(snapshot.quota?.remainingPercent, 58)
        XCTAssertEqual(finalCount, 2)
    }

    func testParkedNotificationReadDoesNotBlockRefreshOrCurrentSnapshot() async throws {
        let baselineNow = now
        let codexHome = try temporaryCodexHome()
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        let client = ParkedNotificationAccountClient(
            initialized: InitializeResult(
                codexHome: codexHome.path,
                platformFamily: "unix",
                platformOs: "macos",
                userAgent: "test"
            ),
            limits: ServiceFixture.fullLimits,
            usage: ServiceFixture.fullUsage
        )
        let service = makeService(
            accountClient: client,
            indexer: CountingSessionIndexer(),
            store: store,
            codexHome: codexHome
        )
        let notification = Task {
            try await service.processNextAccountNotification(now: baselineNow)
        }
        await client.waitUntilNotificationStarts()

        let refreshFinished = expectation(description: "refresh finishes while notification waits")
        let refresh = Task {
            let snapshot = try await service.refresh(
                reason: .sessionFilesChanged,
                now: baselineNow.addingTimeInterval(1)
            )
            refreshFinished.fulfill()
            return snapshot
        }
        let snapshotFinished = expectation(
            description: "current snapshot finishes while notification waits"
        )
        let current = Task {
            let snapshot = try await service.currentSnapshot(
                now: baselineNow.addingTimeInterval(1)
            )
            snapshotFinished.fulfill()
            return snapshot
        }

        await fulfillment(of: [refreshFinished, snapshotFinished], timeout: 1)
        let initializedBeforeListening = await client.didInitializeBeforeListening()
        XCTAssertTrue(initializedBeforeListening)

        await client.enqueue(
            .rateLimitsUpdated(try rateLimitUpdate(usedPercent: 31))
        )
        _ = try await refresh.value
        _ = try await current.value
        _ = try await notification.value
    }

    func testRefreshPersistsRemoteDataIndexesSessionsAndBuildsSnapshot() async throws {
        let fixture = try await ServiceFixture.make()

        let snapshot = try await fixture.service.refresh(
            reason: .startup,
            now: now
        )
        let officialDays = try await fixture.store.officialDays()
        let cycles = try await fixture.store.cycles()

        XCTAssertEqual(snapshot.quota?.remainingPercent, 75)
        XCTAssertEqual(snapshot.today.displayedTokens, 120)
        XCTAssertEqual(officialDays.first?.tokens, 400)
        XCTAssertEqual(cycles.count, 9)
    }

    func testFirstRefreshPersistsNineCyclesAndIndexesFromOldestEstimatedBoundary() async throws {
        let codexHome = try temporaryCodexHome()
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        let currentStart = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let duration = TimeInterval(10_080 * 60)
        let client = FakeAccountUsageClient(
            initialized: InitializeResult(
                codexHome: codexHome.path,
                platformFamily: "unix",
                platformOs: "macos",
                userAgent: "test"
            ),
            limits: RateLimitsResponse(
                rateLimits: RateLimitBucket(
                    limitId: "codex",
                    limitName: nil,
                    primary: RateLimitWindow(
                        usedPercent: 25,
                        windowDurationMins: 10_080,
                        resetsAt: Int64(
                            currentStart.addingTimeInterval(duration)
                                .timeIntervalSince1970
                        )
                    ),
                    secondary: nil
                ),
                rateLimitsByLimitId: nil
            ),
            usage: ServiceFixture.fullUsage
        )
        let indexer = RecordingSessionIndexer()
        let service = makeService(
            accountClient: client,
            indexer: indexer,
            store: store,
            codexHome: codexHome
        )

        let snapshot = try await service.refresh(reason: .startup, now: now)
        let cycles = try await store.cycles()
        let modifiedSince = await indexer.modifiedSince()

        XCTAssertEqual(cycles.count, 9)
        XCTAssertEqual(snapshot.cycleHistory.count, 8)
        XCTAssertTrue(cycles.dropLast().allSatisfy(\.boundaryIsEstimated))
        XCTAssertFalse(cycles.last?.boundaryIsEstimated ?? true)
        XCTAssertEqual(
            modifiedSince,
            currentStart.addingTimeInterval(-8 * duration)
        )
    }

    func testRemoteFailureKeepsLastQuotaAndMarksSnapshotStale() async throws {
        let fixture = try await ServiceFixture.make()
        _ = try await fixture.service.refresh(reason: .startup, now: now)
        await fixture.accountClient.setFailure(
            RPCErrorPayload(
                code: -32600,
                message: "authentication required",
                data: nil
            )
        )

        let snapshot = try await fixture.service.refresh(
            reason: .manual,
            now: now.addingTimeInterval(1)
        )
        let officialDays = try await fixture.store.officialDays()

        XCTAssertEqual(snapshot.quota?.remainingPercent, 75)
        XCTAssertEqual(snapshot.status, .stale)
        XCTAssertEqual(officialDays.count, 1)
    }

    func testRemoteFailureKeepsCurrentSnapshotStale() async throws {
        let fixture = try await ServiceFixture.make()
        _ = try await fixture.service.refresh(reason: .startup, now: now)
        await fixture.accountClient.setRateLimitsFailure(rpcFailure())
        _ = try await fixture.service.refresh(
            reason: .manual,
            now: now.addingTimeInterval(1)
        )

        let snapshot = try await fixture.service.currentSnapshot(
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(snapshot.status, .stale)
    }

    func testSessionOnlySuccessDoesNotClearRateLimitFailure() async throws {
        let fixture = try await ServiceFixture.make()
        _ = try await fixture.service.refresh(reason: .startup, now: now)
        await fixture.accountClient.setRateLimitsFailure(rpcFailure())
        _ = try await fixture.service.refresh(
            reason: .manual,
            now: now.addingTimeInterval(1)
        )
        await fixture.accountClient.setRateLimitsFailure(nil)

        let snapshot = try await fixture.service.refresh(
            reason: .sessionFilesChanged,
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(snapshot.status, .stale)
    }

    func testReopenedServiceKeepsPersistedRemoteFailureStale() async throws {
        let codexHome = try temporaryCodexHome()
        let databaseURL = try temporaryDatabaseURL()
        let store = try SQLiteUsageStore(databaseURL: databaseURL)
        let client = FakeAccountUsageClient(
            initialized: InitializeResult(
                codexHome: codexHome.path,
                platformFamily: "unix",
                platformOs: "macos",
                userAgent: "test"
            ),
            limits: ServiceFixture.fullLimits,
            usage: ServiceFixture.fullUsage
        )
        let service = makeService(
            accountClient: client,
            indexer: CountingSessionIndexer(),
            store: store,
            codexHome: codexHome
        )
        _ = try await service.refresh(reason: .startup, now: now)
        await client.setRateLimitsFailure(rpcFailure())
        _ = try await service.refresh(
            reason: .manual,
            now: now.addingTimeInterval(1)
        )
        try await store.close()

        let reopenedStore = try SQLiteUsageStore(databaseURL: databaseURL)
        let reopenedService = makeService(
            accountClient: FakeAccountUsageClient(
                initialized: InitializeResult(
                    codexHome: codexHome.path,
                    platformFamily: "unix",
                    platformOs: "macos",
                    userAgent: "test"
                ),
                limits: ServiceFixture.fullLimits,
                usage: ServiceFixture.fullUsage
            ),
            indexer: CountingSessionIndexer(),
            store: reopenedStore,
            codexHome: codexHome
        )

        let snapshot = try await reopenedService.currentSnapshot(
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(snapshot.status, .stale)
    }

    func testMatchingRemoteSuccessClearsPersistedFailure() async throws {
        let fixture = try await ServiceFixture.make()
        _ = try await fixture.service.refresh(reason: .startup, now: now)
        await fixture.accountClient.setRateLimitsFailure(rpcFailure())
        _ = try await fixture.service.refresh(
            reason: .manual,
            now: now.addingTimeInterval(1)
        )
        await fixture.accountClient.setRateLimitsFailure(nil)

        let snapshot = try await fixture.service.refresh(
            reason: .manual,
            now: now.addingTimeInterval(2)
        )
        let state = try await fixture.store.refreshState()

        XCTAssertNotEqual(snapshot.status, .stale)
        XCTAssertFalse(state.failedSources.contains(.rateLimits))
    }

    func testQuotaSuccessSurvivesOfficialFailureAndMarksImmediateStale() async throws {
        let fixture = try await ServiceFixture.make()
        _ = try await fixture.service.refresh(reason: .startup, now: now)
        await fixture.accountClient.setLimits(
            RateLimitsResponse(
                rateLimits: RateLimitBucket(
                    limitId: "codex",
                    limitName: nil,
                    primary: RateLimitWindow(
                        usedPercent: 30,
                        windowDurationMins: 10_080,
                        resetsAt: 1_788_753_600
                    ),
                    secondary: nil
                ),
                rateLimitsByLimitId: nil
            )
        )
        await fixture.accountClient.setUsageFailure(rpcFailure())

        let snapshot = try await fixture.service.refresh(
            reason: .manual,
            now: now.addingTimeInterval(1)
        )
        let days = try await fixture.store.officialDays()

        XCTAssertEqual(snapshot.quota?.remainingPercent, 70)
        XCTAssertEqual(snapshot.quota?.fetchedAt, now.addingTimeInterval(1))
        XCTAssertEqual(snapshot.status, .stale)
        XCTAssertEqual(days.map(\.tokens), [400])
    }

    func testOfficialSuccessSurvivesQuotaFailureAndMarksImmediateStale() async throws {
        let fixture = try await ServiceFixture.make()
        _ = try await fixture.service.refresh(reason: .startup, now: now)
        await fixture.accountClient.setRateLimitsFailure(rpcFailure())
        await fixture.accountClient.setUsage(
            AccountUsageResponse(
                summary: ServiceFixture.fullUsage.summary,
                dailyUsageBuckets: [
                    AccountTokenUsageDailyBucket(
                        startDate: "2026-08-30",
                        tokens: 450
                    )
                ]
            )
        )

        let snapshot = try await fixture.service.refresh(
            reason: .manual,
            now: now.addingTimeInterval(1)
        )
        let days = try await fixture.store.officialDays()

        XCTAssertEqual(snapshot.quota?.remainingPercent, 75)
        XCTAssertEqual(snapshot.quota?.fetchedAt, now)
        XCTAssertEqual(snapshot.status, .stale)
        XCTAssertEqual(days.map(\.tokens), [450])
    }

    func testRemoteSQLiteShapedErrorsStillDegradeInsteadOfThrowing() async throws {
        let quotaFixture = try await ServiceFixture.make()
        _ = try await quotaFixture.service.refresh(reason: .startup, now: now)
        await quotaFixture.accountClient.setRateLimitsError(
            SQLiteStoreError.closed
        )

        let quotaSnapshot = try await quotaFixture.service.refresh(
            reason: .manual,
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(quotaSnapshot.quota?.remainingPercent, 75)
        XCTAssertEqual(quotaSnapshot.status, .stale)

        let usageFixture = try await ServiceFixture.make()
        _ = try await usageFixture.service.refresh(reason: .startup, now: now)
        await usageFixture.accountClient.setUsageError(
            SQLiteStoreError.closed
        )

        let usageSnapshot = try await usageFixture.service.refresh(
            reason: .manual,
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(usageSnapshot.quota?.remainingPercent, 75)
        XCTAssertEqual(usageSnapshot.status, .stale)
    }

    func testNilDailyBucketsKeepStoredDaysAndMarkImmediateStale() async throws {
        let fixture = try await ServiceFixture.make()
        _ = try await fixture.service.refresh(reason: .startup, now: now)
        await fixture.accountClient.setUsage(
            AccountUsageResponse(
                summary: ServiceFixture.fullUsage.summary,
                dailyUsageBuckets: nil
            )
        )

        let snapshot = try await fixture.service.refresh(
            reason: .manual,
            now: now.addingTimeInterval(1)
        )
        let days = try await fixture.store.officialDays()

        XCTAssertEqual(snapshot.status, .stale)
        XCTAssertEqual(days.map(\.tokens), [400])
    }

    func testIndexerFailureKeepsRemoteDataAndMarksStale() async throws {
        let codexHome = try temporaryCodexHome()
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        let client = FakeAccountUsageClient(
            initialized: InitializeResult(
                codexHome: codexHome.path,
                platformFamily: "unix",
                platformOs: "macos",
                userAgent: "test"
            ),
            limits: ServiceFixture.fullLimits,
            usage: ServiceFixture.fullUsage
        )
        let service = makeService(
            accountClient: client,
            indexer: FailingSessionIndexer(),
            store: store,
            codexHome: codexHome
        )

        let snapshot = try await service.refresh(reason: .startup, now: now)
        let days = try await store.officialDays()

        XCTAssertEqual(snapshot.quota?.remainingPercent, 75)
        XCTAssertEqual(snapshot.status, .stale)
        XCTAssertEqual(days.map(\.tokens), [400])
    }

    func testSparseNotificationMergesWithLastFullQuota() async throws {
        let fixture = try await ServiceFixture.make()
        _ = try await fixture.service.refresh(reason: .startup, now: now)
        let update = try JSONDecoder().decode(
            RateLimitsUpdatedParams.self,
            from: Data(
                #"{"rateLimits":{"primary":{"usedPercent":31}}}"#.utf8
            )
        )
        await fixture.accountClient.enqueue(.rateLimitsUpdated(update))

        let snapshot = try await fixture.service.processNextAccountNotification(
            now: now.addingTimeInterval(5)
        )

        XCTAssertEqual(snapshot?.quota?.remainingPercent, 69)
        XCTAssertEqual(snapshot?.quota?.windowDurationMinutes, 10_080)
    }

    func testNotificationWithoutFullResponseFallsBackToRead() async throws {
        let fixture = try await ServiceFixture.make()
        await fixture.accountClient.enqueue(
            .rateLimitsUpdated(try rateLimitUpdate(usedPercent: 31))
        )

        let snapshot = try await fixture.service.processNextAccountNotification(
            now: now
        )
        let counts = await fixture.accountClient.callCounts()

        XCTAssertEqual(snapshot?.quota?.remainingPercent, 75)
        XCTAssertEqual(counts.initialize, 1)
        XCTAssertEqual(counts.limits, 1)
    }

    func testUnselectableNotificationFallsBackToLatestFullRead() async throws {
        let fixture = try await ServiceFixture.make()
        _ = try await fixture.service.refresh(reason: .startup, now: now)
        await fixture.accountClient.setLimits(
            RateLimitsResponse(
                rateLimits: RateLimitBucket(
                    limitId: "codex",
                    limitName: nil,
                    primary: RateLimitWindow(
                        usedPercent: 40,
                        windowDurationMins: 10_080,
                        resetsAt: 1_788_753_600
                    ),
                    secondary: nil
                ),
                rateLimitsByLimitId: nil
            )
        )
        await fixture.accountClient.enqueue(
            .rateLimitsUpdated(try clearingPrimaryUpdate())
        )

        let snapshot = try await fixture.service.processNextAccountNotification(
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(snapshot?.quota?.remainingPercent, 60)
        XCTAssertNotEqual(snapshot?.status, .stale)
    }

    func testNotificationFallbackFailureKeepsQuotaAndReturnsStale() async throws {
        let fixture = try await ServiceFixture.make()
        _ = try await fixture.service.refresh(reason: .startup, now: now)
        await fixture.accountClient.setRateLimitsFailure(rpcFailure())
        await fixture.accountClient.enqueue(
            .rateLimitsUpdated(try clearingPrimaryUpdate())
        )

        let snapshot = try await fixture.service.processNextAccountNotification(
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(snapshot?.quota?.remainingPercent, 75)
        XCTAssertEqual(snapshot?.status, .stale)
    }

    func testConsecutiveSparseNotificationsMergeWithLatestFullState() async throws {
        let fixture = try await ServiceFixture.make()
        _ = try await fixture.service.refresh(reason: .startup, now: now)
        await fixture.accountClient.enqueue(
            .rateLimitsUpdated(try rateLimitUpdate(usedPercent: 31))
        )
        await fixture.accountClient.enqueue(
            .rateLimitsUpdated(try rateLimitUpdate(usedPercent: 42))
        )

        _ = try await fixture.service.processNextAccountNotification(
            now: now.addingTimeInterval(1)
        )
        let second = try await fixture.service.processNextAccountNotification(
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(second?.quota?.remainingPercent, 58)
        XCTAssertEqual(second?.quota?.windowDurationMinutes, 10_080)
    }

    func testInvalidOfficialDayIsIgnoredWithoutDeletingStoredDays() async throws {
        let fixture = try await ServiceFixture.make()
        _ = try await fixture.service.refresh(reason: .startup, now: now)
        await fixture.accountClient.setUsage(
            AccountUsageResponse(
                summary: AccountUsageSummary(
                    lifetimeTokens: nil,
                    peakDailyTokens: nil,
                    longestRunningTurnSec: nil,
                    currentStreakDays: nil,
                    longestStreakDays: nil
                ),
                dailyUsageBuckets: [
                    AccountTokenUsageDailyBucket(
                        startDate: "2026-02-30",
                        tokens: 999
                    ),
                    AccountTokenUsageDailyBucket(
                        startDate: "2026-08-29",
                        tokens: 300
                    )
                ]
            )
        )

        let snapshot = try await fixture.service.refresh(
            reason: .manual,
            now: now.addingTimeInterval(1)
        )
        let days = try await fixture.store.officialDays()

        XCTAssertEqual(snapshot.status, .stale)
        XCTAssertEqual(days.map(\.day.iso8601), ["2026-08-29", "2026-08-30"])
        XCTAssertEqual(days.map(\.tokens), [300, 400])
    }

    func testMissingWeeklyWindowDoesNotOverwriteStoredQuota() async throws {
        let fixture = try await ServiceFixture.make()
        _ = try await fixture.service.refresh(reason: .startup, now: now)
        await fixture.accountClient.setLimits(
            RateLimitsResponse(
                rateLimits: RateLimitBucket(
                    limitId: "codex",
                    limitName: nil,
                    primary: RateLimitWindow(
                        usedPercent: 90,
                        windowDurationMins: 300,
                        resetsAt: 1_788_753_600
                    ),
                    secondary: nil
                ),
                rateLimitsByLimitId: nil
            )
        )

        let snapshot = try await fixture.service.refresh(
            reason: .manual,
            now: now.addingTimeInterval(60)
        )
        let storedQuota = try await fixture.store.latestQuota()

        XCTAssertEqual(snapshot.quota?.remainingPercent, 75)
        XCTAssertEqual(snapshot.status, .stale)
        XCTAssertEqual(storedQuota?.remainingPercent, 75)
    }

    func testUnavailableHomeStillReturnsPreviouslyStoredUsage() async throws {
        let fixture = try await ServiceFixture.make()
        _ = try await fixture.service.refresh(reason: .startup, now: now)
        try FileManager.default.removeItem(at: fixture.codexHome)

        let snapshot = try await fixture.service.refresh(
            reason: .sessionFilesChanged,
            now: now.addingTimeInterval(5)
        )

        XCTAssertEqual(snapshot.today.displayedTokens, 120)
        XCTAssertEqual(snapshot.status, .stale)
    }

    func testCurrentSnapshotDoesNotInitializeIndexOrReadNetwork() async throws {
        let codexHome = try temporaryCodexHome()
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        try await store.migrate()
        let storedQuota = QuotaSnapshot(
            limitID: "codex",
            usedPercent: 25,
            windowDurationMinutes: 10_080,
            startsAt: now.addingTimeInterval(-3 * 24 * 60 * 60),
            resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60),
            fetchedAt: now.addingTimeInterval(-10)
        )
        try await store.save(quota: storedQuota)
        let client = FakeAccountUsageClient(
            initialized: InitializeResult(
                codexHome: codexHome.path,
                platformFamily: "unix",
                platformOs: "macos",
                userAgent: "test"
            ),
            limits: ServiceFixture.fullLimits,
            usage: ServiceFixture.fullUsage
        )
        let indexer = CountingSessionIndexer()
        let service = makeService(
            accountClient: client,
            indexer: indexer,
            store: store,
            codexHome: codexHome
        )

        let snapshot = try await service.currentSnapshot(now: now)
        let clientCounts = await client.callCounts()
        let indexCalls = await indexer.calls()

        XCTAssertEqual(snapshot.quota, storedQuota)
        XCTAssertEqual(clientCounts.initialize, 0)
        XCTAssertEqual(clientCounts.limits, 0)
        XCTAssertEqual(clientCounts.usage, 0)
        XCTAssertEqual(clientCounts.notification, 0)
        XCTAssertEqual(indexCalls, 0)
    }

    func testCurrentSnapshotDoesNotMigrateOrWriteStore() async throws {
        let codexHome = try temporaryCodexHome()
        let storedQuota = QuotaSnapshot(
            limitID: "codex",
            usedPercent: 25,
            windowDurationMinutes: 10_080,
            startsAt: now.addingTimeInterval(-3 * 24 * 60 * 60),
            resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60),
            fetchedAt: now.addingTimeInterval(-10)
        )
        let store = ReadOnlyUsageStoreSpy(quota: storedQuota)
        let service = makeService(
            accountClient: FakeAccountUsageClient(
                initialized: InitializeResult(
                    codexHome: codexHome.path,
                    platformFamily: "unix",
                    platformOs: "macos",
                    userAgent: "test"
                ),
                limits: ServiceFixture.fullLimits,
                usage: ServiceFixture.fullUsage
            ),
            indexer: CountingSessionIndexer(),
            store: store,
            codexHome: codexHome
        )

        let snapshot = try await service.currentSnapshot(now: now)
        let sideEffects = await store.sideEffectCounts()

        XCTAssertEqual(snapshot.quota, storedQuota)
        XCTAssertEqual(
            sideEffects,
            StoreSideEffectCounts(migrations: 0, writes: 0)
        )
    }

    func testNineRetainedCyclesPruneOnlyUsageBeforeEarliestCycle() async throws {
        let fixture = try await ServiceFixture.make()
        try await fixture.store.migrate()
        let week = TimeInterval(7 * 24 * 60 * 60)
        let earliestStart = now.addingTimeInterval(-8 * week)
        let cycles = (0..<8).map { index in
            let startsAt = earliestStart.addingTimeInterval(
                TimeInterval(index) * week
            )
            return QuotaCycle(
                startsAt: startsAt,
                endsAt: startsAt.addingTimeInterval(week),
                usage: .zero,
                displayedTokens: 0,
                status: .localLive,
                boundaryIsEstimated: false
            )
        }
        try await fixture.store.replace(cycles: cycles)
        let cursor = FileCursor(
            pathHash: Data([0x01, 0x02, 0x03]),
            deviceID: 10,
            inode: 20,
            committedOffset: 30,
            counterState: SessionCounterState(previousTotal: nil)
        )
        try await fixture.store.save(cursor: cursor)
        let oldEvent = storedEvent(
            at: earliestStart.addingTimeInterval(-1),
            input: 10,
            output: 1
        )
        let keptEvent = storedEvent(
            at: earliestStart,
            input: 20,
            output: 2
        )
        _ = try await fixture.store.insert(events: [oldEvent, keptEvent])
        try await fixture.store.upsert(
            officialDays: [
                OfficialUsageDay(
                    day: LocalDay(year: 2026, month: 7, day: 5),
                    tokens: 100,
                    fetchedAt: now
                ),
                OfficialUsageDay(
                    day: LocalDay(year: 2026, month: 7, day: 6),
                    tokens: 200,
                    fetchedAt: now
                )
            ]
        )

        _ = try await fixture.service.refresh(reason: .startup, now: now)
        let retainedEvents = try await fixture.store.events(
            from: .distantPast,
            to: .distantFuture
        )
        let retainedDays = try await fixture.store.officialDays()
        let retainedCursor = try await fixture.store.cursor(
            for: cursor.pathHash
        )

        XCTAssertFalse(retainedEvents.contains { $0.signature == oldEvent.signature })
        XCTAssertTrue(retainedEvents.contains { $0.signature == keptEvent.signature })
        XCTAssertEqual(
            retainedDays.map(\.day.iso8601),
            ["2026-07-06", "2026-08-30"]
        )
        XCTAssertEqual(retainedCursor, cursor)
    }

    func testOldestRetainedCycleUsesEventsOlderThanIndexWindow() async throws {
        let fixture = try await ServiceFixture.make()
        try await fixture.store.migrate()
        let week = TimeInterval(7 * 24 * 60 * 60)
        let currentStart = now.addingTimeInterval(-week / 2)
        let earliestStart = currentStart.addingTimeInterval(-8 * week)
        let cycles = (0..<8).map { index in
            let startsAt = earliestStart.addingTimeInterval(
                TimeInterval(index) * week
            )
            return QuotaCycle(
                startsAt: startsAt,
                endsAt: startsAt.addingTimeInterval(week),
                usage: .zero,
                displayedTokens: 0,
                status: .localLive,
                boundaryIsEstimated: false
            )
        }
        try await fixture.store.replace(cycles: cycles)
        _ = try await fixture.store.insert(
            events: [
                storedEvent(
                    at: earliestStart.addingTimeInterval(60),
                    input: 30,
                    output: 3
                )
            ]
        )
        await fixture.accountClient.setLimits(
            RateLimitsResponse(
                rateLimits: RateLimitBucket(
                    limitId: "codex",
                    limitName: nil,
                    primary: RateLimitWindow(
                        usedPercent: 25,
                        windowDurationMins: 10_080,
                        resetsAt: Int64(now.addingTimeInterval(week / 2).timeIntervalSince1970)
                    ),
                    secondary: nil
                ),
                rateLimitsByLimitId: nil
            )
        )

        _ = try await fixture.service.refresh(reason: .startup, now: now)
        let retainedCycles = try await fixture.store.cycles()

        XCTAssertEqual(retainedCycles.count, 9)
        XCTAssertEqual(retainedCycles.first?.startsAt, earliestStart)
        XCTAssertEqual(retainedCycles.first?.usage.inputTokens, 30)
        XCTAssertEqual(retainedCycles.first?.usage.outputTokens, 3)
    }

    func testIndexerScanWindowRespectsOlderStoredCycleBoundary() async throws {
        let codexHome = try temporaryCodexHome()
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        try await store.migrate()
        let oldCycle = QuotaCycle(
            startsAt: now.addingTimeInterval(-70 * 24 * 60 * 60),
            endsAt: now.addingTimeInterval(-63 * 24 * 60 * 60),
            usage: .zero,
            displayedTokens: 0,
            status: .localLive,
            boundaryIsEstimated: false
        )
        try await store.replace(cycles: [oldCycle])
        let client = FakeAccountUsageClient(
            initialized: InitializeResult(
                codexHome: codexHome.path,
                platformFamily: "unix",
                platformOs: "macos",
                userAgent: "test"
            ),
            limits: ServiceFixture.fullLimits,
            usage: ServiceFixture.fullUsage
        )
        let indexer = RecordingSessionIndexer()
        let service = makeService(
            accountClient: client,
            indexer: indexer,
            store: store,
            codexHome: codexHome
        )

        _ = try await service.refresh(reason: .startup, now: now)
        let cutoff = await indexer.modifiedSince()

        XCTAssertEqual(
            cutoff,
            oldCycle.startsAt
        )
    }

    func testOtherNotificationReturnsNil() async throws {
        let fixture = try await ServiceFixture.make()
        await fixture.accountClient.enqueue(.other(method: "thread/started"))
        let snapshot = try await fixture.service.processNextAccountNotification(
            now: now
        )

        XCTAssertNil(snapshot)
    }

    func testDirectoryWatcherEmitsAndStopsCleanly() async throws {
        let directory = try temporaryDirectory()
        let watcher = SessionDirectoryWatcher(
            coalescingDelay: .milliseconds(50)
        )
        let stream = await watcher.changes(for: [directory])
        let first = expectation(description: "first change")
        let unexpectedSecond = expectation(description: "no event after stop")
        unexpectedSecond.isInverted = true
        let consumer = Task {
            var count = 0
            for await _ in stream {
                count += 1
                if count == 1 {
                    first.fulfill()
                } else {
                    unexpectedSecond.fulfill()
                }
            }
        }

        try Data("one\n".utf8).write(
            to: directory.appendingPathComponent("one.jsonl")
        )
        await fulfillment(of: [first], timeout: 2)

        await watcher.stop()
        try Data("two\n".utf8).write(
            to: directory.appendingPathComponent("two.jsonl")
        )
        await fulfillment(of: [unexpectedSecond], timeout: 0.3)
        consumer.cancel()
    }

    func testDirectoryWatcherCoalescesBurstIntoOneTrailingChange() async throws {
        let directory = try temporaryDirectory()
        let watcher = SessionDirectoryWatcher(
            coalescingDelay: .milliseconds(200)
        )
        let stream = await watcher.changes(for: [directory])
        let leading = expectation(description: "leading change")
        let trailing = expectation(description: "one trailing change")
        let unexpectedThird = expectation(description: "no third change")
        unexpectedThird.isInverted = true
        let consumer = Task {
            var count = 0
            for await _ in stream {
                count += 1
                switch count {
                case 1:
                    leading.fulfill()
                case 2:
                    trailing.fulfill()
                default:
                    unexpectedThird.fulfill()
                }
            }
        }

        try Data("first\n".utf8).write(
            to: directory.appendingPathComponent("first.jsonl")
        )
        await fulfillment(of: [leading], timeout: 2)
        for index in 0..<10 {
            try Data("burst\n".utf8).write(
                to: directory.appendingPathComponent("burst-\(index).jsonl")
            )
        }
        await fulfillment(of: [trailing], timeout: 2)
        await fulfillment(of: [unexpectedThird], timeout: 0.3)

        await watcher.stop()
        consumer.cancel()
    }

    func testDirectoryWatcherRejectsCallbacksFromReplacedGeneration() async throws {
        let directory = try temporaryDirectory()
        let watcher = SessionDirectoryWatcher(
            coalescingDelay: .milliseconds(50)
        )
        let firstStream = await watcher.changes(for: [directory])
        let firstConsumer = Task {
            for await _ in firstStream {}
        }
        let secondStream = await watcher.changes(for: [directory])
        let secondConsumer = Task {
            for await _ in secondStream {}
        }

        let acceptedOld = await watcher.recordChange(generation: 1)
        let acceptedCurrent = await watcher.recordChange(generation: 2)

        XCTAssertFalse(acceptedOld)
        XCTAssertTrue(acceptedCurrent)
        await watcher.stop()
        firstConsumer.cancel()
        secondConsumer.cancel()
    }

    func testDirectoryWatcherRejectsQueuedWorkAfterConsumerCancellation() async throws {
        let directory = try temporaryDirectory()
        let watcher = SessionDirectoryWatcher(
            coalescingDelay: .milliseconds(50)
        )
        let stream = await watcher.changes(for: [directory])
        let consumer = Task {
            for await _ in stream {}
        }
        consumer.cancel()
        for _ in 0..<200 { await Task.yield() }

        let acceptedCallback = await watcher.recordChange(generation: 1)
        let acceptedFinish = await watcher.finishCoalescingWindow(
            generation: 1
        )

        XCTAssertFalse(acceptedCallback)
        XCTAssertFalse(acceptedFinish)
    }

    private func makeService(
        accountClient: any AccountUsageReading,
        indexer: any SessionUsageIndexing,
        store: any UsageStore,
        codexHome: URL
    ) -> UsageService {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return UsageService(
            accountClient: accountClient,
            indexer: indexer,
            store: store,
            environment: [:],
            homeDirectory: codexHome.deletingLastPathComponent(),
            calendar: calendar
        )
    }

    private func rateLimitUpdate(
        usedPercent: Double
    ) throws -> RateLimitsUpdatedParams {
        try JSONDecoder().decode(
            RateLimitsUpdatedParams.self,
            from: Data(
                """
                {"rateLimits":{"primary":{"usedPercent":\(usedPercent)}}}
                """.utf8
            )
        )
    }

    private func clearingPrimaryUpdate() throws -> RateLimitsUpdatedParams {
        try JSONDecoder().decode(
            RateLimitsUpdatedParams.self,
            from: Data(#"{"rateLimits":{"primary":null}}"#.utf8)
        )
    }

    private func rpcFailure() -> RPCErrorPayload {
        RPCErrorPayload(
            code: -32600,
            message: "authentication required",
            data: nil
        )
    }

    private func waitUntilOperationQueueDepth(
        _ expectedDepth: Int,
        service: UsageService
    ) async {
        while await service.operationQueueDepth() < expectedDepth {
            await Task.yield()
        }
    }
}
