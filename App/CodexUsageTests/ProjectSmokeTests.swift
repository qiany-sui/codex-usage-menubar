import CoreGraphics
import UsageCore
import XCTest
@testable import CodexUsage

final class ProjectSmokeTests: XCTestCase {
    func testTestTargetLinksLocalUsageCoreProduct() {
        let usage = TokenBreakdown(
            inputTokens: 100,
            cachedInputTokens: 40,
            outputTokens: 20
        )

        XCTAssertEqual(usage.totalTokens, 120)
    }

    func testOpenPanelConfigurationOnlyAllowsOneDirectory() {
        let configuration = CodexHomePanelConfiguration.live

        XCTAssertTrue(configuration.canChooseDirectories)
        XCTAssertFalse(configuration.canChooseFiles)
        XCTAssertFalse(configuration.allowsMultipleSelection)
        XCTAssertEqual(configuration.prompt, "选择")
        XCTAssertEqual(
            configuration.message,
            "请选择包含 sessions 或 archived_sessions 的 Codex Home 文件夹。"
        )
    }

    func testAppMetadataMatchesMenuBarDelivery() {
        XCTAssertEqual(
            AppMetadata.popoverSize,
            CGSize(width: 410, height: 440)
        )
        XCTAssertEqual(AppMetadata.applicationName, "Codex Usage")
    }
}
