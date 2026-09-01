import UsageCore
import XCTest

final class ProjectSmokeTests: XCTestCase {
    func testTestTargetLinksLocalUsageCoreProduct() {
        let usage = TokenBreakdown(
            inputTokens: 100,
            cachedInputTokens: 40,
            outputTokens: 20
        )

        XCTAssertEqual(usage.totalTokens, 120)
    }
}
