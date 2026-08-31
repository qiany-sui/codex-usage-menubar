import XCTest
@testable import UsageCore

final class DomainModelsTests: XCTestCase {
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
