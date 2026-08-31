import XCTest
@testable import UsageCore

final class WeeklyQuotaSelectorTests: XCTestCase {
    func testSelectsCodexSevenDayWindowAndClampsRemainingPercent() throws {
        let data = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": {
                  "usedPercent": 30,
                  "windowDurationMins": 300,
                  "resetsAt": 1788170400
                },
                "secondary": {
                  "usedPercent": 125,
                  "windowDurationMins": 10080,
                  "resetsAt": 1788753600
                }
              },
              "rateLimitsByLimitId": null
            }
            """.utf8
        )
        let response = try JSONDecoder().decode(
            RateLimitsResponse.self,
            from: data
        )

        let quota = WeeklyQuotaSelector().select(
            from: response,
            fetchedAt: Date(timeIntervalSince1970: 1788148800)
        )

        XCTAssertEqual(quota?.windowDurationMinutes, 10080)
        XCTAssertEqual(quota?.remainingPercent, 0)
        XCTAssertEqual(
            quota?.startsAt,
            Date(timeIntervalSince1970: 1788753600 - 10080 * 60)
        )
    }

    func testReturnsNilWhenOnlyShortWindowsExist() throws {
        let response = RateLimitsResponse(
            rateLimits: RateLimitBucket(
                limitId: "codex",
                limitName: nil,
                primary: RateLimitWindow(
                    usedPercent: 12,
                    windowDurationMins: 300,
                    resetsAt: 1788170400
                ),
                secondary: nil
            ),
            rateLimitsByLimitId: nil
        )

        XCTAssertNil(
            WeeklyQuotaSelector().select(
                from: response,
                fetchedAt: Date(timeIntervalSince1970: 1788148800)
            )
        )
    }
}
