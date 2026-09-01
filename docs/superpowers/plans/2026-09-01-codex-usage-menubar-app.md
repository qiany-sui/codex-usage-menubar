# Codex Usage 原生菜单栏 App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 `UsageCore` 之上交付一个可由 Xcode 16.4 构建、运行并双击启动的 Apple Silicon macOS 菜单栏应用，完整展示额度、今日用量、7 天趋势和周期历史。

**Architecture:** 使用标准 Xcode macOS App Target，通过本地 Swift Package 依赖复用仓库根目录的 `UsageCore`。`AppContainer` 负责组装真实依赖，`@MainActor UsageViewModel` 负责任务生命周期和 UI 状态，纯 SwiftUI `MenuBarExtra(.window)` 负责固定尺寸的概览、趋势和历史页面；App 层只做展示和编排，不复制 Token、校准、周期或持久化规则。

**Tech Stack:** Xcode 16.4、Swift 6、SwiftUI、AppKit、Combine、Charts、Foundation、XCTest、现有 `UsageCore` Swift Package、SQLite3 与 CoreServices（由 `UsageCore` 间接使用）。

**Spec:** `docs/superpowers/specs/2026-09-01-codex-usage-menubar-app-design.md`

## Global Constraints

- 仅支持 Apple Silicon 与 macOS 13+；App 与测试 Target 的 `MACOSX_DEPLOYMENT_TARGET` 固定为 `13.0`，App Target 的 `ARCHS` 固定为 `arm64`。
- 使用 Xcode 16.4 和 Swift 6；根目录 `Package.swift` 继续保持 `swift-tools-version: 6.0` 与 `.macOS(.v13)`。
- 使用纯 SwiftUI `MenuBarExtra(.window)`；`LSUIElement=true`，不显示 Dock 图标和常规主窗口。
- App Target 只依赖仓库根目录的本地 `UsageCore` package；不复制核心领域、解析、校准、周期或 SQLite 逻辑。
- App Sandbox 固定关闭：`ENABLE_APP_SANDBOX=NO`；v1 不面向 Mac App Store。
- 不引入第三方 package、字体、图标库、分析 SDK 或网络服务；图表只使用 Apple `Charts`。
- 界面固定为 `410 × 440 pt`、强制现代深色、简体中文、系统字体和 SF Symbols。
- 今日总量固定为 `inputTokens + outputTokens`；`cachedInputTokens` 只是输入子集，不得作为可相加的第四项。
- SQLite 固定写入 `~/Library/Application Support/Codex Usage/usage.sqlite`，不得写入仓库、Codex Home 或临时目录。
- 不读取 `auth.json`，不保存或输出提示词、回复正文、邮箱、Account ID、Cookie、OAuth Token、API Key 或其他凭据。
- 不发送遥测，不调用私有 HTTP，不增加多账号、云同步、费用估算、通知、登录启动、自动更新、安装器、公证、Mac App Store 或 Intel 支持。
- 保留当前周期和最近 8 个已完成周期；继续依赖 `UsageCore` 的 9 周期清理策略。
- 所有 shell 命令使用 `rtk`；所有 Git 提交使用 `[ai] <type>(<scope>): <中文主题>`，单行不超过 72 字符，并只暂存当前任务文件。
- `.idea/`、`.superpowers/`、`DerivedData/`、构建出的 `.app`、SQLite、bookmark 和 Xcode 用户状态不进入 Git。

## File Map

```text
Package.swift                                      # 保持现有本地 UsageCore package
Sources/UsageCore/Coordination/UsageService.swift # 公开最终解析出的 Codex Home
Tests/UsageCoreTests/UsageServiceTests.swift       # resolvedCodexHome 回归测试
.gitignore                                         # 忽略 Xcode 用户状态与本地构建产物
LICENSE                                            # MIT License
README.md                                          # 面向 Xcode 新手的构建、运行、退出和 Release 指南
App/
  CodexUsage.xcodeproj/
    project.pbxproj                                # App/Test targets、本地 package 依赖和构建设置
    project.xcworkspace/
      contents.xcworkspacedata                     # Xcode workspace 元数据
  CodexUsage/
    CodexUsageApp.swift                            # MenuBarExtra、唤醒事件和退出清理
    AppContainer.swift                             # 数据库路径、进程、store、service、watcher 组装
    UsageRuntime.swift                             # App 层最小协议、runtime 与可测试依赖闭包
    UsageViewModel.swift                           # 主线程状态、刷新、监听、重试、导航和停止
    UsagePresentation.swift                        # Snapshot 到视图所需值的只读映射
    UsagePopoverView.swift                         # 固定弹窗、状态页、同窗页面路由和转场
    OverviewView.swift                             # 额度、今日、周期和入口
    TrendDetailView.swift                          # 最近 7 天统计与柱状图
    CycleHistoryView.swift                         # 当前周期与最近 8 个已完成周期
    UsageTheme.swift                               # 深色颜色、字号、间距和转场常量
    UsageFormatters.swift                          # 百分比、Token、日期、倒计时和状态文案
    CodexHomeBookmarkStore.swift                   # bookmark 保存、恢复、校验和访问释放
    Info.plist                                     # LSUIElement 与应用元数据
    Assets.xcassets/
      Contents.json
      AccentColor.colorset/Contents.json
  CodexUsageTests/
    ProjectSmokeTests.swift                        # Xcode target 与 UsageCore 链接冒烟测试
    UsageFormattersTests.swift                     # 确定性格式化测试
    CodexHomeBookmarkStoreTests.swift              # bookmark/目录校验测试
    AppContainerTests.swift                        # 真实本地 runtime 组装测试
    UsageViewModelTests.swift                      # 状态、原因映射、重试、取消和重建测试
    UsagePresentationTests.swift                   # 今日、趋势和周期展示口径测试
    TestSupport.swift                              # App 测试 fake、固定时间和样例快照
```

---

### Task 1: 向 App 暴露最终解析出的 Codex Home

**Files:**
- Modify: `Sources/UsageCore/Coordination/UsageService.swift`
- Modify: `Tests/UsageCoreTests/UsageServiceTests.swift`

**Interfaces:**
- Consumes: `CodexHomeResolver.resolve(initializedHome:environment:homeDirectory:) -> URL?`。
- Produces: `UsageService.resolvedCodexHome() -> URL?`；App 在首次刷新后用它确定 watcher 目录。

- [ ] **Step 1: 写失败测试，固定未初始化、显式环境和 app-server 优先级**

在 `UsageServiceTests.swift` 中增加三项 actor 测试。每个测试都创建独立临时目录，避免依赖开发机真实的 `~/.codex`：

```swift
func testResolvedCodexHomeIsNilBeforeInitializationWhenNoCandidateExists() async throws {
    let home = try temporaryDirectory()
    let service = UsageService(
        accountClient: NeverInitializedAccountClient(),
        indexer: CountingSessionIndexer(),
        store: ReadOnlyUsageStoreSpy(),
        environment: [:],
        homeDirectory: home,
        calendar: Calendar(identifier: .gregorian)
    )

    XCTAssertNil(await service.resolvedCodexHome())
}

func testResolvedCodexHomeUsesExplicitEnvironmentBeforeInitialization() async throws {
    let codexHome = try temporaryCodexHome()
    let service = UsageService(
        accountClient: NeverInitializedAccountClient(),
        indexer: CountingSessionIndexer(),
        store: ReadOnlyUsageStoreSpy(),
        environment: ["CODEX_HOME": codexHome.path],
        homeDirectory: try temporaryDirectory(),
        calendar: Calendar(identifier: .gregorian)
    )

    XCTAssertEqual(
        await service.resolvedCodexHome(),
        codexHome.standardizedFileURL
    )
}

func testResolvedCodexHomePrefersInitializedHomeOverEnvironment() async throws {
    let initializedHome = try temporaryCodexHome()
    let environmentHome = try temporaryCodexHome()
    let fixture = try await ServiceFixture.make(
        initializedHome: initializedHome,
        environment: ["CODEX_HOME": environmentHome.path]
    )

    _ = try await fixture.service.refresh(
        reason: .startup,
        now: try date("2026-09-01T08:00:00Z")
    )

    XCTAssertEqual(
        await fixture.service.resolvedCodexHome(),
        initializedHome.standardizedFileURL
    )
}
```

测试辅助类型使用以下最小实现：

```swift
private enum HomeResolutionTestError: Error {
    case unavailable
}

private actor NeverInitializedAccountClient: AccountUsageReading {
    func initialize() async throws -> InitializeResult {
        throw HomeResolutionTestError.unavailable
    }

    func readRateLimits() async throws -> RateLimitsResponse {
        throw HomeResolutionTestError.unavailable
    }

    func readAccountUsage() async throws -> AccountUsageResponse {
        throw HomeResolutionTestError.unavailable
    }

    func nextNotification() async -> AppServerNotification? { nil }
}
```

扩展现有 `ServiceFixture.make` 为 `static func make(initializedHome: URL? = nil, environment: [String: String] = [:]) async throws -> ServiceFixture`；传入 URL 时用于 fake 的 `InitializeResult.codexHome`，未传时保持现有 fixture 默认值，避免改动原测试语义。

- [ ] **Step 2: 运行定向测试并确认公开方法缺失**

Run: `rtk swift test --filter UsageServiceTests/testResolvedCodexHome`

Expected: FAIL，编译器报告 `UsageService` 没有 `resolvedCodexHome`。

- [ ] **Step 3: 添加只读方法并复用现有 resolver**

在 `UsageService` 的 `currentSnapshot` 之前加入：

```swift
public func resolvedCodexHome() -> URL? {
    homeResolver.resolve(
        initializedHome: initializedHome,
        environment: environment,
        homeDirectory: homeDirectory
    )
}
```

该方法不得调用 `initialize()`、扫描目录、迁移数据库或修改状态；actor 隔离已经保证与刷新期间的 `initializedHome` 读取串行。

- [ ] **Step 4: 运行核心定向测试和全套回归**

Run: `rtk swift test --filter UsageServiceTests`

Expected: PASS，新增的三个目录解析用例和原有服务用例全部通过。

Run: `rtk swift test`

Expected: PASS，原 165 个测试加新增测试全部通过，0 failures，无新增 warning。

- [ ] **Step 5: 提交 UsageCore 补充**

```bash
rtk git add Sources/UsageCore/Coordination/UsageService.swift Tests/UsageCoreTests/UsageServiceTests.swift
rtk git commit -m "[ai] feat(core): 暴露最终 Codex Home"
```

---

### Task 2: 创建可构建和可运行的 Xcode 菜单栏工程

**Files:**
- Create: `App/CodexUsage.xcodeproj/project.pbxproj`
- Create: `App/CodexUsage.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- Create: `App/CodexUsage/CodexUsageApp.swift`
- Create: `App/CodexUsage/Info.plist`
- Create: `App/CodexUsage/Assets.xcassets/Contents.json`
- Create: `App/CodexUsage/Assets.xcassets/AccentColor.colorset/Contents.json`
- Create: `App/CodexUsageTests/ProjectSmokeTests.swift`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: 根目录本地 package product `UsageCore`。
- Produces: `CodexUsage` App Target、`CodexUsageTests` Unit Test Target、共享 `CodexUsage` scheme，以及可运行的 `MenuBarExtra(.window)` 冒烟应用。

- [ ] **Step 1: 创建经典 Xcode project object graph**

`project.pbxproj` 使用 `objectVersion = 56` 的经典 PBX group/file reference，不依赖外部生成器。对象图必须准确包含：

```text
PBXProject
├── mainGroup
│   ├── CodexUsage group -> App/CodexUsage 下的 Swift、Info.plist、Assets.xcassets
│   ├── CodexUsageTests group -> App/CodexUsageTests 下的 Swift
│   ├── Products group -> Codex Usage.app、CodexUsageTests.xctest
│   └── XCLocalSwiftPackageReference "../.."
├── PBXNativeTarget CodexUsage
│   ├── Sources: CodexUsageApp.swift
│   ├── Resources: Assets.xcassets
│   ├── Frameworks: UsageCore package product
│   └── productType: com.apple.product-type.application
└── PBXNativeTarget CodexUsageTests
    ├── Sources: ProjectSmokeTests.swift
    ├── Frameworks: XCTest、UsageCore、CodexUsage
    ├── Target dependency: CodexUsage
    └── productType: com.apple.product-type.bundle.unit-test
```

Debug 与 Release 的 App build settings 固定为：

```text
ARCHS = arm64
CODE_SIGN_IDENTITY = "-"
CODE_SIGN_STYLE = Automatic
CURRENT_PROJECT_VERSION = 1
DEVELOPMENT_TEAM = ""
ENABLE_APP_SANDBOX = NO
GENERATE_INFOPLIST_FILE = NO
INFOPLIST_FILE = CodexUsage/Info.plist
MACOSX_DEPLOYMENT_TARGET = 13.0
MARKETING_VERSION = 1.0.0
PRODUCT_BUNDLE_IDENTIFIER = com.local.CodexUsage
PRODUCT_NAME = "Codex Usage"
SWIFT_STRICT_CONCURRENCY = complete
SWIFT_VERSION = 6.0
```

测试 Target 使用 `com.local.CodexUsageTests`、`TEST_HOST = $(BUILT_PRODUCTS_DIR)/Codex Usage.app/Contents/MacOS/Codex Usage`、`BUNDLE_LOADER = $(TEST_HOST)`，并同样固定 `arm64`、macOS 13 和 Swift 6。项目的 local package reference 必须是相对 `App/CodexUsage.xcodeproj` 的 `../..`，两个 Target 都链接 `UsageCore` product。

- [ ] **Step 2: 写最小但真实可运行的菜单栏入口**

`CodexUsageApp.swift` 先建立可以人工运行的垂直切片，后续任务在同一文件接入 View Model：

```swift
import SwiftUI
import UsageCore

@main
struct CodexUsageApp: App {
    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 12) {
                Text("Codex Usage")
                    .font(.headline)
                Text("正在准备本机用量数据…")
                    .foregroundStyle(.secondary)
                Divider()
                Button("退出 Codex Usage") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(16)
            .frame(width: 410, height: 440, alignment: .topLeading)
            .preferredColorScheme(.dark)
        } label: {
            Text("◔ --")
        }
        .menuBarExtraStyle(.window)
    }
}
```

这不是最终 UI，但必须已具备真实 App Target、菜单栏入口、固定弹窗和退出能力，不能用命令行 executable 或 Swift Package executable 代替。

- [ ] **Step 3: 写 Info.plist 与 asset catalog 元数据**

`Info.plist` 使用以下键；`LSUIElement` 必须是布尔值：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>Codex Usage</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>LSMinimumSystemVersion</key>
    <string>$(MACOSX_DEPLOYMENT_TARGET)</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Codex Usage contributors</string>
</dict>
</plist>
```

`Assets.xcassets/Contents.json` 使用 Xcode asset catalog version 1；`AccentColor.colorset` 提供通用 sRGB `#7568FF`，不创建没有图像内容的 AppIcon set。

- [ ] **Step 4: 写链接冒烟测试**

```swift
import XCTest
import UsageCore

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
```

- [ ] **Step 5: 补齐忽略规则**

在 `.gitignore` 末尾加入：

```gitignore
xcuserdata/
*.xcworkspace/xcuserdata/
```

现有 `DerivedData/`、`*.xcuserstate` 和 `.worktrees/` 规则保持不变。

- [ ] **Step 6: 验证工程、Debug build 和测试 Target**

Run: `rtk xcodebuild -list -project App/CodexUsage.xcodeproj`

Expected: exit 0，列出 `CodexUsage` target、`CodexUsageTests` target 与 `CodexUsage` scheme。

Run: `rtk xcodebuild build -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Debug CODE_SIGNING_ALLOWED=NO`

Expected: `** BUILD SUCCEEDED **`，本地 package 成功解析为 `UsageCore`，无 duplicate Info.plist 或 package product warning。

Run: `rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO`

Expected: `** TEST SUCCEEDED **`，`ProjectSmokeTests` 为 PASS。

- [ ] **Step 7: 提交 Xcode 工程骨架**

```bash
rtk git add .gitignore App/CodexUsage.xcodeproj App/CodexUsage/CodexUsageApp.swift App/CodexUsage/Info.plist App/CodexUsage/Assets.xcassets App/CodexUsageTests/ProjectSmokeTests.swift
rtk git commit -m "[ai] feat(app): 创建菜单栏应用工程"
```

---

### Task 3: 固定展示格式、状态文案和深色主题

**Files:**
- Create: `App/CodexUsage/UsageFormatters.swift`
- Create: `App/CodexUsage/UsageTheme.swift`
- Create: `App/CodexUsageTests/UsageFormattersTests.swift`
- Modify: `App/CodexUsage.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `UsageCalibrationStatus`、`LocalDay`、`Date`、`Int64`、`Double?`。
- Produces: `UsageFormatters` 静态格式化函数和 `UsageTheme` 视觉常量；后续所有页面只使用这些接口，不自行拼接格式。

- [ ] **Step 1: 写失败格式化测试**

使用固定时区 `Asia/Shanghai` 与 `zh_CN`，覆盖边界而不是依赖开发机当前 locale：

```swift
final class UsageFormattersTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    func testRemainingPercentClampsRoundsAndHandlesMissingValue() {
        XCTAssertEqual(UsageFormatters.remainingPercent(nil), "--")
        XCTAssertEqual(UsageFormatters.remainingPercent(-2), "0%")
        XCTAssertEqual(UsageFormatters.remainingPercent(62.4), "62%")
        XCTAssertEqual(UsageFormatters.remainingPercent(99.6), "100%")
        XCTAssertEqual(UsageFormatters.remainingPercent(120), "100%")
    }

    func testMenuBarTitleUsesDataEmptyAndFatalStates() {
        XCTAssertEqual(UsageFormatters.menuBarTitle(remainingPercent: 62.4, isFatal: false), "◔ 62%")
        XCTAssertEqual(UsageFormatters.menuBarTitle(remainingPercent: nil, isFatal: false), "◔ --")
        XCTAssertEqual(UsageFormatters.menuBarTitle(remainingPercent: 62, isFatal: true), "◔ !")
    }

    func testTokensUseCompactStableUnits() {
        XCTAssertEqual(UsageFormatters.tokens(999), "999")
        XCTAssertEqual(UsageFormatters.tokens(1_200), "1.2K")
        XCTAssertEqual(UsageFormatters.tokens(12_000), "12K")
        XCTAssertEqual(UsageFormatters.tokens(1_250_000), "1.3M")
    }

    func testResetCountdownUsesChineseBoundaries() throws {
        let now = try fixedDate("2026-09-01T08:00:00Z")
        XCTAssertEqual(
            UsageFormatters.resetCountdown(
                resetsAt: now.addingTimeInterval(42 * 60),
                now: now
            ),
            "42 分钟后重置"
        )
        XCTAssertEqual(
            UsageFormatters.resetCountdown(
                resetsAt: now.addingTimeInterval(27 * 60 * 60),
                now: now
            ),
            "1 天 3 小时后重置"
        )
        XCTAssertEqual(
            UsageFormatters.resetCountdown(resetsAt: now, now: now),
            "即将重置"
        )
    }

    func testCalibrationLabelsAreExhaustive() {
        XCTAssertEqual(UsageFormatters.calibration(.localLive), "本机实时")
        XCTAssertEqual(UsageFormatters.calibration(.calibrated), "已校准")
        XCTAssertEqual(UsageFormatters.calibration(.partiallyCalibrated), "部分校准")
        XCTAssertEqual(UsageFormatters.calibration(.stale), "数据可能已过期")
        XCTAssertEqual(UsageFormatters.calibration(.unavailable), "暂无数据")
    }
}
```

同一文件补充日期范围、`LocalDay` 的 `M/d`、最后更新时间“刚刚更新 / N 分钟前更新 / M/d HH:mm 更新”测试。`fixedDate` 使用 ISO8601 formatter，不能调用 `Date()`。

- [ ] **Step 2: 运行格式化测试并确认类型缺失**

Run: `rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO -only-testing:CodexUsageTests/UsageFormattersTests`

Expected: FAIL，编译器报告 `UsageFormatters` 不存在。

- [ ] **Step 3: 实现无共享可变 formatter 的确定性格式化**

`UsageFormatters.swift` 的公开面固定为：

```swift
import Foundation
import UsageCore

enum UsageFormatters {
    static func remainingPercent(_ value: Double?) -> String
    static func menuBarTitle(
        remainingPercent: Double?,
        isFatal: Bool
    ) -> String
    static func tokens(_ value: Int64) -> String
    static func resetCountdown(resetsAt: Date, now: Date) -> String
    static func lastUpdated(_ date: Date, now: Date) -> String
    static func day(_ value: LocalDay) -> String
    static func dateTime(
        _ value: Date,
        timeZone: TimeZone,
        locale: Locale = Locale(identifier: "zh_CN")
    ) -> String
    static func cycleRange(
        startsAt: Date,
        endsAt: Date,
        timeZone: TimeZone,
        locale: Locale = Locale(identifier: "zh_CN")
    ) -> String
    static func calibration(_ status: UsageCalibrationStatus) -> String
}
```

Token 规则固定为：绝对值小于 1,000 显示整数；1,000..<1,000,000 使用 K；其余使用 M；小于 10 个单位保留一位并移除 `.0`，其余四舍五入到整数。百分比先夹到 0...100 再按 `.toNearestOrAwayFromZero` 取整。日期函数每次创建局部 `DateFormatter`，避免跨线程共享非 `Sendable` 实例。

- [ ] **Step 4: 集中声明主题，不把数值散落到 View**

`UsageTheme.swift` 定义：

```swift
import SwiftUI

enum UsageTheme {
    static let popoverSize = CGSize(width: 410, height: 440)
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 18
    static let rowSpacing: CGFloat = 10
    static let cornerRadius: CGFloat = 10
    static let transitionDuration = 0.22

    static let background = Color(red: 0.055, green: 0.059, blue: 0.075)
    static let surface = Color.white.opacity(0.045)
    static let border = Color.white.opacity(0.09)
    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.58)
    static let accent = Color(red: 0.46, green: 0.41, blue: 1.0)
    static let accentBlue = Color(red: 0.23, green: 0.58, blue: 1.0)
    static let warning = Color(red: 1.0, green: 0.67, blue: 0.28)
    static let danger = Color(red: 1.0, green: 0.38, blue: 0.42)
}
```

主题只包含共享值；单个 View 一次使用的布局数字留在对应 View，避免为每个数值建立抽象。

- [ ] **Step 5: 更新 project sources 并运行测试**

把两个 App 源文件和测试文件加入对应 PBXSourcesBuildPhase。

Run: `rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO -only-testing:CodexUsageTests/UsageFormattersTests`

Expected: PASS，所有格式化输出与测试字符串完全一致。

- [ ] **Step 6: 提交格式化和主题**

```bash
rtk git add App/CodexUsage.xcodeproj/project.pbxproj App/CodexUsage/UsageFormatters.swift App/CodexUsage/UsageTheme.swift App/CodexUsageTests/UsageFormattersTests.swift
rtk git commit -m "[ai] feat(ui): 固定用量格式和深色主题"
```

---

### Task 4: 保存、恢复和校验 Codex Home bookmark

**Files:**
- Create: `App/CodexUsage/CodexHomeBookmarkStore.swift`
- Create: `App/CodexUsageTests/CodexHomeBookmarkStoreTests.swift`
- Create: `App/CodexUsageTests/TestSupport.swift`
- Modify: `App/CodexUsage.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: 用户选择的目录 URL、`UserDefaults`、security-scoped bookmark API。
- Produces: `CodexHomeBookmarkStoring`、`CodexHomeBookmarkRestoreResult` 和 `CodexHomeBookmarkStore`；View Model 通过这些接口恢复显式 `CODEX_HOME`，退出或换目录时释放访问。

- [ ] **Step 1: 写失败的目录与 bookmark 行为测试**

先在 `TestSupport.swift` 建立不触碰真实用户数据的最小 helper：

```swift
import Foundation
import XCTest
@testable import CodexUsage

func temporaryAppDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodexUsageAppTests-" + UUID().uuidString,
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

func validCodexHome() throws -> URL {
    let root = try temporaryAppDirectory()
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("sessions", isDirectory: true),
        withIntermediateDirectories: true
    )
    return root
}

func fixedDate(_ text: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let value = formatter.date(from: text) { return value }
    formatter.formatOptions = [.withInternetDateTime]
    return try XCTUnwrap(formatter.date(from: text))
}
```

测试使用每个 test 独立的 `UserDefaults(suiteName:)`，通过 `addTeardownBlock` 调用 `removePersistentDomain(forName:)`，并注入 bookmark 编码/解析闭包，不写真实用户 defaults：

```swift
@MainActor
final class CodexHomeBookmarkStoreTests: XCTestCase {
    func testSaveRejectsDirectoryWithoutSessionRoots() throws {
        let root = try temporaryAppDirectory()
        let store = makeBookmarkStore()

        XCTAssertThrowsError(try store.save(root)) { error in
            XCTAssertEqual(error as? CodexHomeBookmarkError, .invalidCodexHome)
        }
    }

    func testDirectoryWithEitherSupportedSessionRootIsValid() throws {
        let sessionsHome = try temporaryAppDirectory()
        try FileManager.default.createDirectory(
            at: sessionsHome.appendingPathComponent("sessions"),
            withIntermediateDirectories: true
        )
        let archivedHome = try temporaryAppDirectory()
        try FileManager.default.createDirectory(
            at: archivedHome.appendingPathComponent("archived_sessions"),
            withIntermediateDirectories: true
        )

        XCTAssertTrue(CodexHomeBookmarkStore.isValidCodexHome(sessionsHome))
        XCTAssertTrue(CodexHomeBookmarkStore.isValidCodexHome(archivedHome))
    }

    func testRestoreReturnsSavedURLAndStartsScopedAccess() throws {
        let root = try validCodexHome()
        var startedURL: URL?
        let store = makeBookmarkStore(
            encode: { _ in Data("bookmark".utf8) },
            resolve: { _ in (root, false) },
            startAccess: { url in startedURL = url; return true }
        )
        try store.save(root)

        XCTAssertEqual(try store.restore(), .available(root.standardizedFileURL))
        XCTAssertEqual(startedURL, root.standardizedFileURL)
    }

    func testStaleBookmarkIsRemovedAndRequestsSelectionAgain() throws {
        let root = try validCodexHome()
        let defaults = isolatedDefaults()
        defaults.set(Data("stale".utf8), forKey: "codexHomeBookmark")
        let store = makeBookmarkStore(
            defaults: defaults,
            resolve: { _ in (root, true) }
        )

        XCTAssertEqual(try store.restore(), .needsSelection)
        XCTAssertNil(defaults.data(forKey: "codexHomeBookmark"))
    }

    func testReleaseStopsOnlyAccessStartedByStore() throws {
        let root = try validCodexHome()
        var stoppedURL: URL?
        let store = makeBookmarkStore(
            resolve: { _ in (root, false) },
            startAccess: { _ in true },
            stopAccess: { stoppedURL = $0 }
        )
        try store.save(root)
        _ = try store.restore()

        store.releaseAccess()

        XCTAssertEqual(stoppedURL, root.standardizedFileURL)
    }
}
```

另加损坏 bookmark、解析出的 URL 不再含 session 根目录，以及重复 `releaseAccess()` 不重复 stop 的测试。

- [ ] **Step 2: 运行定向测试并确认 store 缺失**

Run: `rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO -only-testing:CodexUsageTests/CodexHomeBookmarkStoreTests`

Expected: FAIL，编译器报告 bookmark 类型不存在。

- [ ] **Step 3: 实现主线程隔离的最小 bookmark store**

公开面固定为：

```swift
import Foundation

enum CodexHomeBookmarkError: Error, Equatable {
    case invalidCodexHome
    case bookmarkCreationFailed
    case bookmarkResolutionFailed
}

enum CodexHomeBookmarkRestoreResult: Equatable {
    case available(URL)
    case needsSelection
}

@MainActor
protocol CodexHomeBookmarkStoring: AnyObject {
    func restore() throws -> CodexHomeBookmarkRestoreResult
    func save(_ url: URL) throws
    func clear()
    func releaseAccess()
}

@MainActor
final class CodexHomeBookmarkStore: CodexHomeBookmarkStoring {
    static func isValidCodexHome(_ url: URL) -> Bool

    init(
        defaults: UserDefaults = .standard,
        key: String = "codexHomeBookmark"
    )

    func restore() throws -> CodexHomeBookmarkRestoreResult
    func save(_ url: URL) throws
    func clear()
    func releaseAccess()
}
```

生产编码使用 `url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)`；解析使用 `URL(resolvingBookmarkData:options:.withSecurityScope,relativeTo:nil,bookmarkDataIsStale:&isStale)`。只有 `startAccessingSecurityScopedResource()` 返回 true 时才记录 active URL；stale、损坏或目录失效时删除 defaults 数据并返回 `.needsSelection`。`clear()` 同时释放 active access。

闭包注入 initializer 仅设为 internal，供 `@testable import CodexUsage` 使用，签名固定为 `init(defaults:key:encode:resolve:startAccess:stopAccess:)`；`encode` 返回 `Data`，`resolve` 返回 `(url: URL, isStale: Bool)`，两个 access 闭包分别返回 `Bool` 和 `Void`。生产 initializer 保持上面的简洁签名。

- [ ] **Step 4: 运行 bookmark 测试**

Run: `rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO -only-testing:CodexUsageTests/CodexHomeBookmarkStoreTests`

Expected: PASS；测试 defaults 在 `tearDown` 中清空，且不会留下真实 security-scope 访问。

- [ ] **Step 5: 提交目录权限持久化**

```bash
rtk git add App/CodexUsage.xcodeproj/project.pbxproj App/CodexUsage/CodexHomeBookmarkStore.swift App/CodexUsageTests/CodexHomeBookmarkStoreTests.swift App/CodexUsageTests/TestSupport.swift
rtk git commit -m "[ai] feat(app): 保存 Codex Home 目录授权"
```

---

### Task 5: 组装真实 UsageCore runtime 并保证可关闭

**Files:**
- Create: `App/CodexUsage/UsageRuntime.swift`
- Create: `App/CodexUsage/AppContainer.swift`
- Create: `App/CodexUsageTests/AppContainerTests.swift`
- Modify: `App/CodexUsageTests/TestSupport.swift`
- Modify: `App/CodexUsage.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `CodexAppServerClient`、`ProcessJSONLTransport`、`SessionUsageIndexer`、`SQLiteUsageStore`、`UsageService`、`SessionDirectoryWatcher`。
- Produces: App 层的 `UsageServicing`、`SessionChangeWatching`、`UsageRuntime`、`UsageRuntimeBuilding` 和 live `AppContainer`。

- [ ] **Step 1: 写失败的 runtime 组装测试**

`TestSupport.swift` 在 Task 4 的 helper 基础上增加 `utcCalendar()`、下面的 session 行工厂和固定 `UsageSnapshot` 工厂，后续 App 测试复用：

```swift
func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

func tokenJSONLine(
    timestamp: String = "2026-09-01T08:00:00.000Z",
    input: Int64,
    cached: Int64,
    output: Int64
) throws -> String {
    let value: [String: Any] = [
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": [
            "type": "token_count",
            "info": [
                "last_token_usage": [
                    "input_tokens": input,
                    "cached_input_tokens": cached,
                    "output_tokens": output,
                    "reasoning_output_tokens": 0
                ]
            ]
        ]
    ]
    let data = try JSONSerialization.data(
        withJSONObject: value,
        options: [.sortedKeys]
    )
    return String(decoding: data, as: UTF8.self)
}
```

`sampleSnapshot(...)` 使用固定 `2026-09-01T08:00:00Z`、62% 剩余、today 120 tokens、7 个自然日和 current+8 cycles；可选参数只替换测试明确需要的 status、remainingPercent、today、recent days/statuses 和 completed cycle count。`AppContainerTests` 覆盖数据库路径和没有 codex executable 时仍能读取本地 session 的降级路径：

```swift
final class AppContainerTests: XCTestCase {
    func testDatabaseURLUsesApplicationSupportCodexUsageDirectory() {
        let support = URL(fileURLWithPath: "/tmp/test-support", isDirectory: true)

        XCTAssertEqual(
            AppContainer.databaseURL(applicationSupport: support),
            support
                .appendingPathComponent("Codex Usage", isDirectory: true)
                .appendingPathComponent("usage.sqlite")
        )
    }

    func testRuntimeWithoutExecutableStillIndexesExplicitCodexHome() async throws {
        let support = try temporaryAppDirectory()
        let codexHome = try validCodexHome()
        try Data(
            (tokenJSONLine(input: 100, cached: 40, output: 20) + "\n").utf8
        ).write(
            to: codexHome
                .appendingPathComponent("sessions")
                .appendingPathComponent("local.jsonl")
        )
        let container = AppContainer(
            applicationSupport: support,
            homeDirectory: try temporaryAppDirectory(),
            environment: [:],
            executableURL: nil,
            calendar: utcCalendar()
        )
        let runtime = try await container.makeRuntime(codexHome: codexHome)
        let snapshot: UsageSnapshot
        do {
            snapshot = try await runtime.service.refresh(
                reason: .startup,
                now: try fixedDate("2026-09-01T08:00:00Z")
            )
        } catch {
            await runtime.stop()
            throw error
        }

        XCTAssertEqual(snapshot.today.localUsage.totalTokens, 120)
        XCTAssertEqual(snapshot.status, .stale)
        XCTAssertEqual(
            await runtime.service.resolvedCodexHome(),
            codexHome.standardizedFileURL
        )
        await runtime.stop()
    }

    func testRuntimeStopGateRunsCleanupOnlyOnce() async {
        let gate = RuntimeStopGate()
        let recorder = StopRecorder()

        await gate.run { await recorder.record() }
        await gate.run { await recorder.record() }

        XCTAssertEqual(await recorder.count, 1)
    }
}
```

测试文件中的 `StopRecorder` 是只有 `record()` 和只读 `count` 的 actor。`RuntimeStopGate` 保持 internal，live runtime 的 stop closure 必须通过它调用 watcher/client/store 清理；生产 `UsageRuntime` 不公开 SQLite，也不为测试新增 store probe API。

- [ ] **Step 2: 运行定向测试并确认 runtime 类型缺失**

Run: `rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO -only-testing:CodexUsageTests/AppContainerTests`

Expected: FAIL，编译器报告 `AppContainer`、`UsageRuntime` 和 App 层协议不存在。

- [ ] **Step 3: 定义 App 实际使用的最小 actor 协议**

`UsageRuntime.swift` 使用以下精确接口：

```swift
import Foundation
import UsageCore

protocol UsageServicing: Actor {
    func refresh(reason: RefreshReason, now: Date) async throws -> UsageSnapshot
    func processNextAccountNotification(now: Date) async throws -> UsageSnapshot?
    func currentSnapshot(now: Date) async throws -> UsageSnapshot
    func resolvedCodexHome() async -> URL?
}

extension UsageService: UsageServicing {}

protocol SessionChangeWatching: Actor {
    func changes(for directories: [URL]) async -> AsyncStream<Void>
    func stop() async
}

extension SessionDirectoryWatcher: SessionChangeWatching {}

struct UsageRuntime: Sendable {
    let service: any UsageServicing
    let watcher: any SessionChangeWatching
    private let stopAction: @Sendable () async -> Void

    init(
        service: any UsageServicing,
        watcher: any SessionChangeWatching,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.service = service
        self.watcher = watcher
        stopAction = stop
    }

    func stop() async {
        await stopAction()
    }
}

protocol UsageRuntimeBuilding: Sendable {
    func makeRuntime(codexHome: URL?) async throws -> UsageRuntime
}
```

如果 Swift 6 对 actor protocol requirement 的显式 `async` 适配提出诊断，以编译器要求为准统一在 protocol 与 conformer 上保留 `async`，不得用 `@unchecked Sendable` 消除诊断。

- [ ] **Step 4: 实现 live container 和不可用 app-server transport**

`AppContainer` 使用以下接口，并保存 immutable 的 application support、home、environment、calendar 和可选 executable URL：

```swift
struct AppContainer: UsageRuntimeBuilding {
    static func live() -> AppContainer
    static func databaseURL(applicationSupport: URL) -> URL
    func makeRuntime(codexHome: URL?) async throws -> UsageRuntime
}
```

`live()` 使用 `FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!`、`FileManager.default.homeDirectoryForCurrentUser`、`ProcessInfo.processInfo.environment`，并通过现有 `CodexExecutableResolver` 解析 executable。

`makeRuntime(codexHome:)` 必须按以下顺序组装：

```swift
let databaseURL = Self.databaseURL(applicationSupport: applicationSupport)
try fileManager.createDirectory(
    at: databaseURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
let store = try SQLiteUsageStore(databaseURL: databaseURL)
let transport: any AppServerTransport = executableURL.map {
    ProcessJSONLTransport(executableURL: $0, arguments: ["app-server"])
} ?? UnavailableAppServerTransport()
let client = CodexAppServerClient(transport: transport)
let indexer = SessionUsageIndexer(store: store)
var runtimeEnvironment = environment
if let codexHome {
    runtimeEnvironment["CODEX_HOME"] = codexHome.standardizedFileURL.path
}
let service = UsageService(
    accountClient: client,
    indexer: indexer,
    store: store,
    environment: runtimeEnvironment,
    homeDirectory: homeDirectory,
    calendar: calendar
)
let watcher = SessionDirectoryWatcher()
```

`UnavailableAppServerTransport` 是 App Target 内 private actor，并严格遵循 `AppServerTransport`：`start() async throws` 与 `send(line:) async throws` 抛出固定 `AppRuntimeError.codexExecutableNotFound`，`nextLine() async throws -> Data?` 返回 nil，`stop() async` 无副作用。这样 app-server 缺失只让远端来源 stale，不阻断显式或 `~/.codex` 的本地索引。

stop closure 用下面的 internal gate 保证幂等：

```swift
actor RuntimeStopGate {
    private var didStop = false

    func run(_ cleanup: @Sendable () async -> Void) async {
        guard !didStop else { return }
        didStop = true
        await cleanup()
    }
}
```

cleanup 严格执行：watcher stop → client stop → store close。close 错误不输出路径、SQL 或数据内容。

- [ ] **Step 5: 运行 container 与核心回归测试**

Run: `rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO -only-testing:CodexUsageTests/AppContainerTests`

Expected: PASS，真实临时 SQLite 写入成功，无 executable 时本地 120 tokens 仍可展示并标 stale，重复 stop 安全。

Run: `rtk swift test`

Expected: PASS，UsageCore 全套回归保持通过。

- [ ] **Step 6: 提交依赖组装层**

```bash
rtk git add App/CodexUsage.xcodeproj/project.pbxproj App/CodexUsage/UsageRuntime.swift App/CodexUsage/AppContainer.swift App/CodexUsageTests/AppContainerTests.swift App/CodexUsageTests/TestSupport.swift
rtk git commit -m "[ai] feat(app): 组装本地用量运行环境"
```

---

### Task 6: 实现可测试的 View Model 基础状态与刷新入口

**Files:**
- Create: `App/CodexUsage/UsageViewModel.swift`
- Create: `App/CodexUsageTests/UsageViewModelTests.swift`
- Modify: `App/CodexUsage.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `UsageRuntimeBuilding`、`CodexHomeBookmarkStoring`、`UsageSnapshot`、`RefreshReason` 和注入的当前时间/目录选择/睡眠闭包。
- Produces: `UsageViewModel` 的快照、加载/刷新/过期/致命/选目录状态，菜单栏标题，刷新入口和页面导航。

- [ ] **Step 1: 写失败的基础状态测试**

测试 fake 接收真实 `RefreshReason`，再映射为可比较的测试枚举；不要为了测试给 `UsageCore.RefreshReason` 增加设计之外的公开 conformance：

```swift
enum RecordedRefreshReason: Equatable {
    case startup
    case scheduled
    case popoverOpened
    case wake
    case sessionFilesChanged
    case manual

    init(_ reason: RefreshReason) {
        switch reason {
        case .startup: self = .startup
        case .scheduled: self = .scheduled
        case .popoverOpened: self = .popoverOpened
        case .wake: self = .wake
        case .sessionFilesChanged: self = .sessionFilesChanged
        case .manual: self = .manual
        }
    }
}
```

`FakeUsageService.reasons() -> [RecordedRefreshReason]` 返回记录结果，并提供 `waitForReason(_ value: RecordedRefreshReason) async`。状态测试如下：

```swift
@MainActor
final class UsageViewModelTests: XCTestCase {
    func testStartPublishesSnapshotAndResolvedHome() async throws {
        let snapshot = try sampleSnapshot(status: .calibrated)
        let fixture = ViewModelFixture(snapshot: snapshot)

        await fixture.viewModel.start()

        XCTAssertEqual(fixture.viewModel.snapshot, snapshot)
        XCTAssertFalse(fixture.viewModel.isInitialLoading)
        XCTAssertFalse(fixture.viewModel.needsCodexHomeSelection)
        XCTAssertNil(fixture.viewModel.fatalErrorMessage)
        XCTAssertEqual(fixture.viewModel.menuBarTitle, "◔ 62%")
        XCTAssertEqual(await fixture.service.reasons(), [.startup])
    }

    func testStaleSnapshotKeepsContentAndShowsCompactWarning() async throws {
        let snapshot = try sampleSnapshot(status: .stale)
        let fixture = ViewModelFixture(snapshot: snapshot)

        await fixture.viewModel.start()

        XCTAssertEqual(fixture.viewModel.snapshot, snapshot)
        XCTAssertTrue(fixture.viewModel.isStale)
        XCTAssertNil(fixture.viewModel.fatalErrorMessage)
    }

    func testSQLiteFailureShowsFatalStateWithoutDeletingDatabase() async throws {
        let fixture = ViewModelFixture(
            refreshError: SQLiteStoreError.operationFailed(
                operation: "migrate",
                code: 11
            )
        )

        await fixture.viewModel.start()

        XCTAssertNil(fixture.viewModel.snapshot)
        XCTAssertEqual(fixture.viewModel.menuBarTitle, "◔ !")
        XCTAssertEqual(fixture.viewModel.fatalErrorMessage, "本地用量数据库无法使用。请重试；应用不会自动删除现有数据。")
        XCTAssertEqual(fixture.runtimeBuilder.buildCount, 1)
    }

    func testMissingHomeAutomaticallyAsksOnlyOnceThenKeepsGuide() async throws {
        let fixture = ViewModelFixture(resolvedHome: nil, chosenHome: nil)

        await fixture.viewModel.start()
        await fixture.viewModel.openPopover()

        XCTAssertTrue(fixture.viewModel.needsCodexHomeSelection)
        XCTAssertEqual(fixture.chooser.callCount, 1)
    }

    func testExplicitActionsMapToRefreshReasonsAndNavigation() async throws {
        let fixture = ViewModelFixture(snapshot: try sampleSnapshot())
        await fixture.viewModel.start()

        await fixture.viewModel.openPopover()
        await fixture.viewModel.handleWake()
        await fixture.viewModel.refreshManually()
        fixture.viewModel.showTrend()
        XCTAssertEqual(fixture.viewModel.page, .trend)
        fixture.viewModel.showHistory()
        XCTAssertEqual(fixture.viewModel.page, .history)
        fixture.viewModel.showOverview()

        XCTAssertEqual(
            await fixture.service.reasons(),
            [.startup, .popoverOpened, .wake, .manual]
        )
        XCTAssertEqual(fixture.viewModel.page, .overview)
    }
}
```

另加测试：非 SQLite 错误保留旧快照、没有旧快照时显示无数据而非致命；手动刷新期间 `isRefreshing=true`；较旧 refresh 序号晚完成时不能覆盖较新结果。

- [ ] **Step 2: 运行 View Model 测试并确认类型缺失**

Run: `rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO -only-testing:CodexUsageTests/UsageViewModelTests`

Expected: FAIL，编译器报告 `UsageViewModel` 和相关状态类型不存在。

- [ ] **Step 3: 定义稳定的 UI 状态与可注入环境**

`UsageViewModel.swift` 的基础接口固定为：

```swift
import AppKit
import Combine
import Foundation
import UsageCore

enum UsagePage: Hashable {
    case overview
    case trend
    case history
}

struct UsageViewModelEnvironment: Sendable {
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void

    static let live = UsageViewModelEnvironment(
        now: Date.init,
        sleep: { try await Task.sleep(for: $0) }
    )
}

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isInitialLoading = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var needsCodexHomeSelection = false
    @Published private(set) var fatalErrorMessage: String?
    @Published private(set) var page: UsagePage = .overview

    var isStale: Bool { snapshot?.status == .stale }
    var menuBarTitle: String {
        UsageFormatters.menuBarTitle(
            remainingPercent: snapshot?.quota?.remainingPercent,
            isFatal: fatalErrorMessage != nil
        )
    }

    init(
        runtimeBuilder: any UsageRuntimeBuilding,
        bookmarkStore: any CodexHomeBookmarkStoring,
        chooseCodexHome: @escaping @MainActor () async -> URL?,
        environment: UsageViewModelEnvironment = .live,
        refreshPolicy: RefreshPolicy = RefreshPolicy()
    )

    func start() async
    func openPopover() async
    func handleWake() async
    func refreshManually() async
    func chooseCodexHome() async
    func retryFatalError() async
    func showOverview()
    func showTrend()
    func showHistory()
    func stop() async
}
```

`menuBarTitle` 使用 `UsageFormatters.menuBarTitle`；fatal 永远优先于剩余百分比。`fatalErrorMessage` 只能放固定中文分类，不直接插入 `error.localizedDescription`，避免泄漏路径、SQL 或进程输出。

- [ ] **Step 4: 实现启动、显式动作和顺序保护**

`start()` 用 guard 保证一次启动：恢复 bookmark → 构建 runtime → `.startup` refresh → 发布 snapshot → 查询 `resolvedCodexHome()`。没有目录且没有快照时调用一次自动 chooser；取消选择后保留 `needsCodexHomeSelection=true`，`openPopover()` 不再自动弹第二次。

统一内部入口：

```swift
private func refresh(reason: RefreshReason) async {
    let requestID = nextRefreshID
    nextRefreshID += 1
    activeRefreshCount += 1
    isRefreshing = !isInitialLoading
    defer {
        activeRefreshCount -= 1
        isRefreshing = activeRefreshCount > 0 && !isInitialLoading
    }

    do {
        let value = try await runtime.service.refresh(
            reason: reason,
            now: environment.now()
        )
        guard requestID >= lastAppliedRefreshID else { return }
        lastAppliedRefreshID = requestID
        snapshot = value
        fatalErrorMessage = nil
    } catch is CancellationError {
        return
    } catch is SQLiteStoreError {
        fatalErrorMessage = Self.databaseFailureMessage
    } catch {
        // UsageCore 保留的旧快照继续显示；无旧值时进入非致命无数据状态。
    }
}
```

选择成功必须先通过 `CodexHomeBookmarkStore.isValidCodexHome`，保存 bookmark，停止旧 runtime，使用选中 URL 重建，然后执行 `.startup`。停止完成前不得创建新 store，避免两个 SQLite runtime 同时访问同一文件。

- [ ] **Step 5: 运行基础状态测试**

Run: `rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO -only-testing:CodexUsageTests/UsageViewModelTests`

Expected: PASS，所有状态转换、刷新原因、目录选择一次性行为和 refresh 顺序保护通过；测试结束主动调用 `stop()`，无悬挂 Task。

- [ ] **Step 6: 提交 View Model 基础状态机**

```bash
rtk git add App/CodexUsage.xcodeproj/project.pbxproj App/CodexUsage/UsageViewModel.swift App/CodexUsageTests/UsageViewModelTests.swift
rtk git commit -m "[ai] feat(app): 管理用量界面状态"
```

---

### Task 7: 接入定时、FSEvents、账户通知、退避重连和退出取消

**Files:**
- Modify: `App/CodexUsage/UsageViewModel.swift`
- Modify: `App/CodexUsageTests/UsageViewModelTests.swift`
- Modify: `App/CodexUsageTests/TestSupport.swift`

**Interfaces:**
- Consumes: Task 6 的 `UsageViewModel`、`UsageRuntime`、`SessionChangeWatching` 和 `RefreshPolicy.retryDelay`。
- Produces: 启动后 60 秒调度、session 目录流、账户通知流、30 秒至 15 分钟重连、可验证的完整停止行为。

- [ ] **Step 1: 写失败的后台生命周期测试**

用 `ControlledSleeper` actor 保存请求的 `Duration` 并由测试显式 resume；不让测试真实等待 30 或 60 秒：

```swift
func testScheduledLoopRefreshesEverySixtySeconds() async throws {
    let fixture = ViewModelFixture(snapshot: try sampleSnapshot())
    await fixture.viewModel.start()

    await fixture.sleeper.resumeNext(expected: .seconds(60))
    await fixture.service.waitForReason(.scheduled)

    XCTAssertTrue(await fixture.service.reasons().contains(.scheduled))
}

func testSessionChangeMapsToLocalOnlyReason() async throws {
    let fixture = ViewModelFixture(snapshot: try sampleSnapshot())
    await fixture.viewModel.start()

    await fixture.watcher.sendChange()
    await fixture.service.waitForReason(.sessionFilesChanged)

    XCTAssertEqual(await fixture.service.reasons().last, .sessionFilesChanged)
}

func testNotificationSnapshotPublishesWithoutFullRefresh() async throws {
    let updated = try sampleSnapshot(remainingPercent: 48)
    let fixture = ViewModelFixture(snapshot: try sampleSnapshot())
    await fixture.service.enqueueNotification(updated)
    await fixture.viewModel.start()
    await fixture.viewModel.waitUntilSnapshotEquals(updated)

    XCTAssertEqual(fixture.viewModel.menuBarTitle, "◔ 48%")
}

func testNotificationEOFBacksOffThenBuildsFreshRuntime() async throws {
    let fixture = ViewModelFixture(
        snapshot: try sampleSnapshot(),
        notificationResults: [nil]
    )
    await fixture.viewModel.start()
    await fixture.sleeper.waitForRequest(.seconds(30))

    XCTAssertEqual(fixture.runtimeBuilder.buildCount, 1)
    await fixture.sleeper.resumeNext(expected: .seconds(30))
    await fixture.runtimeBuilder.waitForBuildCount(2)

    XCTAssertEqual(fixture.runtimeBuilder.buildCount, 2)
    XCTAssertEqual(fixture.runtimeBuilder.stopCount, 1)
}

func testRepeatedNotificationEOFUsesCappedRefreshPolicyBackoff() async throws {
    let fixture = ViewModelFixture(
        snapshot: try sampleSnapshot(),
        everyNotificationEnds: true
    )
    await fixture.viewModel.start()

    for expected in [30, 60, 120, 240, 480, 900, 900] {
        await fixture.sleeper.resumeNext(expected: .seconds(expected))
    }

    XCTAssertEqual(
        Array(await fixture.sleeper.requestedDurations().suffix(7)),
        [.seconds(30), .seconds(60), .seconds(120), .seconds(240), .seconds(480), .seconds(900), .seconds(900)]
    )
}

func testStopCancelsLoopsStopsWatcherRuntimeAndBookmarkAccess() async throws {
    let fixture = ViewModelFixture(snapshot: try sampleSnapshot())
    await fixture.viewModel.start()

    await fixture.viewModel.stop()
    await fixture.watcher.sendChange()

    XCTAssertEqual(fixture.runtimeBuilder.stopCount, 1)
    XCTAssertEqual(fixture.bookmarkStore.releaseCount, 1)
    XCTAssertEqual(await fixture.service.reasons(), [.startup])
}
```

另加测试：1 秒内 fake watcher 多次 yield 只按 watcher 输出消费；新目录选择取消旧调度/通知/watcher；手动刷新可在退避期间立即运行；成功通知或刷新把 EOF failure count 归零；`start()` 重复调用不会复制 loop。

- [ ] **Step 2: 运行后台测试并确认循环尚未实现**

Run: `rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO -only-testing:CodexUsageTests/UsageViewModelTests`

Expected: FAIL，scheduled/session/notification 断言超时或 build count 不符。

- [ ] **Step 3: 启动 watcher、60 秒调度和通知消费者**

首次 refresh 后只对实际存在的目录启动 watcher：

```swift
private func watchedDirectories(for codexHome: URL) -> [URL] {
    ["sessions", "archived_sessions"]
        .map { codexHome.appendingPathComponent($0, isDirectory: true) }
        .filter { url in
            var isDirectory = ObjCBool(false)
            return FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        }
}
```

三类 long-lived Task 都保存在 View Model：

```swift
schedulerTask = Task { [weak self] in
    while !Task.isCancelled {
        try await self?.environment.sleep(.seconds(60))
        guard !Task.isCancelled else { return }
        await self?.refresh(reason: .scheduled)
    }
}

watcherTask = Task { [weak self] in
    let stream = await runtime.watcher.changes(for: directories)
    for await _ in stream {
        guard !Task.isCancelled else { return }
        await self?.refresh(reason: .sessionFilesChanged)
    }
}

notificationTask = Task { [weak self] in
    await self?.consumeAccountNotifications(runtimeID: runtimeID)
}
```

Swift 6 若禁止从 `@MainActor` 闭包直接跨隔离读取环境，先把 immutable `sleep` closure、runtime 和 ID 复制到局部常量，再创建 Task；不得把整个 View Model 标记 `@unchecked Sendable`。

- [ ] **Step 4: 实现 EOF/错误重建与指数退避**

`processNextAccountNotification` 返回 snapshot 时按 Task 6 的 request ID 规则发布。返回 nil 或抛出非 SQLite 错误时先用当前 `notificationFailureCount` 调用 `RefreshPolicy.retryDelay(consecutiveFailures:)`，再把计数加一；因此第一次等待 30 秒，之后依次为 60、120、240、480、900、900 秒。sleep 后停止旧 runtime、用当前 bookmark URL 创建新 runtime、执行 `.startup`，再启动三类 loop。

每次安装 runtime 生成递增 `runtimeID`。任何 loop 发布前检查 ID 仍匹配，避免旧 runtime 的延迟结果覆盖新目录结果。成功通知或成功且非 stale 的刷新将 `notificationFailureCount` 清零。SQLite 错误进入 fatal 状态且不自动重建数据库。

- [ ] **Step 5: 实现统一取消与幂等 stop**

`stopBackgroundTasks()` 先 cancel scheduler、watcher、notification、retry tasks，再把属性置 nil，随后 `await runtime.stop()`。`stop()` 用 guard 幂等，最后调用 `bookmarkStore.releaseAccess()`。换目录复用同一停止顺序，但不把整个 View Model 标记为永久 stopped。

- [ ] **Step 6: 运行后台测试和 Thread Sanitizer 友好的普通测试**

Run: `rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO -only-testing:CodexUsageTests/UsageViewModelTests`

Expected: PASS；所有 controlled sleep 都被测试释放或在 tearDown cancel，无测试进程悬挂、无 continuation leak warning。

Run: `rtk xcodebuild build -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Debug CODE_SIGNING_ALLOWED=NO`

Expected: `** BUILD SUCCEEDED **`，Swift 6 complete concurrency 下无 actor isolation warning。

- [ ] **Step 7: 提交后台刷新生命周期**

```bash
rtk git add App/CodexUsage/UsageViewModel.swift App/CodexUsageTests/UsageViewModelTests.swift App/CodexUsageTests/TestSupport.swift
rtk git commit -m "[ai] feat(app): 接入自动刷新和安全重连"
```

---

### Task 8: 建立展示模型并完成概览页

**Files:**
- Create: `App/CodexUsage/UsagePresentation.swift`
- Create: `App/CodexUsage/UsagePopoverView.swift`
- Create: `App/CodexUsage/OverviewView.swift`
- Create: `App/CodexUsageTests/UsagePresentationTests.swift`
- Modify: `App/CodexUsage.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `UsageSnapshot`、`UsageViewModel` 动作、`UsageFormatters` 和 `UsageTheme`。
- Produces: `OverviewPresentation`、popover 的加载/选目录/致命/content 状态，以及完整概览页。

- [ ] **Step 1: 写失败的概览展示口径测试**

```swift
final class UsagePresentationTests: XCTestCase {
    func testOverviewKeepsTodayTotalPrimaryAndCacheAsInputSubset() throws {
        let snapshot = try sampleSnapshot(
            today: TokenBreakdown(
                inputTokens: 100,
                cachedInputTokens: 80,
                outputTokens: 20
            )
        )

        let presentation = OverviewPresentation(
            snapshot: snapshot,
            now: try fixedDate("2026-09-01T08:00:00Z"),
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )

        XCTAssertEqual(presentation.todayTotal, "120")
        XCTAssertEqual(presentation.inputTokens, "100")
        XCTAssertEqual(presentation.cachedInputTokens, "80")
        XCTAssertEqual(presentation.outputTokens, "20")
        XCTAssertEqual(presentation.additiveSegments.map(\.value), [100, 20])
    }

    func testOverviewMapsQuotaCycleAndStaleState() throws {
        let presentation = OverviewPresentation(
            snapshot: try sampleSnapshot(status: .stale),
            now: try fixedDate("2026-09-01T08:00:00Z"),
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )

        XCTAssertEqual(presentation.remainingPercent, "62%")
        XCTAssertEqual(presentation.progress, 0.62, accuracy: 0.001)
        XCTAssertEqual(presentation.staleMessage, "数据可能已过期")
        XCTAssertFalse(presentation.currentCycleTokens.isEmpty)
    }
}
```

再测试 quota 缺失、current cycle 缺失、进度夹值和最后更新时间。`additiveSegments` 只允许 input 与 output；cache 只能作为 `cachedInputTokens` 文字明细。

- [ ] **Step 2: 运行展示测试并确认 presentation 缺失**

Run: `rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO -only-testing:CodexUsageTests/UsagePresentationTests`

Expected: FAIL，编译器报告 `OverviewPresentation` 不存在。

- [ ] **Step 3: 实现只读 OverviewPresentation**

`UsagePresentation.swift` 定义不可变、`Equatable`、不持有 service 的值类型：

```swift
struct UsageSegment: Equatable, Identifiable {
    let id: String
    let label: String
    let value: Int64
    let formattedValue: String
}

struct OverviewPresentation: Equatable {
    let remainingPercent: String
    let progress: Double
    let resetCountdown: String
    let todayTotal: String
    let inputTokens: String
    let cachedInputTokens: String
    let outputTokens: String
    let additiveSegments: [UsageSegment]
    let currentCycleTokens: String
    let currentCycleStatus: String
    let staleMessage: String?
    let lastUpdated: String

    init(snapshot: UsageSnapshot, now: Date, timeZone: TimeZone)
}
```

`progress = clamp(remainingPercent / 100, 0...1)`；quota/currentCycle 缺失时使用 `--` 和“暂无数据”，不得自行估算。

- [ ] **Step 4: 实现 popover 状态壳**

`UsagePopoverView` 使用 `@ObservedObject var viewModel`，根视图固定 `.frame(width: 410, height: 440)`、`.background(UsageTheme.background)`、`.preferredColorScheme(.dark)`。状态优先级固定为：fatal → initial loading → needs selection 且无 snapshot → content。

加载页显示 `ProgressView` 和“正在读取本机用量…”；目录页显示解释文字与“选择 Codex Home”按钮；fatal 页显示固定错误文案与“重试”按钮，不提供删除数据库按钮。所有按钮调用 View Model 的 async 方法时使用短生命周期 `Task`。

- [ ] **Step 5: 实现概览页的明确视觉层级**

`OverviewView` 接收 presentation 与五个动作闭包：刷新、趋势、历史、选择目录（仅在过期授权提示时显示）、退出。布局从上到下固定为：

```text
Codex Usage + stale/refresh 状态 + 刷新按钮
细紫蓝渐变线
周额度剩余大数字 + 重置倒计时 + 细进度条
今日 Token 主数字
输入 / 缓存输入 / 输出三个小号明细
分隔线
当前周期 Token + 校准状态
最近 7 天 >    历史周期 >
最后更新时间                       退出
```

具体 SwiftUI 要点：

```swift
VStack(alignment: .leading, spacing: UsageTheme.sectionSpacing) {
    header
    quotaSection
    todaySection
    Divider().overlay(UsageTheme.border)
    cycleSection
    navigationRow
    Spacer(minLength: 0)
    footer
}
.padding(UsageTheme.pagePadding)
```

周额度使用 38pt semibold，今日 Token 使用 30pt semibold，三个明细使用 12pt secondary。进度条高度 4pt，只对已剩余比例使用紫蓝渐变。页面不得把四个 Token 数字做成四张同级卡片。

在 `UsagePresentation.swift` 的 `#if DEBUG` 区域定义 `enum UsagePreviewData`，提供固定时间与 `fullSnapshot`、`staleSnapshot`、`snapshotWithoutQuota` 三个纯值。给 `OverviewView` 加三项 `#Preview`，Task 9 再给趋势与历史各加一项。Preview 只能使用这些内存值，不得调用测试 Target 的 `sampleSnapshot`，也不得启动 app-server、SQLite 或 watcher；加载、无数据和 fatal 状态通过 Task 8 的可构建状态分支及 Task 11 人工验收覆盖。

- [ ] **Step 6: 运行展示测试与 Debug build**

Run: `rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO -only-testing:CodexUsageTests/UsagePresentationTests`

Expected: PASS，今日 120 不会错误显示为 200，cache 始终只作为输入子集明细。

Run: `rtk xcodebuild build -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Debug CODE_SIGNING_ALLOWED=NO`

Expected: `** BUILD SUCCEEDED **`，全部 Preview 可编译，无布局或 Charts 依赖错误。

- [ ] **Step 7: 提交概览体验**

```bash
rtk git add App/CodexUsage.xcodeproj/project.pbxproj App/CodexUsage/UsagePresentation.swift App/CodexUsage/UsagePopoverView.swift App/CodexUsage/OverviewView.swift App/CodexUsageTests/UsagePresentationTests.swift
rtk git commit -m "[ai] feat(ui): 实现用量概览界面"
```

---

### Task 9: 完成 7 天趋势、周期历史和同窗转场

**Files:**
- Create: `App/CodexUsage/TrendDetailView.swift`
- Create: `App/CodexUsage/CycleHistoryView.swift`
- Modify: `App/CodexUsage/UsagePresentation.swift`
- Modify: `App/CodexUsage/UsagePopoverView.swift`
- Modify: `App/CodexUsageTests/UsagePresentationTests.swift`
- Modify: `App/CodexUsageTests/UsageViewModelTests.swift`
- Modify: `App/CodexUsage.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `UsageSnapshot.recentDays`、`currentCycle`、`cycleHistory` 和 `UsageViewModel.page`。
- Produces: `TrendPresentation`、`CycleHistoryPresentation`、Charts 柱状趋势、最多 9 个周期条目，以及减少动态效果下的无动画路由。

- [ ] **Step 1: 写失败的趋势与周期口径测试**

```swift
func testTrendUsesSevenMostRecentDaysAndComputesAverage() throws {
    let snapshot = try sampleSnapshot(
        recentDayTotals: [100, 200, 300, 400, 500, 600, 700, 800]
    )

    let trend = TrendPresentation(snapshot: snapshot)

    XCTAssertEqual(trend.days.map(\.tokens), [200, 300, 400, 500, 600, 700, 800])
    XCTAssertEqual(trend.totalTokens, 3_500)
    XCTAssertEqual(trend.averageTokens, 500)
}

func testTrendRetainsPerDayCalibrationStatus() throws {
    let snapshot = try sampleSnapshot(
        recentStatuses: [.calibrated, .partiallyCalibrated, .localLive]
    )

    XCTAssertEqual(
        TrendPresentation(snapshot: snapshot).days.suffix(3).map(\.status),
        [.calibrated, .partiallyCalibrated, .localLive]
    )
}

func testCycleHistoryContainsCurrentThenEightCompletedCycles() throws {
    let snapshot = try sampleSnapshot(completedCycleCount: 10)

    let history = CycleHistoryPresentation(
        snapshot: snapshot,
        timeZone: TimeZone(identifier: "Asia/Shanghai")!
    )

    XCTAssertEqual(history.entries.count, 9)
    XCTAssertTrue(history.entries[0].isCurrent)
    XCTAssertTrue(history.entries.dropFirst().allSatisfy { !$0.isCurrent })
}
```

另加测试：recentDays 少于 7 天时不补假数据；0 天平均值为 0；周期历史按结束时间从新到旧，currentCycle 不在 `cycleHistory` 中重复。

- [ ] **Step 2: 运行展示测试并确认详情类型缺失**

Run: `rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO -only-testing:CodexUsageTests/UsagePresentationTests`

Expected: FAIL，编译器报告 `TrendPresentation` 和 `CycleHistoryPresentation` 不存在。

- [ ] **Step 3: 实现趋势和周期展示值类型**

```swift
struct TrendDayPresentation: Equatable, Identifiable {
    var id: LocalDay { day }
    let day: LocalDay
    let label: String
    let tokens: Int64
    let formattedTokens: String
    let status: UsageCalibrationStatus
    let statusLabel: String
}

struct TrendPresentation: Equatable {
    let totalTokens: Int64
    let averageTokens: Int64
    let days: [TrendDayPresentation]

    init(snapshot: UsageSnapshot)
}

struct CycleEntryPresentation: Equatable, Identifiable {
    let id: Date
    let range: String
    let formattedTokens: String
    let statusLabel: String
    let isCurrent: Bool
    let boundaryIsEstimated: Bool
}

struct CycleHistoryPresentation: Equatable {
    let entries: [CycleEntryPresentation]

    init(snapshot: UsageSnapshot, timeZone: TimeZone)
}
```

趋势使用 `snapshot.recentDays.suffix(7)` 保持自然日顺序；平均值仅按实际存在的天数计算。历史先放 currentCycle，再取 `cycleHistory.sorted(by: endsAt descending).prefix(8)`，并按 `startsAt` 去重。

- [ ] **Step 4: 实现最近 7 天详情页**

`TrendDetailView` 顶部是返回按钮、“最近 7 天”标题、总 Token 和日均 Token；中部使用 Apple Charts：

```swift
Chart(presentation.days) { day in
    BarMark(
        x: .value("日期", day.label),
        y: .value("Token", day.tokens)
    )
    .foregroundStyle(
        LinearGradient(
            colors: [UsageTheme.accent, UsageTheme.accentBlue],
            startPoint: .bottom,
            endPoint: .top
        )
    )
    .cornerRadius(3)
}
.chartYAxis(.hidden)
.frame(height: 132)
```

下方紧凑列出日期、Token 和校准状态；7 行必须在固定高度内可读。图表只画 `displayedTokens`，不把 cached input 作为独立 series。

使用 `UsagePreviewData.fullSnapshot` 增加固定 410×440 的趋势 `#Preview`。

- [ ] **Step 5: 实现周期历史详情页**

`CycleHistoryView` 顶部返回按钮与标题，下方 `ScrollView`/`LazyVStack` 展示最多 9 项。current entry 使用左侧 3pt 紫色标记和“当前周期”，已完成项不使用强调底色；每项显示时间范围、Token、校准状态，`boundaryIsEstimated` 时追加“边界估算”。

使用 `UsagePreviewData.fullSnapshot` 增加固定 410×440 的历史 `#Preview`。

- [ ] **Step 6: 在同一固定弹窗内接入可访问转场**

`UsagePopoverView` 读取 `@Environment(\.accessibilityReduceMotion)`。页面方向固定：overview→detail 从右侧进入，detail→overview 从左侧退出；reduce motion 时使用 `.identity` 且 transaction animation 为 nil：

```swift
let transition: AnyTransition = reduceMotion
    ? .identity
    : .asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity)
    )

Group {
    switch viewModel.page {
    case .overview: overview
    case .trend: trend
    case .history: history
    }
}
.id(viewModel.page)
.transition(transition)
.animation(
    reduceMotion ? nil : .easeInOut(duration: UsageTheme.transitionDuration),
    value: viewModel.page
)
```

页面切换不得创建新 window、sheet 或 popover。给返回、刷新、退出和两个详情入口添加中文 accessibility label。

- [ ] **Step 7: 运行展示/导航测试与 Debug build**

Run: `rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO -only-testing:CodexUsageTests/UsagePresentationTests -only-testing:CodexUsageTests/UsageViewModelTests`

Expected: PASS，趋势固定最近 7 天、周期固定 current+8、路由返回 overview。

Run: `rtk xcodebuild build -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Debug CODE_SIGNING_ALLOWED=NO`

Expected: `** BUILD SUCCEEDED **`，Charts 只链接系统 framework，三个页面保持 410×440。

- [ ] **Step 8: 提交详情页面**

```bash
rtk git add App/CodexUsage.xcodeproj/project.pbxproj App/CodexUsage/UsagePresentation.swift App/CodexUsage/UsagePopoverView.swift App/CodexUsage/TrendDetailView.swift App/CodexUsage/CycleHistoryView.swift App/CodexUsageTests/UsagePresentationTests.swift App/CodexUsageTests/UsageViewModelTests.swift
rtk git commit -m "[ai] feat(ui): 展示趋势和周期历史"
```

---

### Task 10: 接通真实 App 生命周期、目录选择、唤醒和可靠退出

**Files:**
- Modify: `App/CodexUsage/CodexUsageApp.swift`
- Modify: `App/CodexUsage/AppContainer.swift`
- Modify: `App/CodexUsage/UsagePopoverView.swift`
- Modify: `App/CodexUsageTests/ProjectSmokeTests.swift`

**Interfaces:**
- Consumes: live `AppContainer`、`UsageViewModel`、`NSOpenPanel`、`NSWorkspace.didWakeNotification` 和 `NSApplicationDelegate`。
- Produces: 完整 `MenuBarExtra(.window)` 应用；打开 popover 刷新、睡眠唤醒刷新、只弹一次目录选择器，以及 terminateLater 异步清理。

- [ ] **Step 1: 写失败的入口纯逻辑测试**

把目录选择器配置和菜单标题所需的纯值放在 internal helper，避免 UI 自动化：

```swift
func testOpenPanelConfigurationOnlyAllowsOneDirectory() {
    let configuration = CodexHomePanelConfiguration.live

    XCTAssertTrue(configuration.canChooseDirectories)
    XCTAssertFalse(configuration.canChooseFiles)
    XCTAssertFalse(configuration.allowsMultipleSelection)
    XCTAssertEqual(configuration.prompt, "选择")
    XCTAssertEqual(configuration.message, "请选择包含 sessions 或 archived_sessions 的 Codex Home 文件夹。")
}

func testAppMetadataMatchesMenuBarDelivery() {
    XCTAssertEqual(AppMetadata.popoverSize, CGSize(width: 410, height: 440))
    XCTAssertEqual(AppMetadata.applicationName, "Codex Usage")
}
```

Info.plist 的 `LSUIElement` 由 build 后 `plutil` 验证，不在 unit test 读取源文件路径。

- [ ] **Step 2: 运行入口测试并确认 helper 缺失**

Run: `rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO -only-testing:CodexUsageTests/ProjectSmokeTests`

Expected: FAIL，编译器报告 panel configuration/App metadata 不存在。

- [ ] **Step 3: 实现 NSOpenPanel 选择闭包**

先定义测试使用的纯值：

```swift
struct CodexHomePanelConfiguration: Equatable {
    let canChooseDirectories: Bool
    let canChooseFiles: Bool
    let allowsMultipleSelection: Bool
    let prompt: String
    let message: String

    static let live = CodexHomePanelConfiguration(
        canChooseDirectories: true,
        canChooseFiles: false,
        allowsMultipleSelection: false,
        prompt: "选择",
        message: "请选择包含 sessions 或 archived_sessions 的 Codex Home 文件夹。"
    )
}

enum AppMetadata {
    static let applicationName = "Codex Usage"
    static let popoverSize = UsageTheme.popoverSize
}
```

`AppContainer` 提供 `@MainActor static func chooseCodexHome() async -> URL?`，通过 `withCheckedContinuation` 包装 `NSOpenPanel.begin`，逐项把 `.live` 配置应用到 panel，并设置 `canCreateDirectories=false`、标题“选择 Codex Home”。用户取消返回 nil；选中 URL 的结构校验仍由 bookmark store 执行，panel 不复制校验规则。

- [ ] **Step 4: 使用真实 View Model 替换冒烟内容**

最终入口结构固定为：

```swift
@main
struct CodexUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel: UsageViewModel

    init() {
        let container = AppContainer.live()
        _viewModel = StateObject(
            wrappedValue: UsageViewModel(
                runtimeBuilder: container,
                bookmarkStore: CodexHomeBookmarkStore(),
                chooseCodexHome: AppContainer.chooseCodexHome
            )
        )
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(viewModel: viewModel)
                .onAppear {
                    Task { await viewModel.openPopover() }
                }
        } label: {
            Text(viewModel.menuBarTitle)
                .accessibilityLabel(
                    "Codex 周额度 " + viewModel.menuBarTitle
                )
                .task {
                    appDelegate.prepareToTerminate = {
                        await viewModel.stop()
                    }
                    await viewModel.start()
                }
                .onReceive(
                    NSWorkspace.shared.notificationCenter.publisher(
                        for: NSWorkspace.didWakeNotification
                    )
                ) { _ in
                    Task { await viewModel.handleWake() }
                }
        }
        .menuBarExtraStyle(.window)
    }
}
```

启动 `.task` 和 wake subscription 必须放在始终存在的菜单栏 label 上，不能放在只在用户打开弹窗后才创建的 content 中；这样额度会在 App 启动时加载，关闭弹窗时也能处理系统唤醒。content 的 `onAppear` 只负责 `.popoverOpened` 刷新。

- [ ] **Step 5: 实现异步退出握手**

`@MainActor final class AppDelegate: NSObject, NSApplicationDelegate` 保存 `prepareToTerminate: (() async -> Void)?` 和 `isTerminating`。第一次 `applicationShouldTerminate` 返回 `.terminateLater`，启动 Task 等待 `viewModel.stop()` 后调用 `sender.reply(toApplicationShouldTerminate: true)`；再次进入时返回 `.terminateNow`。退出按钮只调用 `NSApplication.shared.terminate(nil)`，确保用户退出和系统退出走同一清理路径。

- [ ] **Step 6: 运行测试、检查 Info.plist 和实际启动**

Run: `rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO -only-testing:CodexUsageTests/ProjectSmokeTests`

Expected: PASS。

Run: `rtk xcodebuild build -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Debug`

Expected: `** BUILD SUCCEEDED **`，本机使用 ad-hoc “Sign to Run Locally”。

Run: `rtk plutil -p 'DerivedData/Debug/Build/Products/Debug/Codex Usage.app/Contents/Info.plist'`

Expected: `LSUIElement => true`、`LSMinimumSystemVersion => 13.0`、bundle identifier 为 `com.local.CodexUsage`。

人工运行 `DerivedData/Debug/Build/Products/Debug/Codex Usage.app`，验证菜单栏出现、Dock 不出现、打开 popover 触发数据读取、退出按钮关闭应用。用 Activity Monitor 搜索 `codex app-server`，退出后不得有由本 App 启动的遗留进程。

- [ ] **Step 7: 提交真实 App 入口**

```bash
rtk git add App/CodexUsage/CodexUsageApp.swift App/CodexUsage/AppContainer.swift App/CodexUsage/UsagePopoverView.swift App/CodexUsageTests/ProjectSmokeTests.swift
rtk git commit -m "[ai] feat(app): 接通菜单栏应用生命周期"
```

---

### Task 11: 添加 MIT License、新手文档和完整 Release 验收

**Files:**
- Create: `LICENSE`
- Modify: `README.md`

**Interfaces:**
- Consumes: 完成的 App/UsageCore targets 和 Xcode build 路径。
- Produces: MIT 授权、Xcode 新手可直接照做的运行/停止/Release 指南，以及 v1 完整验收证据。

- [ ] **Step 1: 添加标准 MIT License**

`LICENSE` 使用以下完整文本，版权主体不写个人敏感信息：

```text
MIT License

Copyright (c) 2026 Codex Usage contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: 把 README 更新为可执行的新手指南**

保留现有隐私边界并将“App 壳尚未创建”改为 v1 已完成。README 至少包含以下准确操作：

```markdown
## 用 Xcode 运行

1. 双击 `App/CodexUsage.xcodeproj`，不要打开根目录 `Package.swift`。
2. 在 Xcode 顶部 Scheme 选择 `CodexUsage`，运行目标选择 `My Mac`。
3. 按 `⌘R`。出现 `Build Succeeded` 后，到 macOS 菜单栏寻找 `◔ --` 或额度百分比。
4. 点击菜单栏项目查看概览；应用没有 Dock 图标属于正常行为。
5. 停止调试按 Xcode 左上角停止按钮或 `⌘.`；正常退出请在弹窗底部点击“退出”。

## 构建可双击的 Release App

1. 在 Xcode 菜单选择 Product → Scheme → Edit Scheme。
2. 选择 Run，将 Build Configuration 改为 Release 后关闭设置。
3. 按 `⌘B` 完成构建。
4. 在 Xcode 左侧 Products 下右键 `Codex Usage.app`，选择 Show in Finder。

命令行可重复生成到固定位置：

`rtk xcodebuild build -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Release`

产物路径：`DerivedData/Release/Build/Products/Release/Codex Usage.app`
```

README 还要说明：仅 Apple Silicon/macOS 13+；Xcode 16.4；首次找不到目录时选择包含 `sessions` 或 `archived_sessions` 的 Codex Home；数据存储路径；App Sandbox 关闭与非 Mac App Store 定位；没有遥测且不读 auth.json；Debug/Release 测试命令；MIT License 链接；Phase 1 和 Phase 2 两份设计/计划链接。

- [ ] **Step 3: 运行 UsageCore 与 App 全套自动化测试**

Run: `rtk swift test`

Expected: PASS，全部 UsageCore tests，0 failures，无新增 warning。

Run: `rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO`

Expected: `** TEST SUCCEEDED **`，CodexUsageTests 全部通过，无悬挂进程或 continuation warning。

- [ ] **Step 4: 验证无签名 Debug 与 Release 构建**

Run: `rtk xcodebuild build -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Debug CODE_SIGNING_ALLOWED=NO`

Expected: `** BUILD SUCCEEDED **`，关键目标无 warning。

Run: `rtk xcodebuild build -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Release CODE_SIGNING_ALLOWED=NO`

Expected: `** BUILD SUCCEEDED **`，生成 `DerivedData/Release/Build/Products/Release/Codex Usage.app`。

Run: `rtk lipo -info 'DerivedData/Release/Build/Products/Release/Codex Usage.app/Contents/MacOS/Codex Usage'`

Expected: 输出只包含 `arm64`。

Run: `rtk otool -L 'DerivedData/Release/Build/Products/Release/Codex Usage.app/Contents/MacOS/Codex Usage'`

Expected: 只列出 Apple 系统 dylib/framework；没有第三方动态库。

- [ ] **Step 5: 生成并人工验收本机可双击 Release App**

Run: `rtk xcodebuild build -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Release`

Expected: `** BUILD SUCCEEDED **`，Xcode 使用本机 “Sign to Run Locally”；Finder 双击 `.app` 可启动。

人工验收逐项记录通过/失败：

1. 菜单栏显示 `◔ 百分比`，无数据 `◔ --`，致命 SQLite fake 场景 `◔ !`；
2. Dock 无图标，popover 固定 410×440；
3. 今日总量层级高于输入/缓存/输出，cache 未被额外相加；
4. 趋势与历史在同一 popover 内切换并返回；
5. 系统“减少动态效果”开启时无滑动转场；
6. 自动发现和手动选择 Codex Home 均可用，取消后不重复弹 panel；
7. 写入一条完整 Token 事件后目标 2 秒内更新；
8. 离线或 app-server 不可用时保留旧快照并显示 stale；
9. 睡眠唤醒和手动刷新可用；
10. 静置 5 分钟后 Activity Monitor 中平均 CPU 低于 1%；
11. 退出后无本 App 遗留的 codex 子进程和 FSEvents 监听；
12. `~/Library/Application Support/Codex Usage/usage.sqlite` 存在，仓库和 Codex Home 内没有 App 数据库。

- [ ] **Step 6: 检查隐私、保留和 Git 边界**

Run: `rtk rg -n 'auth\.json|api[_-]?key|oauth|cookie|telemetry|analytics' App Sources Tests README.md`

Expected: 只出现 README/隐私测试中的否定说明；App 生产代码没有认证读取、遥测或第三方分析。

Run: `rtk git status --short`

Expected: 本任务只新增 `LICENSE`、修改 `README.md`；`.idea/` 与 `.superpowers/` 仍未暂存，`DerivedData/` 和 `.app` 不出现。

- [ ] **Step 7: 提交许可证和交付文档**

```bash
rtk git add LICENSE README.md
rtk git commit -m "[ai] docs(app): 补充本地运行和发布说明"
```

---

## Phase 2 Completion Gate

以下条件必须同时满足才能宣告 v1 完成：

- `rtk swift test` 全绿，新增 `resolvedCodexHome` 测试覆盖三层优先级且没有破坏原有隐私/9 周期清理测试；
- `rtk xcodebuild test ...` 的 App 测试全绿，受控时钟测试没有真实长等待或悬挂 Task；
- Debug、无签名 Release、本机 “Sign to Run Locally” Release 三种构建均成功，关键目标无新增 warning；
- 菜单栏、四种内容状态、概览、趋势、周期历史、目录选择、唤醒、手动刷新和退出均实际可操作；
- 新完整 Token 事件 2 秒内反映、静置 CPU 低于 1%、退出后无遗留 codex 子进程；
- Release `.app` 仅含 arm64，可由 Finder 双击启动，路径与 README 一致；
- SQLite 只位于 Application Support，bookmark 只保存目录授权，App 不读取或持久化敏感内容；
- 当前周期 + 8 个已完成周期的保留规则、cache 为 input 子集的口径均未回归；
- `LICENSE` 为 MIT，README 足以让第一次使用 Xcode 的用户独立完成运行、停止、构建和定位 `.app`；
- Git diff 不包含 `DerivedData/`、`.app`、SQLite、bookmark、`.idea/`、`.superpowers/`、Xcode 用户状态或任何 v1 非目标功能。
