import XCTest
@testable import UsageCore

final class DomainModelsTests: XCTestCase {
    func testLocalDayFormatsAndComparesByCalendarComponents() {
        let earlier = LocalDay(year: 2026, month: 8, day: 30)
        let later = LocalDay(year: 2026, month: 8, day: 31)

        XCTAssertEqual(later.iso8601, "2026-08-31")
        XCTAssertLessThan(earlier, later)
    }

    func testQuotaRemainingPercentClampsWithinZeroAndHundred() {
        let date = Date(timeIntervalSince1970: 0)
        let overused = QuotaSnapshot(limitID: "x", usedPercent: 120, windowDurationMinutes: 60, startsAt: date, resetsAt: date, fetchedAt: date)
        let negative = QuotaSnapshot(limitID: "x", usedPercent: -20, windowDurationMinutes: 60, startsAt: date, resetsAt: date, fetchedAt: date)

        XCTAssertEqual(overused.remainingPercent, 0)
        XCTAssertEqual(negative.remainingPercent, 100)
    }

    func testQuotaRemainingPercentReturnsComplementForNormalUsage() {
        let date = Date(timeIntervalSince1970: 0)
        let quota = QuotaSnapshot(limitID: "x", usedPercent: 40, windowDurationMinutes: 60, startsAt: date, resetsAt: date, fetchedAt: date)

        XCTAssertEqual(quota.remainingPercent, 60)
    }

    func testTotalTokensCountsInputAndOutputOnly() {
        let usage = TokenBreakdown(
            inputTokens: 100,
            cachedInputTokens: 80,
            outputTokens: 20
        )

        XCTAssertEqual(usage.totalTokens, 120)
    }

    func testAddingBreakdownsAddsEachCounterIndependently() {
        let left = TokenBreakdown(
            inputTokens: 100,
            cachedInputTokens: 40,
            outputTokens: 20
        )
        let right = TokenBreakdown(
            inputTokens: 7,
            cachedInputTokens: 3,
            outputTokens: 5
        )

        XCTAssertEqual(
            left + right,
            TokenBreakdown(
                inputTokens: 107,
                cachedInputTokens: 43,
                outputTokens: 25
            )
        )
    }
}
