import XCTest
@testable import UsageCore

final class CycleDailyUsageTests: XCTestCase {
    func testOldCycleDailyUsageUsesClippedLocalBoundaryDaysAndOfficialFullDays() throws {
        let start = date("2026-08-01T12:00:00+08:00")
        let end = date("2026-08-03T12:00:00+08:00")
        let now = date("2026-08-31T12:00:00+08:00")
        let events = [
            event("2026-08-01T11:59:59+08:00", tokens: 999),
            event("2026-08-01T12:00:00+08:00", tokens: 10),
            event("2026-08-02T12:00:00+08:00", tokens: 20),
            event("2026-08-03T11:59:59+08:00", tokens: 30),
            event("2026-08-03T12:00:00+08:00", tokens: 999)
        ]
        let snapshot = snapshot(
            now: now, cycles: [cycle(start, end, events: events)], events: events,
            official: [official("2026-08-01", 1_000, now), official("2026-08-02", 200, now),
                       official("2026-08-03", 1_000, now)]
        )
        let result = try XCTUnwrap(snapshot.cycleHistory.first)
        let days = try XCTUnwrap(result.dailyUsage)

        XCTAssertEqual(days.map(\.day.iso8601), ["2026-08-01", "2026-08-02", "2026-08-03"])
        XCTAssertEqual(days.map(\.displayedTokens), [10, 200, 30])
        XCTAssertEqual(days.map(\.status), [.localLive, .calibrated, .localLive])
        XCTAssertEqual(days.first?.startsAt, start)
        XCTAssertEqual(days.last?.endsAt, end)
        XCTAssertEqual(days.reduce(0) { $0 + $1.displayedTokens }, result.displayedTokens)
        XCTAssertEqual(result.status, .partiallyCalibrated)
        XCTAssertTrue(days.allSatisfy { $0.quotaConsumedPercent == nil && $0.recordedQuotaConsumedPercent == nil })
        XCTAssertFalse(snapshot.recentDays.contains { $0.day == days[0].day })
    }

    func testCurrentCycleStopsAtNowAndKeepsTodayLocal() throws {
        let start = date("2026-09-01T12:00:00+08:00")
        let end = date("2026-09-08T12:00:00+08:00")
        let now = date("2026-09-03T10:00:00+08:00")
        let events = [event("2026-09-01T13:00:00+08:00", tokens: 10),
                      event("2026-09-02T13:00:00+08:00", tokens: 20),
                      event("2026-09-03T09:00:00+08:00", tokens: 30)]
        let result = try XCTUnwrap(snapshot(
            now: now, cycles: [cycle(start, end, events: events)], events: events,
            official: [official("2026-09-02", 200, now), official("2026-09-03", 999, now)]
        ).currentCycle)
        let days = try XCTUnwrap(result.dailyUsage)

        XCTAssertEqual(days.map(\.day.iso8601), ["2026-09-01", "2026-09-02", "2026-09-03"])
        XCTAssertEqual(days.map(\.displayedTokens), [10, 200, 30])
        XCTAssertEqual(days.last?.endsAt, now)
        XCTAssertEqual(result.status, .partiallyCalibrated)
        XCTAssertEqual(days.reduce(0) { $0 + $1.displayedTokens }, result.displayedTokens)
    }

    func testSameDayCyclesKeepTheirOwnTokensAndQuota() throws {
        let firstStart = date("2026-09-01T00:00:00+08:00")
        let reset = date("2026-09-01T12:00:00+08:00")
        let end = date("2026-09-02T00:00:00+08:00")
        let events = [event("2026-09-01T11:59:59+08:00", tokens: 10),
                      event("2026-09-01T12:00:00+08:00", tokens: 20)]
        let readings = [quota(firstStart, reset, at: "2026-09-01T11:59:00+08:00", percent: 40),
                        quota(reset, end, at: "2026-09-01T13:00:00+08:00", percent: 5),
                        quota(reset, end, at: "2026-09-01T23:59:00+08:00", percent: 15)]
        let result = snapshot(now: end, cycles: [cycle(firstStart, reset, events: events),
                                               cycle(reset, end, events: events)],
                              events: events, readings: readings).cycleHistory.reversed()
        let days = try result.map { try XCTUnwrap($0.dailyUsage?.first) }

        XCTAssertEqual(days.map(\.displayedTokens), [10, 20])
        XCTAssertEqual(days.map(\.quotaConsumedPercent), [40, 15])
        XCTAssertEqual(days.map(\.startsAt), [firstStart, reset])
        XCTAssertEqual(days.map(\.endsAt), [reset, end])
    }

    func testIncompleteDailyQuotaKeepsOnlyRecordedChangesWithinItsSlice() throws {
        let start = date("2026-09-01T12:00:00+08:00")
        let end = date("2026-09-03T12:00:00+08:00")
        let readings = [quota(start, end, at: "2026-09-01T19:30:00+08:00", percent: 10),
                        quota(start, end, at: "2026-09-02T08:00:00+08:00", percent: 20),
                        quota(start, end, at: "2026-09-02T12:00:00+08:00", percent: 30),
                        quota(start, end, at: "2026-09-02T20:00:00+08:00", percent: 45),
                        quota(start, end, at: "2026-09-03T10:00:00+08:00", percent: 60)]
        let result = snapshot(now: end, cycles: [cycle(start, end)], readings: readings)
        let days = try XCTUnwrap(result.cycleHistory.first?.dailyUsage)

        XCTAssertEqual(days.map(\.quotaConsumedPercent), [nil, nil, nil])
        XCTAssertEqual(days.map(\.recordedQuotaConsumedPercent), [10, 25, nil])
    }

    func testTwoRealResetsWithinOneMinuteKeepDistinctDailyQuota() throws {
        let start = date("2026-09-01T00:00:00+08:00")
        let firstReset = date("2026-09-01T06:00:00+08:00")
        let secondReset = date("2026-09-01T06:00:30+08:00")
        let end = date("2026-09-02T00:00:00+08:00")
        let now = date("2026-09-01T12:00:00+08:00")
        let readings = [quota(start, firstReset, at: "2026-09-01T05:59:00+08:00", percent: 30),
                        quota(firstReset, end, at: "2026-09-01T06:00:10+08:00", percent: 5),
                        quota(secondReset, end, at: "2026-09-01T06:00:31+08:00", percent: 0),
                        quota(secondReset, end, at: "2026-09-01T12:00:00+08:00", percent: 2)]
        let result = snapshot(now: now, cycles: [cycle(start, firstReset),
                                               cycle(firstReset, secondReset),
                                               cycle(secondReset, end)], readings: readings)

        XCTAssertEqual(result.cycleHistory.reversed().map { $0.dailyUsage?.first?.quotaConsumedPercent }, [30, 5])
        XCTAssertEqual(result.currentCycle?.dailyUsage?.first?.quotaConsumedPercent, 2)
    }

    func testChangedTimeZoneDoesNotMoveStoredDayTokensToInventASplit() throws {
        let start = date("2026-09-01T12:00:00+08:00")
        let end = date("2026-09-02T12:00:00+08:00")
        let stored = StoredUsageEvent(
            signature: Data("old-time-zone".utf8), occurredAt: date("2026-09-01T13:00:00+08:00"),
            localDay: LocalDay(year: 2026, month: 8, day: 31),
            usage: TokenBreakdown(inputTokens: 100, cachedInputTokens: 0, outputTokens: 0)
        )
        let result = snapshot(now: end, cycles: [cycle(start, end, events: [stored])], events: [stored])

        XCTAssertNil(result.cycleHistory.first?.dailyUsage)
        XCTAssertEqual(result.cycleHistory.first?.displayedTokens, 100)
    }

    func testEstimatedCycleDoesNotInferDailyQuotaFromMatchingReadings() throws {
        let start = date("2026-09-01T12:00:00+08:00")
        let end = date("2026-09-02T12:00:00+08:00")
        let readings = [quota(start, end, at: "2026-09-01T23:59:00+08:00", percent: 20),
                        quota(start, end, at: "2026-09-02T11:59:00+08:00", percent: 30)]
        let result = snapshot(now: end, cycles: [cycle(start, end, estimated: true)], readings: readings)
        let days = try XCTUnwrap(result.cycleHistory.first?.dailyUsage)

        XCTAssertEqual(days.map(\.quotaConsumedPercent), [nil, nil])
        XCTAssertEqual(days.map(\.recordedQuotaConsumedPercent), [nil, nil])
        XCTAssertEqual(result.cycleHistory.first?.status, .localLive)
    }

    func testChangedTimeZoneDoesNotAssignTokensToAnEarlierDayWithinTheCycle() throws {
        let start = date("2026-09-01T12:00:00+08:00")
        let end = date("2026-09-03T12:00:00+08:00")
        let stored = StoredUsageEvent(
            signature: Data("previous-zone-day".utf8), occurredAt: date("2026-09-02T01:00:00+08:00"),
            localDay: LocalDay(year: 2026, month: 9, day: 1),
            usage: TokenBreakdown(inputTokens: 100, cachedInputTokens: 0, outputTokens: 0)
        )
        let result = snapshot(now: end, cycles: [cycle(start, end, events: [stored])], events: [stored])

        XCTAssertNil(result.cycleHistory.first?.dailyUsage)
        XCTAssertEqual(result.cycleHistory.first?.displayedTokens, 100)
    }

    func testMissingRawEventsDoNotInventDailyAllocationForStoredTotal() throws {
        let start = date("2026-09-01T12:00:00+08:00")
        let end = date("2026-09-02T12:00:00+08:00")
        let stored = QuotaCycle(startsAt: start, endsAt: end,
                                usage: TokenBreakdown(inputTokens: 100, cachedInputTokens: 0, outputTokens: 0),
                                displayedTokens: 100, status: .localLive, boundaryIsEstimated: false)
        let result = snapshot(now: end, cycles: [stored]).cycleHistory.first

        XCTAssertNil(result?.dailyUsage)
        XCTAssertEqual(result?.displayedTokens, 100)
        XCTAssertEqual(result?.status, .localLive)
    }

    func testDaylightSavingAndMidnightEndHaveExactlyTheirNaturalDays() throws {
        let calendar = calendar("America/Los_Angeles")
        let start = date("2026-03-07T00:00:00-08:00")
        let end = date("2026-03-10T00:00:00-07:00")
        let result = snapshot(now: end, cycles: [cycle(start, end)], calendar: calendar)
        let days = try XCTUnwrap(result.cycleHistory.first?.dailyUsage)

        XCTAssertEqual(days.map(\.day.iso8601), ["2026-03-07", "2026-03-08", "2026-03-09"])
        XCTAssertEqual(days.map { $0.endsAt.timeIntervalSince($0.startsAt) }, [86_400, 82_800, 86_400])
        XCTAssertEqual(days.map(\.displayedTokens), [0, 0, 0])
        XCTAssertEqual(days.last?.endsAt, end)
    }

    func testEndedCycleWithEveryFullDayOfficiallyCoveredIsCalibrated() throws {
        let start = date("2026-09-01T00:00:00+08:00")
        let end = date("2026-09-03T00:00:00+08:00")
        let result = try XCTUnwrap(snapshot(
            now: end, cycles: [cycle(start, end)],
            official: [official("2026-09-01", 100, end), official("2026-09-02", 0, end)]
        ).cycleHistory.first)

        XCTAssertEqual(result.dailyUsage?.map(\.displayedTokens), [100, 0])
        XCTAssertEqual(result.dailyUsage?.map(\.status), [.calibrated, .calibrated])
        XCTAssertEqual(result.status, .calibrated)
    }

    func testCycleAtItsStartHasNoFutureDailyRows() throws {
        let start = date("2026-09-01T12:00:00+08:00")
        let end = date("2026-09-08T12:00:00+08:00")
        let result = try XCTUnwrap(snapshot(now: start, cycles: [cycle(start, end)]).currentCycle)

        XCTAssertEqual(result.dailyUsage, [])
        XCTAssertEqual(result.displayedTokens, 0)
        XCTAssertEqual(result.status, .localLive)
    }

    func testOlderCyclePayloadWithoutDailyUsageStillDecodes() throws {
        let start = date("2026-09-01T12:00:00+08:00")
        let end = date("2026-09-08T12:00:00+08:00")
        let encoded = try JSONEncoder().encode(cycle(start, end))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "dailyUsage")
        let decoded = try JSONDecoder().decode(QuotaCycle.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertNil(decoded.dailyUsage)
        XCTAssertEqual(decoded.startsAt, start)
    }

    private func snapshot(
        now: Date, cycles: [QuotaCycle], events: [StoredUsageEvent] = [],
        official: [OfficialUsageDay] = [], readings: [QuotaSnapshot] = [],
        calendar: Calendar? = nil
    ) -> UsageSnapshot {
        UsageReconciler().snapshot(now: now, calendar: calendar ?? self.calendar(), quota: readings.last,
                                   events: events, officialDays: official, cycles: cycles,
                                   lastUpdatedAt: now, quotaHistory: readings)
    }

    private func cycle(_ start: Date, _ end: Date, events: [StoredUsageEvent] = [], estimated: Bool = false) -> QuotaCycle {
        let tokens = events.filter { start <= $0.occurredAt && $0.occurredAt < end }
            .reduce(Int64(0)) { $0 + $1.usage.totalTokens }
        return QuotaCycle(startsAt: start, endsAt: end,
                          usage: TokenBreakdown(inputTokens: tokens, cachedInputTokens: 0, outputTokens: 0),
                          displayedTokens: tokens, status: .localLive, boundaryIsEstimated: estimated)
    }

    private func event(_ value: String, tokens: Int64) -> StoredUsageEvent {
        let occurredAt = date(value)
        let components = calendar().dateComponents([.year, .month, .day], from: occurredAt)
        return StoredUsageEvent(signature: Data(value.utf8), occurredAt: occurredAt,
                                localDay: LocalDay(year: components.year!, month: components.month!, day: components.day!),
                                usage: TokenBreakdown(inputTokens: tokens, cachedInputTokens: 0, outputTokens: 0))
    }

    private func official(_ value: String, _ tokens: Int64, _ fetchedAt: Date) -> OfficialUsageDay {
        let parts = value.split(separator: "-").map { Int($0)! }
        return OfficialUsageDay(day: LocalDay(year: parts[0], month: parts[1], day: parts[2]),
                                tokens: tokens, fetchedAt: fetchedAt)
    }

    private func quota(_ start: Date, _ end: Date, at value: String, percent: Double) -> QuotaSnapshot {
        QuotaSnapshot(limitID: "codex", usedPercent: percent, windowDurationMinutes: 10_080,
                      startsAt: start, resetsAt: end, fetchedAt: date(value))
    }

    private func calendar(_ timeZone: String = "Asia/Shanghai") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
