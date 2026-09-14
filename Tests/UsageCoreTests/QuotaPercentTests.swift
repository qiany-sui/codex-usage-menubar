import XCTest
@testable import UsageCore

final class QuotaPercentTests: XCTestCase {
    func testDailyConsumptionUsesOfficialChangeRegardlessOfTokens() throws {
        let history = try [
            quota(38, at: "2026-09-08T23:58:00+08:00"),
            quota(45, at: "2026-09-09T12:00:00+08:00")
        ]
        for tokens: Int64 in [0, 500, 9_000_000] {
            let snapshot = try makeSnapshot(history, tokens: tokens)
            XCTAssertEqual(try percent(snapshot.today), 7)
            XCTAssertEqual(snapshot.today.displayedTokens, tokens)
        }
    }

    func testHistoricalConsumptionDoesNotChangeWhenCurrentQuotaIncreases() throws {
        let history = try [
            quota(20, at: "2026-09-07T23:58:00+08:00"),
            quota(30, at: "2026-09-08T23:58:00+08:00")
        ]
        for used in [35.0, 80.0] {
            let snapshot = try makeSnapshot(history + [
                quota(used, at: "2026-09-09T12:00:00+08:00")
            ])
            XCTAssertEqual(try percent(snapshot.recentDays[5]), 10)
        }
    }

    func testEqualReadingsAcrossAnOvernightGapEstablishTheMidnightValue() throws {
        let snapshot = try makeSnapshot([
            quota(38, at: "2026-09-08T19:00:00+08:00"),
            quota(38, at: "2026-09-09T09:00:00+08:00"),
            quota(45, at: "2026-09-09T12:00:00+08:00")
        ])
        XCTAssertEqual(try percent(snapshot.today), 7)
    }

    func testUnchangedReadingsAcrossAnEntireDayProduceZero() throws {
        let snapshot = try makeSnapshot([
            quota(38, at: "2026-09-07T19:00:00+08:00"),
            quota(38, at: "2026-09-09T09:00:00+08:00"),
            quota(45, at: "2026-09-09T12:00:00+08:00")
        ])
        XCTAssertEqual(try percent(snapshot.recentDays[5]), 0)
    }

    func testMissingOrAmbiguousMidnightReadingIsUnknownEvenWithZeroTokens() throws {
        let current = try quota(45, at: "2026-09-09T12:00:00+08:00")
        let histories: [[QuotaSnapshot]] = try [
            [], [current],
            [quota(38, at: "2026-09-08T19:00:00+08:00"), current],
            [quota(38, at: "2026-09-09T00:01:00+08:00"), current]
        ]
        for history in histories {
            XCTAssertNil(try percent(makeSnapshot(history).today))
        }
    }

    func testMissingDayEndAndStaleCurrentReadingsAreUnknown() throws {
        let snapshot = try makeSnapshot([
            quota(20, at: "2026-09-07T23:58:00+08:00"),
            quota(30, at: "2026-09-08T19:00:00+08:00"),
            quota(40, at: "2026-09-09T09:00:00+08:00"),
            quota(45, at: "2026-09-09T11:49:59+08:00")
        ])
        XCTAssertNil(try percent(snapshot.recentDays[5]))
        XCTAssertNil(try percent(snapshot.today))
    }

    func testResetAddsObservedConsumptionOnBothSidesWithoutFillingToOneHundred() throws {
        let oldStart = "2026-09-02T06:00:00+08:00"
        let newStart = "2026-09-09T06:00:00+08:00"
        let snapshot = try makeSnapshot([
            quota(30, at: "2026-09-08T23:58:00+08:00", start: oldStart),
            quota(45, at: "2026-09-09T05:59:00+08:00", start: oldStart),
            quota(5, at: "2026-09-09T06:04:00+08:00", start: newStart),
            quota(20, at: "2026-09-09T12:00:00+08:00", start: newStart)
        ])
        XCTAssertEqual(try percent(snapshot.today), 35)
    }

    func testResetWithMissingOldCycleClosingReadingIsUnknown() throws {
        let snapshot = try makeSnapshot([
            quota(30, at: "2026-09-08T23:58:00+08:00", start: "2026-09-02T06:00:00+08:00"),
            quota(20, at: "2026-09-09T12:00:00+08:00", start: "2026-09-09T06:00:00+08:00")
        ])
        XCTAssertNil(try percent(snapshot.today))
    }

    func testEarlyResetJustBeforeMidnightMakesUnobservedBoundaryUnknown() throws {
        let snapshot = try makeSnapshot([
            quota(30, at: "2026-09-07T23:58:00+08:00"),
            quota(45, at: "2026-09-08T23:59:00+08:00"),
            quota(20, at: "2026-09-09T12:00:00+08:00", start: "2026-09-08T23:59:30+08:00")
        ])
        XCTAssertNil(try percent(snapshot.recentDays[5]))
        XCTAssertNil(try percent(snapshot.today))
    }

    func testMidnightBoundaryDoesNotRefreshTheAgeOfAnOldPreResetReading() throws {
        let snapshot = try makeSnapshot([
            quota(30, at: "2026-09-08T23:50:00+08:00", start: "2026-09-02T00:10:00+08:00"),
            quota(20, at: "2026-09-09T12:00:00+08:00", start: "2026-09-09T00:10:00+08:00")
        ])
        XCTAssertNil(try percent(snapshot.today))
    }

    func testEarlyResetCanProduceMoreThanOneFullQuotaOfDailyConsumption() throws {
        let oldStart = "2026-09-03T00:00:00+08:00"
        let newStart = "2026-09-09T06:00:00+08:00"
        let snapshot = try makeSnapshot([
            quota(10, at: "2026-09-08T23:58:00+08:00", start: oldStart),
            quota(95, at: "2026-09-09T05:59:00+08:00", start: oldStart),
            quota(40, at: "2026-09-09T12:00:00+08:00", start: newStart)
        ])
        XCTAssertEqual(try percent(snapshot.today), 125)
    }

    func testCycleStartingAtMidnightHasAKnownZeroBaseline() throws {
        let snapshot = try makeSnapshot([
            quota(20, at: "2026-09-09T12:00:00+08:00", start: "2026-09-09T00:00:00+08:00")
        ])
        XCTAssertEqual(try percent(snapshot.today), 20)
        XCTAssertNil(try percent(snapshot.recentDays[5]))
    }

    func testCounterCorrectionWithinSameCycleIsUnknown() throws {
        let snapshot = try makeSnapshot([
            quota(38, at: "2026-09-08T23:58:00+08:00"),
            quota(20, at: "2026-09-09T09:00:00+08:00"),
            quota(45, at: "2026-09-09T12:00:00+08:00")
        ])
        XCTAssertNil(try percent(snapshot.today))
    }

    func testOneSecondResetTimestampJitterDoesNotCreateANewCycle() throws {
        let snapshot = try makeSnapshot([
            quota(38, at: "2026-09-08T23:58:00+08:00"),
            quota(45, at: "2026-09-09T12:00:00+08:00", start: "2026-09-03T00:00:01+08:00")
        ])
        XCTAssertEqual(try percent(snapshot.today), 7)
    }

    func testOtherBucketsAndFutureReadingsDoNotAffectConsumption() throws {
        let snapshot = try makeSnapshot([
            quota(38, at: "2026-09-08T23:58:00+08:00"),
            quota(99, at: "2026-09-09T00:00:00+08:00", limitID: "other"),
            quota(45, at: "2026-09-09T12:00:00+08:00"),
            quota(90, at: "2026-09-09T13:00:00+08:00")
        ])
        XCTAssertEqual(try percent(snapshot.today), 7)
    }

    func testInvalidOfficialReadingsAreUnknown() throws {
        for invalid in [-1.0, .nan, .infinity] {
            let snapshot = try makeSnapshot([
                quota(38, at: "2026-09-08T23:58:00+08:00"),
                quota(invalid, at: "2026-09-09T12:00:00+08:00")
            ])
            XCTAssertNil(try percent(snapshot.today))
        }
    }

    func testOldEstimatedSnapshotDoesNotDecodeAsObservedConsumption() throws {
        let data = try JSONEncoder().encode(makeSnapshot([], tokens: 500).today)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["estimatedQuotaPercent"] = 25
        object.removeValue(forKey: "quotaConsumedPercent")
        let restored = try JSONDecoder().decode(
            UsageDay.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(restored.displayedTokens, 500)
        XCTAssertNil(try percent(restored))
        XCTAssertNil(restored.quotaSegments)
    }

    func testServiceReadsHistoricalObservationsFromExistingDatabase() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteUsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try await store.migrate()
        let history = try [
            quota(10, at: "2026-09-02T18:00:00+08:00", start: "2026-08-28T00:00:00+08:00"),
            quota(10, at: "2026-09-03T09:00:00+08:00", start: "2026-08-28T00:00:00+08:00"),
            quota(25, at: "2026-09-03T23:58:00+08:00", start: "2026-08-28T00:00:00+08:00"),
            quota(20, at: "2026-09-07T23:58:00+08:00", start: "2026-09-04T00:00:00+08:00"),
            quota(30, at: "2026-09-08T23:58:00+08:00", start: "2026-09-04T00:00:00+08:00"),
            quota(99, at: "2026-09-09T00:00:00+08:00", limitID: "other"),
            quota(45, at: "2026-09-09T12:00:00+08:00", start: "2026-09-04T00:00:00+08:00")
        ]
        for item in history { try await store.save(quota: item) }
        let decoder = JSONDecoder()
        let client = FakeAccountUsageClient(
            initialized: try decoder.decode(InitializeResult.self, from: Data("{}".utf8)),
            limits: try decoder.decode(RateLimitsResponse.self, from: Data(#"{"rateLimits":{}}"#.utf8)),
            usage: try decoder.decode(AccountUsageResponse.self, from: Data(#"{"summary":{}}"#.utf8))
        )
        let service = UsageService(
            accountClient: client, indexer: CountingSessionIndexer(), store: store,
            environment: [:], homeDirectory: root, calendar: calendar()
        )
        let snapshot = try await service.currentSnapshot(now: date("2026-09-09T12:00:00+08:00"))
        XCTAssertEqual(try percent(snapshot.recentDays[0]), 15)
        XCTAssertEqual(try percent(snapshot.recentDays[5]), 10)
        XCTAssertEqual(try percent(snapshot.today), 15)
        let later = try await service.currentSnapshot(now: date("2026-09-09T12:10:01+08:00"))
        XCTAssertNil(try percent(later.today))
        XCTAssertEqual(try percent(later.recentDays[5]), 10)
        try await store.close()
    }

    func testResetDisplaySeparatesConsumptionAndCoalescesBoundaryCorrections() throws {
        let snapshot = try makeSnapshot([
            quota(46, at: "2026-09-08T23:58:00+08:00"),
            quota(98, at: "2026-09-09T06:23:48+08:00"),
            quota(0, at: "2026-09-09T06:28:50+08:00", start: "2026-09-09T06:28:52+08:00"),
            quota(0, at: "2026-09-09T06:30:16+08:00", start: "2026-09-09T06:29:56+08:00"),
            quota(6, at: "2026-09-09T12:00:00+08:00", start: "2026-09-09T06:29:56+08:00")
        ], tokens: 380_000_000)
        let parts = try segments(snapshot.today)
        XCTAssertEqual(parts.map(\.consumedPercent), [52, 6])
        XCTAssertEqual(parts.map(\.startsWithReset), [false, true])
        XCTAssertEqual(parts.last?.startsAt, try date("2026-09-09T06:28:52+08:00"))
        XCTAssertEqual(parts.first?.endsAt, parts.last?.startsAt)
        XCTAssertEqual(snapshot.today.displayedTokens, 380_000_000)
    }

    func testResetDisplayKeepsKnownPostResetUsageWhenMidnightIsMissing() throws {
        let snapshot = try makeSnapshot([
            quota(0, at: "2026-09-08T10:31:36+08:00", start: "2026-09-08T10:31:40+08:00"),
            quota(0, at: "2026-09-08T10:36:59+08:00", start: "2026-09-08T10:32:16+08:00"),
            quota(46, at: "2026-09-08T21:34:26+08:00", start: "2026-09-08T10:32:16+08:00"),
            quota(46, at: "2026-09-09T10:07:25+08:00", start: "2026-09-08T10:32:16+08:00"),
            quota(50, at: "2026-09-09T12:00:00+08:00", start: "2026-09-08T10:32:16+08:00")
        ])
        let day = snapshot.recentDays[5]
        let parts = try segments(day)
        XCTAssertEqual(parts.map(\.consumedPercent), [nil, 46])
        XCTAssertEqual(parts.last?.startsAt, try date("2026-09-08T10:31:40+08:00"))
        XCTAssertNil(try percent(day))
    }

    func testResetDisplayKeepsKnownPostResetUsageWhenClosingReadingIsMissing() throws {
        let snapshot = try makeSnapshot([
            quota(30, at: "2026-09-08T23:58:00+08:00"),
            quota(20, at: "2026-09-09T12:00:00+08:00", start: "2026-09-09T06:00:00+08:00")
        ])
        XCTAssertEqual(try segments(snapshot.today).map(\.consumedPercent), [nil, 20])
        XCTAssertNil(try percent(snapshot.today))
    }

    func testResetDisplayPreservesTwoRealResetsWithinOneMinute() throws {
        let snapshot = try makeSnapshot([
            quota(30, at: "2026-09-08T23:58:00+08:00"),
            quota(45, at: "2026-09-09T05:59:00+08:00"),
            quota(5, at: "2026-09-09T06:00:10+08:00", start: "2026-09-09T06:00:00+08:00"),
            quota(0, at: "2026-09-09T06:00:31+08:00", start: "2026-09-09T06:00:30+08:00"),
            quota(2, at: "2026-09-09T12:00:00+08:00", start: "2026-09-09T06:00:30+08:00")
        ])
        let parts = try segments(snapshot.today)
        XCTAssertEqual(parts.map(\.consumedPercent), [15, 5, 2])
        XCTAssertEqual(parts.map(\.startsWithReset), [false, true, true])
    }

    func testMidnightResetHasOnePostResetSegmentWithoutAnEmptyPreResetSegment() throws {
        let snapshot = try makeSnapshot([
            quota(20, at: "2026-09-09T12:00:00+08:00", start: "2026-09-09T00:00:00+08:00")
        ])
        let parts = try segments(snapshot.today)
        XCTAssertEqual(parts.map(\.consumedPercent), [20])
        XCTAssertEqual(parts.map(\.startsWithReset), [true])
    }

    func testIncompleteDayKeepsRecordedConsumptionWithoutClaimingTheDayIsComplete() throws {
        let snapshot = try makeSnapshot([
            quota(58, at: "2026-09-07T23:12:42+08:00"),
            quota(58, at: "2026-09-08T10:05:52+08:00"),
            quota(76, at: "2026-09-08T23:09:56+08:00"),
            quota(0, at: "2026-09-09T11:00:00+08:00", start: "2026-09-09T11:00:00+08:00")
        ])
        let day = snapshot.recentDays[5]
        XCTAssertNil(day.quotaConsumedPercent)
        XCTAssertEqual(try recordedPercent(day), 18)
    }

    func testPartialConsumptionUsesOnlyRecordedChangesWithinTheDay() throws {
        let snapshot = try makeSnapshot([
            quota(30, at: "2026-09-08T19:00:00+08:00"),
            quota(58, at: "2026-09-09T10:00:00+08:00"),
            quota(76, at: "2026-09-09T11:00:00+08:00")
        ])
        XCTAssertNil(snapshot.today.quotaConsumedPercent)
        XCTAssertEqual(try recordedPercent(snapshot.today), 18)
    }

    func testSingleReadingAndCounterCorrectionDoNotBecomePartialConsumption() throws {
        let histories = try [
            [quota(76, at: "2026-09-09T11:00:00+08:00")],
            [quota(76, at: "2026-09-09T10:00:00+08:00"),
             quota(0, at: "2026-09-09T11:00:00+08:00")]
        ]
        for history in histories {
            XCTAssertNil(try recordedPercent(makeSnapshot(history).today))
        }
    }

    func testPartialResetSegmentKeepsObservedConsumptionInItsOwnCycle() throws {
        let snapshot = try makeSnapshot([
            quota(30, at: "2026-09-08T23:58:00+08:00"),
            quota(45, at: "2026-09-09T03:00:00+08:00"),
            quota(20, at: "2026-09-09T12:00:00+08:00", start: "2026-09-09T06:00:00+08:00")
        ])
        struct Output: Decodable {
            struct Segment: Decodable { let recordedConsumedPercent: Double? }
            let quotaSegments: [Segment]
        }
        let output = try JSONDecoder().decode(Output.self, from: JSONEncoder().encode(snapshot.today))
        XCTAssertEqual(output.quotaSegments.map(\.recordedConsumedPercent), [15, nil])
        XCTAssertEqual(snapshot.today.quotaSegments?.map(\.consumedPercent), [nil, 20])
        XCTAssertNil(try recordedPercent(snapshot.today))
    }

    private func recordedPercent(_ day: UsageDay) throws -> Double? {
        struct Output: Decodable { let recordedQuotaConsumedPercent: Double? }
        return try JSONDecoder().decode(Output.self, from: JSONEncoder().encode(day)).recordedQuotaConsumedPercent
    }

    private struct QuotaSegmentOutput: Decodable {
        let startsAt: Date
        let endsAt: Date
        let consumedPercent: Double?
        let startsWithReset: Bool
    }

    private func segments(_ day: UsageDay) throws -> [QuotaSegmentOutput] {
        struct DayOutput: Decodable { let quotaSegments: [QuotaSegmentOutput]? }
        let output = try JSONDecoder().decode(DayOutput.self, from: JSONEncoder().encode(day))
        return try XCTUnwrap(output.quotaSegments)
    }

    // 验证公开快照输出，旧估算值不能冒充新的官方增量。
    private func percent(_ day: UsageDay) throws -> Double? {
        let data = try JSONEncoder().encode(day)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object["quotaConsumedPercent"] as? Double
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func quota(
        _ used: Double, at timestamp: String,
        start: String = "2026-09-03T00:00:00+08:00", limitID: String = "codex"
    ) throws -> QuotaSnapshot {
        let startsAt = try date(start)
        return QuotaSnapshot(
            limitID: limitID, usedPercent: used, windowDurationMinutes: 10_080,
            startsAt: startsAt, resetsAt: startsAt.addingTimeInterval(7 * 24 * 60 * 60),
            fetchedAt: try date(timestamp)
        )
    }

    private func makeSnapshot(_ history: [QuotaSnapshot], tokens: Int64 = 0) throws -> UsageSnapshot {
        let now = try date("2026-09-09T12:00:00+08:00")
        let events = [storedEvent(at: now, input: tokens, output: 0)]
        return UsageReconciler().snapshot(
            now: now, calendar: calendar(),
            quota: history.filter { $0.fetchedAt <= now && $0.limitID == "codex" }.last,
            events: events, officialDays: [], cycles: [], lastUpdatedAt: now,
            quotaHistory: history
        )
    }
}
