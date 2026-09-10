import XCTest
@testable import UsageCore

final class ResetCycleTests: XCTestCase {
    func testResetCardBoundaryCorrectionsDoNotCreateEmptyCycles() async throws {
        let start = try date("2026-09-09T16:28:52+08:00")
        let previousStart = try date("2026-09-08T10:31:40+08:00")
        for drift: TimeInterval in [64, 300, 1_800] {
            let settled = start.addingTimeInterval(drift)
            let pending = stride(from: 300.0, to: drift, by: 300).map {
                quota(start: start, used: 0, fetchedAt: start.addingTimeInterval($0))
            }
            let records = [
                quota(start: previousStart, used: 98, fetchedAt: start.addingTimeInterval(-300)),
                quota(start: start, used: 0, fetchedAt: start.addingTimeInterval(-2))
            ] + pending + [
                quota(start: settled, used: 0, fetchedAt: settled.addingTimeInterval(20)),
                quota(start: settled, used: 1, fetchedAt: settled.addingTimeInterval(300))
            ]
            let cycles = try await refresh(
                records: records,
                events: [
                    storedEvent(at: start.addingTimeInterval(-10), input: 100, output: 20),
                    storedEvent(at: start.addingTimeInterval(10), input: 7, output: 5),
                    storedEvent(at: settled.addingTimeInterval(10), input: 11, output: 3)
                ]
            )
            let observed = cycles.filter { !$0.boundaryIsEstimated }
            XCTAssertEqual(observed.map(\.startsAt), [previousStart, start], "drift: \(drift)")
            XCTAssertEqual(observed.map(\.displayedTokens), [120, 26])
            XCTAssertEqual(observed.last?.endsAt, settled.addingTimeInterval(604_800))
        }
    }

    func testStartupRepairsOfficialAndCardResetFragmentsFromRecordedHistory() async throws {
        for (initial, corrected) in [
            ("2026-09-08T10:31:40+08:00", "2026-09-08T10:32:16+08:00"),
            ("2026-09-09T16:28:52+08:00", "2026-09-09T16:29:56+08:00")
        ] {
            let start = try date(initial)
            let settled = try date(corrected)
            let previousStart = start.addingTimeInterval(-86_400)
            let end = settled.addingTimeInterval(604_800)
            let records = [
                quota(start: previousStart, used: 98, fetchedAt: start.addingTimeInterval(-300)),
                quota(start: start, used: 0, fetchedAt: start.addingTimeInterval(-2)),
                quota(start: settled, used: 1, fetchedAt: settled.addingTimeInterval(300))
            ]
            let cycles = try await refresh(
                records: records,
                existing: [
                    cycle(previousStart, start), cycle(start, settled), cycle(settled, end)
                ],
                events: [
                    storedEvent(at: start.addingTimeInterval(-10), input: 100, output: 20),
                    storedEvent(at: start.addingTimeInterval(10), input: 7, output: 5),
                    storedEvent(at: settled.addingTimeInterval(10), input: 11, output: 3)
                ],
                restoreHistory: true
            )
            let observed = cycles.filter { !$0.boundaryIsEstimated }
            XCTAssertEqual(observed.map(\.startsAt), [previousStart, start])
            XCTAssertEqual(observed.map(\.endsAt), [start, end])
            XCTAssertEqual(observed.map(\.displayedTokens), [120, 26])
            XCTAssertEqual(cycles.count, 9)
        }
    }

    func testTwoRealResetsOnSameDayRemainSeparateEvenWithinOneMinute() async throws {
        let start = try date("2026-09-09T16:28:52+08:00")
        let next = start.addingTimeInterval(30)
        let records = [
            quota(start: start, used: 0, fetchedAt: start),
            quota(start: start, used: 5, fetchedAt: start.addingTimeInterval(15)),
            quota(start: next, used: 0, fetchedAt: next),
            quota(start: next, used: 1, fetchedAt: next.addingTimeInterval(30))
        ]
        let cycles = try await refresh(
            records: records,
            events: [
                storedEvent(at: start.addingTimeInterval(10), input: 7, output: 5),
                storedEvent(at: next.addingTimeInterval(10), input: 11, output: 3)
            ]
        )
        let observed = cycles.filter { !$0.boundaryIsEstimated }
        XCTAssertEqual(observed.map(\.startsAt), [start, next])
        XCTAssertEqual(observed.map(\.displayedTokens), [12, 14])
    }

    func testStartupRepairsFragmentsOlderThanTheDailyTrendRange() async throws {
        let start = try date("2026-09-09T16:28:52+08:00")
        let settled = start.addingTimeInterval(64)
        let previous = start.addingTimeInterval(-86_400)
        let nextWeek = settled.addingTimeInterval(604_800)
        let records = [
            quota(start: previous, used: 98, fetchedAt: start.addingTimeInterval(-300)),
            quota(start: start, used: 0, fetchedAt: start.addingTimeInterval(-2)),
            quota(start: settled, used: 1, fetchedAt: settled.addingTimeInterval(300)),
            quota(start: nextWeek, used: 15, fetchedAt: nextWeek.addingTimeInterval(3 * 86_400))
        ]
        let cycles = try await refresh(
            records: records,
            existing: [
                cycle(previous, start), cycle(start, settled),
                cycle(settled, nextWeek), cycle(nextWeek, nextWeek.addingTimeInterval(604_800))
            ],
            events: [storedEvent(at: start.addingTimeInterval(10), input: 7, output: 5)],
            restoreHistory: true
        )
        let observed = cycles.filter { !$0.boundaryIsEstimated }
        XCTAssertEqual(observed.map(\.startsAt), [previous, start, nextWeek])
        XCTAssertEqual(observed.map(\.displayedTokens), [0, 12, 0])
    }

    func testMissingHistoryDoesNotMergeUnverifiedStarts() throws {
        let start = try date("2026-09-09T16:28:52+08:00")
        let next = start.addingTimeInterval(64)
        let current = quota(start: next, used: 1, fetchedAt: next.addingTimeInterval(30))
        let cycles = CycleTracker().update(
            existing: [cycle(start, next), cycle(next, current.resetsAt)],
            quota: current, events: []
        )
        XCTAssertEqual(cycles.filter { !$0.boundaryIsEstimated }.map(\.startsAt), [start, next])
    }

    func testRealResetCanClearUsageBeforeUpdatingTheBoundary() async throws {
        let start = try date("2026-09-09T16:28:52+08:00")
        let next = start.addingTimeInterval(30)
        let cycles = try await refresh(
            records: [
                quota(start: start, used: 5, fetchedAt: start.addingTimeInterval(15)),
                quota(start: start, used: 0, fetchedAt: start.addingTimeInterval(29)),
                quota(start: next, used: 0, fetchedAt: next),
                quota(start: next, used: 1, fetchedAt: next.addingTimeInterval(30))
            ],
            events: [
                storedEvent(at: start.addingTimeInterval(10), input: 7, output: 5),
                storedEvent(at: next.addingTimeInterval(10), input: 11, output: 3)
            ]
        )
        let observed = cycles.filter { !$0.boundaryIsEstimated }
        XCTAssertEqual(observed.map(\.startsAt), [start, next])
        XCTAssertEqual(observed.map(\.displayedTokens), [12, 14])
    }

    func testUnobservedGapDoesNotMergeAPossibleRealReset() async throws {
        let start = try date("2026-09-09T16:28:52+08:00")
        let next = start.addingTimeInterval(86_400)
        let cycles = try await refresh(
            records: [
                quota(start: start, used: 0, fetchedAt: start),
                quota(start: next, used: 0, fetchedAt: next.addingTimeInterval(30))
            ],
            events: [
                storedEvent(at: start.addingTimeInterval(10), input: 7, output: 5),
                storedEvent(at: next.addingTimeInterval(10), input: 11, output: 3)
            ]
        )
        let observed = cycles.filter { !$0.boundaryIsEstimated }
        XCTAssertEqual(observed.map(\.startsAt), [start, next])
        XCTAssertEqual(observed.map(\.displayedTokens), [12, 14])
    }

    private func refresh(
        records: [QuotaSnapshot], existing: [QuotaCycle] = [],
        events: [StoredUsageEvent], restoreHistory: Bool = false
    ) async throws -> [QuotaCycle] {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteUsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try await store.migrate()
        try await store.replace(cycles: existing)
        _ = try await store.insert(events: events)
        if restoreHistory {
            for record in records.dropLast() { try await store.save(quota: record) }
        }
        let client = FakeAccountUsageClient(
            initialized: InitializeResult(codexHome: root.path, platformFamily: nil, platformOs: nil, userAgent: nil),
            limits: limits(records[0]),
            usage: AccountUsageResponse(
                summary: AccountUsageSummary(lifetimeTokens: nil, peakDailyTokens: nil, longestRunningTurnSec: nil, currentStreakDays: nil, longestStreakDays: nil),
                dailyUsageBuckets: []
            )
        )
        let service = UsageService(
            accountClient: client, indexer: CountingSessionIndexer(), store: store,
            environment: [:], homeDirectory: root, calendar: Calendar(identifier: .gregorian)
        )
        for record in restoreHistory ? Array(records.suffix(1)) : records {
            await client.setLimits(limits(record))
            _ = try await service.refresh(reason: .manual, now: record.fetchedAt)
        }
        let cycles = try await store.cycles()
        if let last = records.last {
            _ = try await service.refresh(reason: .manual, now: last.fetchedAt.addingTimeInterval(10))
            let again = try await store.cycles()
            XCTAssertEqual(cycles, again, "再次刷新不能重新拆出碎片")
        }
        try await store.close()
        return cycles
    }

    private func limits(_ quota: QuotaSnapshot) -> RateLimitsResponse {
        RateLimitsResponse(
            rateLimits: RateLimitBucket(
                limitId: "codex", limitName: nil,
                primary: RateLimitWindow(
                    usedPercent: quota.usedPercent, windowDurationMins: 10_080,
                    resetsAt: Int64(quota.resetsAt.timeIntervalSince1970)
                ), secondary: nil
            ), rateLimitsByLimitId: nil
        )
    }

    private func quota(start: Date, used: Double, fetchedAt: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            limitID: "codex", usedPercent: used, windowDurationMinutes: 10_080,
            startsAt: start, resetsAt: start.addingTimeInterval(604_800), fetchedAt: fetchedAt
        )
    }

    private func cycle(_ start: Date, _ end: Date) -> QuotaCycle {
        QuotaCycle(startsAt: start, endsAt: end, usage: .zero, displayedTokens: 0, status: .localLive, boundaryIsEstimated: false)
    }
}
