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
            CGSize(width: 380, height: 440)
        )
        XCTAssertEqual(AppMetadata.applicationName, "Codex Usage")
    }

    func testPopoverUsesNativeMaterialWithoutForcingDarkAppearance() throws {
        let source = try appSource(named: "UsagePopoverView.swift")

        XCTAssertTrue(source.contains(".background(.regularMaterial)"))
        XCTAssertFalse(source.contains(".preferredColorScheme(.dark)"))
    }

    func testUsageThemeUsesSystemSemanticColors() throws {
        let source = try appSource(named: "UsageTheme.swift")

        XCTAssertTrue(source.contains("Color(nsColor: .windowBackgroundColor)"))
        XCTAssertTrue(source.contains("Color(nsColor: .controlBackgroundColor)"))
        XCTAssertTrue(source.contains("Color(nsColor: .separatorColor)"))
        XCTAssertTrue(source.contains("Color(nsColor: .labelColor)"))
        XCTAssertTrue(source.contains("Color(nsColor: .secondaryLabelColor)"))
        XCTAssertTrue(source.contains("Color(nsColor: .controlAccentColor)"))
        XCTAssertFalse(source.contains("Color(red:"))
    }

    func testOverviewAndTrendDoNotUseCustomAccentGradients() throws {
        let overviewSource = try appSource(named: "OverviewView.swift")
        let trendSource = try appSource(named: "TrendDetailView.swift")

        XCTAssertFalse(overviewSource.contains("LinearGradient("))
        XCTAssertFalse(trendSource.contains("LinearGradient("))
    }

    private func appSource(named fileName: String) throws -> String {
        let appDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodexUsage", isDirectory: true)

        return try String(
            contentsOf: appDirectory.appendingPathComponent(fileName),
            encoding: .utf8
        )
    }

}
