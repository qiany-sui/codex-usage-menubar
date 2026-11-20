import AppKit
import CoreGraphics
import SwiftUI
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
            CGSize(width: 360, height: 440)
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

    @MainActor
    func testOverviewFitsResetDayMetricsWithoutVerticalScrolling() throws {
        let base = try sampleSnapshot(today: TokenBreakdown(
            inputTokens: 38_668_000, cachedInputTokens: 36_794_000, outputTokens: 149_000
        ))
        let now = base.lastUpdatedAt
        let cases: [(segmentCount: Int, isPartial: Bool)] = [
            (0, false), (2, false), (2, true), (3, false), (3, true)
        ]

        for (segmentCount, isPartial) in cases {
            let segments = (0..<segmentCount).map { index in
                let percent = index == 0 ? 100.0 : 9.0
                return QuotaConsumptionSegment(
                    startsAt: now.addingTimeInterval(Double(index - segmentCount) * 3 * 3600),
                    endsAt: now.addingTimeInterval(Double(index + 1 - segmentCount) * 3 * 3600),
                    consumedPercent: isPartial ? nil : percent,
                    startsWithReset: index > 0,
                    recordedConsumedPercent: isPartial ? percent : nil
                )
            }
            let today = UsageDay(
                day: base.today.day, localUsage: base.today.localUsage,
                officialTokens: nil, displayedTokens: base.today.displayedTokens,
                status: .localLive,
                quotaConsumedPercent: segmentCount == 0 ? 9 : nil,
                quotaSegments: segments.isEmpty ? nil : segments
            )
            let snapshot = UsageSnapshot(
                quota: base.quota, today: today, currentCycle: base.currentCycle,
                recentDays: [today], cycleHistory: [], lastUpdatedAt: now, status: .localLive
            )
            let presentation = OverviewPresentation(
                snapshot: snapshot, now: now, timeZone: utcCalendar().timeZone
            )
            for style in UsageStyle.allCases {
                for scheme in [ColorScheme.light, .dark] {
                    let view = NSHostingView(rootView:
                        OverviewView(presentation: presentation, style: .constant(style))
                            .modifier(UsagePopoverSurface(style: style))
                            .environment(\.colorScheme, scheme)
                    )
                    view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    view.frame = NSRect(origin: .zero, size: AppMetadata.popoverSize)
                    view.layoutSubtreeIfNeeded()
                    let scroll = try XCTUnwrap(
                        descendants(of: view).compactMap { $0 as? NSScrollView }.first
                    )
                    let document = try XCTUnwrap(scroll.documentView)
                    // 离屏 SwiftUI 文档 bounds 可能为零，以实际子视图末端检查是否溢出。
                    let contentBottom = try XCTUnwrap(descendants(of: document).map {
                        $0.convert($0.bounds, to: document).maxY
                    }.max())
                    XCTAssertGreaterThan(contentBottom, 0)
                    XCTAssertLessThanOrEqual(
                        contentBottom, scroll.contentView.bounds.height,
                        "\(style.rawValue) / \(scheme) / segments=\(segmentCount) / partial=\(isPartial)：首页信息应完整显示，无需滚动"
                    )
                }
            }
        }
    }

    @MainActor
    func testTodayQuotaOpensAndClosesDetailsOnOverviewInBothStyles() throws {
        let base = try sampleSnapshot()
        let model = ModelTokenUsage(model: "example-model", usage: base.today.localUsage)
        let today = UsageDay(
            day: base.today.day, localUsage: model.usage, officialTokens: nil,
            displayedTokens: 120, status: .localLive, modelUsage: [model]
        )
        let snapshot = UsageSnapshot(
            quota: nil, today: today, currentCycle: nil, recentDays: [], cycleHistory: [],
            lastUpdatedAt: base.lastUpdatedAt, status: .localLive
        )
        let overview = OverviewPresentation(snapshot: snapshot, now: base.lastUpdatedAt, timeZone: utcCalendar().timeZone)

        let restoreAccessibility = enableAccessibility()
        defer { restoreAccessibility() }

        for style in UsageStyle.allCases {
            var trendOpens = 0
            var expanded = true
            let view = OverviewView(
                presentation: overview, style: .constant(style),
                isModelUsageExpanded: Binding(get: { expanded }, set: { expanded = $0 }),
                onShowTrend: { trendOpens += 1 }
            )
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: view.modifier(UsagePopoverSurface(style: style, height: 570))
                    .environment(\.accessibilityEnabled, true)
            ))
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            try press("当日额度消耗")
            try press("关闭当日详情")
            XCTAssertNil(findButton("关闭当日详情", visible: false))
            XCTAssertEqual(trendOpens, 0)
            XCTAssertTrue(expanded)
            XCTAssertNotNil(findButton("example-model"))
            try press("最近 7 天")
            XCTAssertEqual(trendOpens, 1)
        }
    }

    @MainActor
    func testTogglingModelListKeepsPopoverAndNavigationInPlace() async throws {
        let base = try sampleSnapshot()
        let modelNames = (1...4).map { "model-\($0)" }
        let usage = TokenBreakdown(inputTokens: 25, cachedInputTokens: 10, outputTokens: 5)
        let today = UsageDay(
            day: base.today.day, localUsage: base.today.localUsage, officialTokens: nil,
            displayedTokens: base.today.displayedTokens, status: .localLive,
            modelUsage: modelNames.map { ModelTokenUsage(model: $0, usage: usage) }
        )
        let snapshot = UsageSnapshot(
            quota: base.quota, today: today, currentCycle: base.currentCycle, recentDays: [today],
            cycleHistory: [], lastUpdatedAt: base.lastUpdatedAt, status: .localLive
        )
        let viewModel = await startedTestViewModel(snapshot: snapshot)
        addTeardownBlock { await viewModel.stop() }
        let suite = "CodexUsageFoldTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let restoreAccessibility = enableAccessibility()
        defer { restoreAccessibility() }

        for style in UsageStyle.allCases {
            defaults.set(style.rawValue, forKey: UsageStyle.storageKey)
            let controller = NSHostingController(rootView:
                UsagePopoverView(viewModel: viewModel, now: { base.lastUpdatedAt }, styleDefaults: defaults)
                    .environment(\.accessibilityEnabled, true)
            )
            let window = NSWindow(contentViewController: controller)
            window.setContentSize(controller.view.fittingSize)
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            controller.view.layoutSubtreeIfNeeded()

            func buttonFrame(_ name: String) throws -> NSRect {
                let button = try XCTUnwrap(findButton(name), name)
                let frame = try XCTUnwrap(button.accessibilityFrame?(), name)
                XCTAssertFalse(frame.isEmpty, name)
                return controller.view.convert(window.convertFromScreen(frame), from: nil)
            }

            XCTAssertNil(findButton("model-4", visible: false))
            let toggle = try buttonFrame("按模型")
            let navigation = try buttonFrame("最近 7 天")
            let size = controller.view.fittingSize
            for expanded in [true, false] {
                try press("按模型")
                for name in modelNames {
                    XCTAssertEqual(findButton(name, visible: expanded) != nil, expanded, name)
                }
                controller.view.layoutSubtreeIfNeeded()
                XCTAssertEqual(controller.view.fittingSize, size, style.title)
                XCTAssertEqual(try buttonFrame("最近 7 天"), navigation, style.title)
                XCTAssertEqual(try buttonFrame("按模型"), toggle, style.title)
            }
        }
    }

    @MainActor
    func testOverviewModelListStartsCollapsedInBothStyles() throws {
        let base = try sampleSnapshot()

        func contentHeight(modelCount: Int, style: UsageStyle, expanded: Bool = false) throws -> CGFloat {
            let models = (0..<modelCount).map { index in
                ModelTokenUsage(model: "model-\(index)", usage: .init(
                    inputTokens: 100, cachedInputTokens: 40, outputTokens: 20
                ))
            }
            let today = UsageDay(
                day: base.today.day, localUsage: base.today.localUsage,
                officialTokens: nil, displayedTokens: base.today.displayedTokens,
                status: .localLive, modelUsage: models
            )
            let snapshot = UsageSnapshot(
                quota: base.quota, today: today, currentCycle: base.currentCycle,
                recentDays: [today], cycleHistory: [], lastUpdatedAt: base.lastUpdatedAt, status: .localLive
            )
            let presentation = OverviewPresentation(
                snapshot: snapshot, now: base.lastUpdatedAt, timeZone: utcCalendar().timeZone
            )
            let view = NSHostingView(rootView:
                OverviewView(
                    presentation: presentation, style: .constant(style), isModelUsageExpanded: .constant(expanded)
                )
                    .modifier(UsagePopoverSurface(style: style, height: 570))
            )
            view.frame = NSRect(x: 0, y: 0, width: AppMetadata.popoverSize.width, height: 570)
            view.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSScrollView }.first)
            let document = try XCTUnwrap(scroll.documentView)
            return try XCTUnwrap(descendants(of: document).map {
                $0.convert($0.bounds, to: document).maxY
            }.max())
        }

        for style in UsageStyle.allCases {
            let oneModel = try contentHeight(modelCount: 1, style: style)
            let fourModels = try contentHeight(modelCount: 4, style: style)
            XCTAssertGreaterThan(oneModel, 0)
            XCTAssertEqual(oneModel, fourModels, accuracy: 1, "\(style.title) 收拢时的高度与模型数量无关")
            let expanded = try contentHeight(modelCount: 4, style: style, expanded: true)
            XCTAssertGreaterThan(expanded, fourModels + 80, "\(style.title) 展开后应显示四行模型")
        }
    }

    @MainActor
    func testTrendShowsAllSevenCollapsedDaysWithoutVerticalScrolling() throws {
        let base = try sampleSnapshot(
            recentDayTotals: [230_000_000, 0, 392_000, 7_846_000, 23_000_000, 48_000_000, 94_653_000],
            recentStatuses: [.calibrated, .localLive, .unavailable, .calibrated, .partiallyCalibrated, .calibrated, .stale]
        )
        let now = base.lastUpdatedAt
        let reset = now.addingTimeInterval(-3600)
        let days = base.recentDays.enumerated().map { index, day in
            UsageDay(
                day: day.day, localUsage: day.localUsage,
                officialTokens: day.officialTokens, displayedTokens: day.displayedTokens,
                status: day.status, quotaConsumedPercent: index == 3 ? 43 : nil,
                quotaSegments: index == 6 ? [
                    QuotaConsumptionSegment(
                        startsAt: now.addingTimeInterval(-8 * 3600), endsAt: reset,
                        consumedPercent: nil, startsWithReset: false
                    ),
                    QuotaConsumptionSegment(
                        startsAt: reset, endsAt: now, consumedPercent: 15,
                        startsWithReset: true
                    )
                ] : nil,
                recordedQuotaConsumedPercent: index == 4 ? 72 : nil
            )
        }
        let today = try XCTUnwrap(days.last)
        let presentation = TrendPresentation(snapshot: UsageSnapshot(
            quota: base.quota, today: today, currentCycle: base.currentCycle,
            recentDays: days, cycleHistory: [], lastUpdatedAt: now, status: .localLive
        ), timeZone: utcCalendar().timeZone)
        XCTAssertEqual(presentation.days.count, 7)

        for style in UsageStyle.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let view = NSHostingView(rootView:
                    TrendDetailView(presentation: presentation, onBack: {})
                        .modifier(UsagePopoverSurface(style: style))
                        .environment(\.colorScheme, scheme)
                )
                view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                view.frame = NSRect(origin: .zero, size: AppMetadata.popoverSize)
                view.layoutSubtreeIfNeeded()
                let scroll = try XCTUnwrap(
                    descendants(of: view).compactMap { $0 as? NSScrollView }.first
                )
                let document = try XCTUnwrap(scroll.documentView)
                let contentViews = descendants(of: document)
                let contentBottom = try XCTUnwrap(contentViews.map {
                    $0.convert($0.bounds, to: document).maxY
                }.max())
                XCTAssertGreaterThan(contentBottom, 0)

                // 按实际行按钮的非零布局框检查七行，避免空文档或少渲染日期误通过。
                let leafFrames = contentViews.filter { $0.subviews.isEmpty }.map {
                    $0.convert($0.bounds, to: document)
                }.filter { !$0.isEmpty }
                let rowFrames = Dictionary(grouping: leafFrames.filter {
                    $0.width > scroll.contentView.bounds.width * 0.75
                        && (20...80).contains($0.height)
                }, by: \.minY).compactMap { $0.value.first }
                XCTAssertEqual(rowFrames.count, 7, "七个日期行必须都实际渲染")
                for row in rowFrames {
                    let labels = leafFrames.filter {
                        row.contains($0) && $0.height > 8 && $0.width < row.width / 2
                    }
                    XCTAssertGreaterThanOrEqual(labels.count, 3, "每行应包含日期、Token 和额度内容")
                }
                XCTAssertLessThanOrEqual(
                    contentBottom, scroll.contentView.bounds.height,
                    "\(style.rawValue) / \(scheme)：七天折叠列表应完整显示，无需滚动"
                )

                scroll.scrollerStyle = .legacy
                scroll.hasVerticalScroller = true
                scroll.autohidesScrollers = false
                scroll.tile()
                view.layoutSubtreeIfNeeded()
                // SwiftUI 的尺寸偏好在下一轮布局反馈到固定表头。
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                view.layoutSubtreeIfNeeded()

                let scrollFrame = scroll.convert(scroll.bounds, to: view)
                let visibleLeafFrames = descendants(of: view).filter { $0.subviews.isEmpty }.map {
                    $0.convert($0.bounds, to: view)
                }.filter { !$0.isEmpty }
                let columnHeaders = visibleLeafFrames.filter {
                    // 排除说明图标及其点击区域，只比较三个文字表头。
                    $0.width >= 20 && $0.height > 8 && $0.maxY <= scrollFrame.minY
                        && $0.minY >= scrollFrame.minY - 30
                }.sorted { $0.minX < $1.minX }
                let firstRow = try XCTUnwrap(visibleLeafFrames.filter {
                    $0.width > scroll.contentView.bounds.width * 0.75
                        && (20...80).contains($0.height) && $0.minY >= scrollFrame.minY
                }.min { $0.minY < $1.minY })
                let rowColumns = visibleLeafFrames.filter {
                    firstRow.contains($0) && $0.height > 8 && $0.width < firstRow.width / 2
                }.sorted { $0.minX < $1.minX }
                XCTAssertEqual(columnHeaders.count, 3, "必须实际布局日期、Token 和额度表头")
                XCTAssertEqual(rowColumns.count, 3, "首行必须实际布局三列数据")
                if columnHeaders.count == 3 && rowColumns.count == 3 {
                    XCTAssertEqual(
                        columnHeaders[2].minX, rowColumns[2].minX, accuracy: 0.5,
                        "\(style.rawValue) / \(scheme)：常显滚动条下额度表头应与数值同起点"
                    )
                }

                scroll.scrollerStyle = .overlay
                scroll.hasVerticalScroller = true
                scroll.autohidesScrollers = false
                scroll.tile()
                view.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                view.layoutSubtreeIfNeeded()
                let scroller = try XCTUnwrap(scroll.verticalScroller)
                let scrollerFrame = scroller.convert(scroller.bounds, to: view)
                XCTAssertGreaterThan(scrollerFrame.width, 0, "必须取得实际覆盖式滚动条区域")
                let overlayRows = descendants(of: document).filter { $0.subviews.isEmpty }.map {
                    $0.convert($0.bounds, to: view)
                }.filter {
                    $0.width > scroll.contentView.bounds.width * 0.75
                        && (20...80).contains($0.height)
                }
                let rowRight = try XCTUnwrap(overlayRows.map(\.maxX).max())
                XCTAssertLessThanOrEqual(
                    rowRight, scrollerFrame.minX,
                    "\(style.rawValue) / \(scheme)：日期行和箭头应避开覆盖式滚动条区域"
                )
            }
        }
    }

    @MainActor
    private func enableAccessibility() -> () -> Void {
        // AppKit 在辅助技术启用后才会向测试宿主公开 SwiftUI 滚动区域的子节点。
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhancedUI) as? Bool ?? false
        NSApp.accessibilitySetValue(true, forAttribute: enhancedUI)
        return { NSApp.accessibilitySetValue(previous, forAttribute: enhancedUI) }
    }

    @MainActor
    private func findButton(_ name: String, visible: Bool = true) -> AnyObject? {
        func button(in element: AnyObject) -> AnyObject? {
            // SwiftUI 的节点支持标准无障碍方法，但不声明遵从整套 AppKit 协议。
            let title = element.accessibilityLabel?() ?? element.accessibilityTitle?() ?? ""
            if element.accessibilityRole?() == .button, title.hasPrefix(name) { return element }
            for child in element.accessibilityChildren?() ?? [] {
                if let found = button(in: child as AnyObject) { return found }
            }
            return nil
        }
        let deadline = Date().addingTimeInterval(2)
        var match: AnyObject?
        repeat {
            match = NSApp.windows.lazy.filter(\.isVisible).compactMap { button(in: $0) }.first
            if (match != nil) == visible { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        return match
    }

    @MainActor
    private func press(_ name: String) throws {
        let element = try XCTUnwrap(findButton(name), name)
        XCTAssertTrue(element.accessibilityPerformPress?() == true, name)
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
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
