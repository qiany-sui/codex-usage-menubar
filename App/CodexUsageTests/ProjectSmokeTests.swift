import AppKit
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

    func testPopoverDoesNotForceAppearanceOrUseWallpaperDependentMaterial() throws {
        let source = try appSource(named: "UsagePopoverView.swift")

        XCTAssertFalse(source.contains(".background(.regularMaterial)"))
        XCTAssertFalse(source.contains(".preferredColorScheme(.dark)"))
    }

    func testApprovedPalettesAdaptToAppearance() throws {
        let cases: [(UsageStyle, NSAppearance.Name, UInt32, UInt32)] = [
            (.native, .aqua, 0xf6f7f9, 0x2868c7),
            (.native, .darkAqua, 0x232428, 0x81b2ff),
            (.orbit, .aqua, 0xf5f4f8, 0x7952b8),
            (.orbit, .darkAqua, 0x222127, 0xbb9de9)
        ]

        for (style, appearanceName, background, accent) in cases {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            appearance.performAsCurrentDrawingAppearance {
                for (color, expected) in [
                    (style.colors.background, background),
                    (style.colors.accent, accent)
                ] {
                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else {
                        XCTFail("无法解析配色")
                        continue
                    }
                    XCTAssertEqual(rgb.redComponent, CGFloat((expected >> 16) & 0xff) / 255, accuracy: 0.001)
                    XCTAssertEqual(rgb.greenComponent, CGFloat((expected >> 8) & 0xff) / 255, accuracy: 0.001)
                    XCTAssertEqual(rgb.blueComponent, CGFloat(expected & 0xff) / 255, accuracy: 0.001)
                    XCTAssertEqual(rgb.alphaComponent, 1)
                }
            }
        }
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
