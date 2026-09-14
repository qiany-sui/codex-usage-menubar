import XCTest
@testable import UsageCore

final class CycleQuotaPercentTests: XCTestCase {
    func testCurrentCycleUsesOfficialCumulativePercentRegardlessOfTokens() throws {
        for tokens: Int64 in [0, 500, 900_000_000] {
            let snapshot = try snapshot(
                history: [quota(32, at: "2026-09-10T12:00:00+08:00", start: "2026-09-09T16:29:56+08:00")],
                cycles: [cycle("2026-09-09T16:29:56+08:00", "2026-09-16T16:29:56+08:00", tokens: tokens)]
            )
            XCTAssertEqual(try percent(XCTUnwrap(snapshot.currentCycle)), 32)
        }
    }

    func testHistoricalCycleKeepsItsClosingPercentAfterEarlyReset() throws {
        for currentUsed in [8.0, 32.0] {
            let snapshot = try snapshot(
                history: [
                    quota(98, at: "2026-09-09T16:23:48+08:00", start: "2026-09-08T10:31:40+08:00"),
                    quota(0, at: "2026-09-09T16:28:50+08:00", start: "2026-09-09T16:28:52+08:00"),
                    quota(0, at: "2026-09-09T16:30:16+08:00", start: "2026-09-09T16:29:56+08:00"),
                    quota(currentUsed, at: "2026-09-10T12:00:00+08:00", start: "2026-09-09T16:29:56+08:00")
                ],
                cycles: [
                    cycle("2026-09-08T10:31:40+08:00", "2026-09-09T16:28:52+08:00"),
                    cycle("2026-09-09T16:28:52+08:00", "2026-09-16T16:29:56+08:00")
                ]
            )
            XCTAssertEqual(try percent(XCTUnwrap(snapshot.cycleHistory.first)), 98)
            XCTAssertEqual(try percent(XCTUnwrap(snapshot.currentCycle)), currentUsed)
        }
    }

    func testCycleWithMissingClosingRecordDoesNotUseAnOldPartialReading() throws {
        let snapshot = try snapshot(
            history: [
                quota(70, at: "2026-09-09T15:00:00+08:00", start: "2026-09-08T10:31:40+08:00"),
                quota(32, at: "2026-09-10T12:00:00+08:00", start: "2026-09-09T16:28:52+08:00")
            ],
            cycles: [cycle("2026-09-08T10:31:40+08:00", "2026-09-09T16:28:52+08:00")]
        )
        let historical = try XCTUnwrap(snapshot.cycleHistory.first)
        XCTAssertNil(try percent(historical))
        let recorded = try XCTUnwrap(lastRecordedQuota(historical))
        XCTAssertEqual(recorded.usedPercent, 70)
        XCTAssertEqual(recorded.fetchedAt, try date("2026-09-09T15:00:00+08:00"))
    }

    func testEstimatedCycleDoesNotAcquireAnOfficialPercentage() throws {
        let snapshot = try snapshot(
            history: [quota(100, at: "2026-09-09T16:27:00+08:00", start: "2026-09-02T16:28:52+08:00")],
            cycles: [cycle("2026-09-02T16:28:52+08:00", "2026-09-09T16:28:52+08:00", estimated: true)]
        )
        XCTAssertNil(try percent(XCTUnwrap(snapshot.cycleHistory.first)))
        XCTAssertNil(try lastRecordedQuota(XCTUnwrap(snapshot.cycleHistory.first)))
    }

    func testAsynchronousResetClearingDoesNotTurnTheOldCycleIntoZeroUsage() throws {
        let snapshot = try snapshot(
            history: [
                quota(98, at: "2026-09-09T16:23:48+08:00", start: "2026-09-08T10:31:40+08:00"),
                quota(0, at: "2026-09-09T16:28:49+08:00", start: "2026-09-08T10:31:40+08:00"),
                quota(0, at: "2026-09-09T16:28:53+08:00", start: "2026-09-09T16:28:52+08:00"),
                quota(32, at: "2026-09-10T12:00:00+08:00", start: "2026-09-09T16:28:52+08:00")
            ],
            cycles: [cycle("2026-09-08T10:31:40+08:00", "2026-09-09T16:28:52+08:00")]
        )
        XCTAssertNil(try percent(XCTUnwrap(snapshot.cycleHistory.first)))
        XCTAssertNil(try lastRecordedQuota(XCTUnwrap(snapshot.cycleHistory.first)))
    }

    func testNearbyRealCyclesDoNotBorrowEachOthersPercentages() throws {
        let snapshot = try snapshot(
            history: [
                quota(5, at: "2026-09-09T06:00:10+08:00", start: "2026-09-09T06:00:00+08:00"),
                quota(0, at: "2026-09-09T06:00:31+08:00", start: "2026-09-09T06:00:30+08:00"),
                quota(32, at: "2026-09-10T12:00:00+08:00", start: "2026-09-09T06:00:30+08:00")
            ],
            cycles: [
                cycle("2026-09-09T06:00:00+08:00", "2026-09-09T06:00:30+08:00"),
                cycle("2026-09-09T06:00:30+08:00", "2026-09-16T06:00:30+08:00")
            ]
        )
        XCTAssertEqual(try percent(XCTUnwrap(snapshot.cycleHistory.first)), 5)
        XCTAssertEqual(try percent(XCTUnwrap(snapshot.currentCycle)), 32)
    }

    func testRetainedCycleStartCanMatchASmallOfficialBoundaryCorrection() throws {
        let snapshot = try snapshot(
            history: [quota(32, at: "2026-09-10T12:00:00+08:00", start: "2026-09-09T16:28:53+08:00")],
            cycles: [cycle("2026-09-09T16:28:52+08:00", "2026-09-16T16:28:53+08:00")]
        )
        XCTAssertEqual(try percent(XCTUnwrap(snapshot.currentCycle)), 32)
    }

    func testInvalidCurrentReadingDoesNotProduceAPercentage() throws {
        for invalid in [-1.0, .nan, .infinity] {
            let snapshot = try snapshot(
                history: [quota(invalid, at: "2026-09-10T12:00:00+08:00", start: "2026-09-09T16:28:52+08:00")],
                cycles: [cycle("2026-09-09T16:28:52+08:00", "2026-09-16T16:28:52+08:00")]
            )
            XCTAssertNil(try percent(XCTUnwrap(snapshot.currentCycle)))
        }
    }

    func testUnrecordedShortCycleDoesNotBorrowThePreviousCyclesReading() throws {
        let snapshot = try snapshot(
            history: [
                quota(5, at: "2026-09-09T06:00:10+08:00", start: "2026-09-09T06:00:00+08:00"),
                quota(32, at: "2026-09-10T12:00:00+08:00", start: "2026-09-09T06:01:30+08:00")
            ],
            cycles: [
                cycle("2026-09-09T06:00:00+08:00", "2026-09-09T06:00:30+08:00"),
                cycle("2026-09-09T06:00:30+08:00", "2026-09-09T06:01:30+08:00"),
                cycle("2026-09-09T06:01:30+08:00", "2026-09-16T06:01:30+08:00")
            ]
        )
        XCTAssertEqual(try percent(XCTUnwrap(snapshot.cycleHistory.last)), 5)
        XCTAssertNil(try percent(XCTUnwrap(snapshot.cycleHistory.first)))
        XCTAssertNil(try lastRecordedQuota(XCTUnwrap(snapshot.cycleHistory.first)))
    }

    private func lastRecordedQuota(_ cycle: QuotaCycle) throws -> QuotaSnapshot? {
        struct Output: Decodable { let lastRecordedQuota: QuotaSnapshot? }
        return try JSONDecoder().decode(Output.self, from: JSONEncoder().encode(cycle)).lastRecordedQuota
    }

    private func percent(_ cycle: QuotaCycle) throws -> Double? {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cycle)) as? [String: Any])
        return object["quotaUsedPercent"] as? Double
    }

    private func quota(_ used: Double, at timestamp: String, start: String) throws -> QuotaSnapshot {
        let startsAt = try date(start)
        return QuotaSnapshot(
            limitID: "codex", usedPercent: used, windowDurationMinutes: 10_080,
            startsAt: startsAt, resetsAt: startsAt.addingTimeInterval(7 * 24 * 3600), fetchedAt: try date(timestamp)
        )
    }

    private func cycle(_ start: String, _ end: String, tokens: Int64 = 0, estimated: Bool = false) throws -> QuotaCycle {
        QuotaCycle(
            startsAt: try date(start), endsAt: try date(end),
            usage: TokenBreakdown(inputTokens: tokens, cachedInputTokens: 0, outputTokens: 0),
            displayedTokens: tokens, status: .localLive, boundaryIsEstimated: estimated
        )
    }

    private func snapshot(history: [QuotaSnapshot], cycles: [QuotaCycle]) throws -> UsageSnapshot {
        let now = try date("2026-09-10T12:00:00+08:00")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return UsageReconciler().snapshot(
            now: now, calendar: calendar, quota: history.last, events: [], officialDays: [],
            cycles: cycles, lastUpdatedAt: now, quotaHistory: history
        )
    }
}
