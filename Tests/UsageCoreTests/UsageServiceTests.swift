import Foundation
import XCTest
@testable import UsageCore

actor FakeAccountUsageClient: AccountUsageReading {
    let initialized: InitializeResult
    private var limits: RateLimitsResponse
    private var usage: AccountUsageResponse
    private var failure: RPCErrorPayload?
    private var queuedNotifications: [AppServerNotification] = []

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
        initialized
    }

    func readRateLimits() async throws -> RateLimitsResponse {
        if let failure { throw failure }
        return limits
    }

    func readAccountUsage() async throws -> AccountUsageResponse {
        if let failure { throw failure }
        return usage
    }

    func nextNotification() async -> AppServerNotification? {
        guard !queuedNotifications.isEmpty else { return nil }
        return queuedNotifications.removeFirst()
    }

    func setFailure(_ value: RPCErrorPayload?) {
        failure = value
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
            usage: AccountUsageResponse(
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
}

final class UsageServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_148_800)

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
        XCTAssertEqual(cycles.count, 1)
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
            now: now.addingTimeInterval(601)
        )
        let officialDays = try await fixture.store.officialDays()

        XCTAssertEqual(snapshot.quota?.remainingPercent, 75)
        XCTAssertEqual(snapshot.status, .stale)
        XCTAssertEqual(officialDays.count, 1)
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
            now: now.addingTimeInterval(60)
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

        XCTAssertFalse(retainedEvents.contains { $0.signature == oldEvent.signature })
        XCTAssertTrue(retainedEvents.contains { $0.signature == keptEvent.signature })
        XCTAssertEqual(
            retainedDays.map(\.day.iso8601),
            ["2026-07-06", "2026-08-30"]
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
}
