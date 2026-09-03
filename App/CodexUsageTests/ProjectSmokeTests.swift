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

    func testAppBundlesCompanionLaunchAgentAndExecutable() throws {
        let contentsURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
        let executableURL = contentsURL
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("CodexUsageWatcher")
        let plistURL = contentsURL
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.local.CodexUsage.Watcher.plist")

        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: executableURL.path),
            "辅助程序必须作为可执行文件嵌入 App"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: plistURL.path),
            "LaunchAgent plist 必须嵌入 App"
        )

        let data = try Data(contentsOf: plistURL)
        let object = try PropertyListSerialization.propertyList(
            from: data,
            format: nil
        )
        let plist = try XCTUnwrap(object as? [String: Any])

        XCTAssertEqual(plist["Label"] as? String, "com.local.CodexUsage.Watcher")
        XCTAssertEqual(
            plist["BundleProgram"] as? String,
            "Contents/MacOS/CodexUsageWatcher"
        )
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
