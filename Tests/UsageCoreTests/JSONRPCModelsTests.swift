import XCTest
@testable import UsageCore

final class JSONRPCModelsTests: XCTestCase {
    func testDecodesUnknownNotificationWithoutResponseID() throws {
        let data = Data(
            #"{"method":"remoteControl/status/changed","params":{"state":"idle"}}"#.utf8
        )

        let message = try JSONDecoder().decode(
            RPCIncomingMessage.self,
            from: data
        )

        XCTAssertNil(message.id)
        XCTAssertEqual(message.method, "remoteControl/status/changed")
        XCTAssertNil(message.result)
    }

    func testAccountUsageAcceptsNullDailyBuckets() throws {
        let data = Data(
            #"{"summary":{"lifetimeTokens":null},"dailyUsageBuckets":null,"threadUsage":null}"#.utf8
        )

        let response = try JSONDecoder().decode(
            AccountUsageResponse.self,
            from: data
        )

        XCTAssertNil(response.dailyUsageBuckets)
        XCTAssertNil(response.summary.lifetimeTokens)
    }

    func testSparseRateLimitUpdatePreservesMissingWindowFields() throws {
        let full = try JSONDecoder().decode(
            RateLimitsResponse.self,
            from: Data(
                #"{"rateLimits":{"limitId":"codex","primary":null,"secondary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":1788753600}},"rateLimitsByLimitId":null}"#.utf8
            )
        )
        let updateData = Data(
            #"{"rateLimits":{"secondary":{"usedPercent":31}}}"#.utf8
        )
        let update = try JSONDecoder().decode(
            RateLimitsUpdatedParams.self,
            from: updateData
        )

        let merged = full.applying(update)

        XCTAssertEqual(merged.rateLimits.secondary?.usedPercent, 31)
        XCTAssertEqual(
            merged.rateLimits.secondary?.windowDurationMins,
            10_080
        )
        XCTAssertEqual(
            merged.rateLimits.secondary?.resetsAt,
            1_788_753_600
        )
    }
}
