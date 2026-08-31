# Codex Usage Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** 构建一个经过完整自动化测试的 Swift 6 UsageCore library，安全读取 Codex 额度、官方每日 Token 和本机 session Token，并输出可供后续菜单栏 App 直接展示的统一快照。

**Architecture:** 第一阶段使用 macOS-only SwiftPM library，将领域模型、app-server JSONL/JSON-RPC、session 增量索引、SQLite 持久化、校准和刷新编排分成聚焦目录。所有外部边界都通过小协议注入；生产实现使用本机 codex 子进程、只读文件系统和系统 SQLite3，测试使用真实临时文件、真实临时数据库及假的 JSONL 子进程。

**Tech Stack:** Swift 6.2.4、Swift Package Manager、Foundation、CryptoKit、SQLite3、CoreServices/FSEvents、XCTest。

**Spec:** docs/superpowers/specs/2026-08-31-codex-usage-menubar-design.md

## Global Constraints

- 仅支持 Apple Silicon 与 macOS 13+；Package.swift 固定 swift-tools-version 6.0 和 macOS v13。
- 第一阶段只创建 UsageCore library 和测试，不创建或手写 .xcodeproj。
- 仅使用 Apple 系统 framework/library；不引入第三方 package。
- Token 总量固定为 inputTokens + outputTokens；cachedInputTokens 只做输入子集明细。
- 不读取 auth.json，不访问私有 HTTP 接口，不保存原始 JSONL、消息正文、账号身份或凭据。
- app-server 请求只依赖稳定字段；未知字段忽略，可选字段缺失时降级。
- 每个生产行为必须先有能因该行为缺失而失败的测试，再写最小实现。
- shell 命令一律使用 rtk 前缀。
- Git 提交信息使用 [ai] type(scope): 中文主题，单行不超过 72 字符。

## File Map

~~~text
Package.swift
.gitignore
Sources/UsageCore/
  Domain/
    LocalDay.swift
    TokenBreakdown.swift
    UsageModels.swift
  AppServer/
    JSONValue.swift
    AppServerModels.swift
    WeeklyQuotaSelector.swift
    CodexExecutableResolver.swift
    JSONLLineFramer.swift
    AppServerTransport.swift
    ProcessJSONLTransport.swift
    CodexAppServerClient.swift
  Sessions/
    CodexHomeResolver.swift
    SessionModels.swift
    SessionLineParser.swift
    SessionUsageAccumulator.swift
    SessionFileScanner.swift
    SessionUsageIndexer.swift
    SessionDirectoryWatcher.swift
  Persistence/
    UsageStore.swift
    SQLiteConnection.swift
    SQLiteUsageStore.swift
  Reconciliation/
    CycleTracker.swift
    UsageReconciler.swift
  Coordination/
    RefreshPolicy.swift
    UsageService.swift
Tests/UsageCoreTests/
  TestSupport.swift
  DomainModelsTests.swift
  JSONRPCModelsTests.swift
  WeeklyQuotaSelectorTests.swift
  AppServerClientTests.swift
  SessionLineParserTests.swift
  SessionUsageAccumulatorTests.swift
  SQLiteUsageStoreTests.swift
  SessionUsageIndexerTests.swift
  CycleTrackerTests.swift
  UsageReconcilerTests.swift
  RefreshPolicyTests.swift
  UsageServiceTests.swift
  PrivacyBoundaryTests.swift
  Fixtures/
    fake-app-server.sh
    session-last-usage.jsonl
    session-total-usage.jsonl
    session-replayed-prefix.jsonl
README.md
~~~

## Execution Preflight

在 Task 1 前先运行：

~~~bash
rtk git status --short
rtk git diff --check
rtk git add docs/superpowers/specs/2026-08-31-codex-usage-menubar-design.md docs/superpowers/plans/2026-08-31-codex-usage-core.md
rtk git commit -m "[ai] docs(design): 记录用量核心实施方案"
~~~

Expected: status 在提交前只含 docs/；diff check 无输出；提交后工作树干净。

---

### Task 1: Swift Package 与稳定领域模型

**Files:**
- Create: Package.swift
- Create: .gitignore
- Create: Sources/UsageCore/Domain/LocalDay.swift
- Create: Sources/UsageCore/Domain/TokenBreakdown.swift
- Create: Sources/UsageCore/Domain/UsageModels.swift
- Create: Tests/UsageCoreTests/DomainModelsTests.swift
- Create: Tests/UsageCoreTests/TestSupport.swift
- Create: Tests/UsageCoreTests/Fixtures/.gitkeep

**Interfaces:**
- Consumes: 无。
- Produces: LocalDay、TokenBreakdown、UsageCalibrationStatus、QuotaSnapshot、UsageDay、QuotaCycle、UsageSnapshot。

- [ ] **Step 1: 创建只含 target 定义的构建骨架**

~~~swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexUsage",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"])
    ],
    targets: [
        .target(
            name: "UsageCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("CoreServices")
            ]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
~~~

同时创建 Sources/UsageCore/Domain/TokenBreakdown.swift，初始只含 import Foundation，用来让 SwiftPM 建立真实 UsageCore module；同一红—绿循环的 Step 5 会把它替换为完整类型，不提交这个中间状态。

.gitignore 精确包含：

~~~gitignore
.build/
.swiftpm/
DerivedData/
*.xcuserstate
.DS_Store
~~~

- [ ] **Step 2: 创建共享测试支持，只负责临时文件和字面 fixture**

TestSupport.swift 提供以下真实 helper；它不复制生产聚合或选择算法：

~~~swift
import Foundation

enum TestSupportError: Error {
    case missingFixture(String)
    case invalidDate(String)
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodexUsageTests-" + UUID().uuidString,
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

func temporaryDatabaseURL() throws -> URL {
    try temporaryDirectory().appendingPathComponent("usage.sqlite3")
}

func temporaryCodexHome() throws -> URL {
    let root = try temporaryDirectory()
    for name in ["sessions", "archived_sessions"] {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name),
            withIntermediateDirectories: true
        )
    }
    return root
}

func fixtureLines(named name: String) throws -> [Data] {
    guard let url = Bundle.module.url(
        forResource: name,
        withExtension: "jsonl",
        subdirectory: "Fixtures"
    ) else {
        throw TestSupportError.missingFixture(name)
    }
    return try Data(contentsOf: url)
        .split(separator: 0x0A)
        .map(Data.init)
}

func fixtureLine(named name: String) throws -> Data {
    guard let first = try fixtureLines(named: name).first else {
        throw TestSupportError.missingFixture(name)
    }
    return first
}

func date(_ text: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let value = formatter.date(from: text) {
        return value
    }
    formatter.formatOptions = [.withInternetDateTime]
    guard let value = formatter.date(from: text) else {
        throw TestSupportError.invalidDate(text)
    }
    return value
}
~~~

- [ ] **Step 3: 写入第一个失败测试，证明缓存输入不会重复累计**

~~~swift
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
~~~

- [ ] **Step 4: 运行测试并确认因 TokenBreakdown 尚不存在而失败**

Run: rtk swift test --filter DomainModelsTests

Expected: FAIL，编译器报告 cannot find TokenBreakdown in scope。

- [ ] **Step 5: 实现最小领域模型**

TokenBreakdown.swift：

~~~swift
public struct TokenBreakdown: Codable, Equatable, Sendable {
    public let inputTokens: Int64
    public let cachedInputTokens: Int64
    public let outputTokens: Int64

    public init(
        inputTokens: Int64,
        cachedInputTokens: Int64,
        outputTokens: Int64
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
    }

    public var totalTokens: Int64 {
        inputTokens + outputTokens
    }

    public static let zero = TokenBreakdown(
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0
    )

    public static func + (
        lhs: TokenBreakdown,
        rhs: TokenBreakdown
    ) -> TokenBreakdown {
        TokenBreakdown(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens
        )
    }
}
~~~

LocalDay.swift 以 year、month、day 三个 Int 保存已归档的本地日期，不使用当前时区重新解释已保存日期：

~~~swift
public struct LocalDay: Codable, Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public var iso8601: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
        (lhs.year, lhs.month, lhs.day)
            < (rhs.year, rhs.month, rhs.day)
    }
}
~~~

UsageModels.swift 定义以下精确属性：

~~~swift
public enum UsageCalibrationStatus: String, Codable, Sendable {
    case localLive
    case calibrated
    case partiallyCalibrated
    case stale
    case unavailable
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public let limitID: String
    public let usedPercent: Double
    public let windowDurationMinutes: Int
    public let startsAt: Date
    public let resetsAt: Date
    public let fetchedAt: Date

    public var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }
}

public struct UsageDay: Codable, Equatable, Sendable {
    public let day: LocalDay
    public let localUsage: TokenBreakdown
    public let officialTokens: Int64?
    public let displayedTokens: Int64
    public let status: UsageCalibrationStatus
}

public struct QuotaCycle: Codable, Equatable, Sendable {
    public let startsAt: Date
    public let endsAt: Date
    public let usage: TokenBreakdown
    public let displayedTokens: Int64
    public let status: UsageCalibrationStatus
    public let boundaryIsEstimated: Bool
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let quota: QuotaSnapshot?
    public let today: UsageDay
    public let currentCycle: QuotaCycle?
    public let recentDays: [UsageDay]
    public let cycleHistory: [QuotaCycle]
    public let lastUpdatedAt: Date
    public let status: UsageCalibrationStatus
}
~~~

- [ ] **Step 6: 运行领域测试和全套测试**

Run: rtk swift test --filter DomainModelsTests

Expected: PASS，2 tests，0 failures。

Run: rtk swift test

Expected: PASS，0 failures，编译输出无 warning。

- [ ] **Step 7: 提交领域骨架**

~~~bash
rtk git add Package.swift .gitignore Sources/UsageCore/Domain Tests/UsageCoreTests/TestSupport.swift Tests/UsageCoreTests/DomainModelsTests.swift Tests/UsageCoreTests/Fixtures/.gitkeep
rtk git commit -m "[ai] feat(core): 建立用量领域模型"
~~~

---

### Task 2: JSON-RPC 模型、额度响应与周窗口选择

**Files:**
- Create: Sources/UsageCore/AppServer/JSONValue.swift
- Create: Sources/UsageCore/AppServer/AppServerModels.swift
- Create: Sources/UsageCore/AppServer/WeeklyQuotaSelector.swift
- Create: Tests/UsageCoreTests/JSONRPCModelsTests.swift
- Create: Tests/UsageCoreTests/WeeklyQuotaSelectorTests.swift

**Interfaces:**
- Consumes: QuotaSnapshot。
- Produces: JSONValue、RPCIncomingMessage、RPCErrorPayload、InitializeResult、RateLimitsResponse、RateLimitsUpdatedParams、AppServerNotification、AccountUsageResponse、WeeklyQuotaSelector.select(from:fetchedAt:)。

- [ ] **Step 1: 写失败测试，固定未知通知与可空字段的解码行为**

~~~swift
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
~~~

- [ ] **Step 2: 运行测试并确认因 RPCIncomingMessage 和 AccountUsageResponse 缺失而失败**

Run: rtk swift test --filter JSONRPCModelsTests

Expected: FAIL，编译器报告两个生产类型不存在。

- [ ] **Step 3: 实现 JSONValue 和 app-server wire models**

JSONValue.swift 定义可递归 Codable enum：

~~~swift
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}
~~~

自定义 init(from:) 按 null、Bool、Int64、Double、String、Array、Dictionary 顺序解码；encode(to:) 对称编码，不把大整数先转成 Double，也不把未知对象转成字符串。

AppServerModels.swift 定义：

~~~swift
public struct RPCErrorPayload: Codable, Equatable, Error, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?
}

public struct RPCIncomingMessage: Decodable, Sendable {
    public let jsonrpc: String?
    public let id: Int64?
    public let method: String?
    public let params: JSONValue?
    public let result: JSONValue?
    public let error: RPCErrorPayload?
}

public struct InitializeResult: Decodable, Equatable, Sendable {
    public let codexHome: String?
    public let platformFamily: String?
    public let platformOs: String?
    public let userAgent: String?
}

public struct RateLimitWindow: Decodable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: Int64?
}

public struct RateLimitBucket: Decodable, Equatable, Sendable {
    public let limitId: String?
    public let limitName: String?
    public let primary: RateLimitWindow?
    public let secondary: RateLimitWindow?
}

public struct RateLimitsResponse: Decodable, Equatable, Sendable {
    public let rateLimits: RateLimitBucket
    public let rateLimitsByLimitId: [String: RateLimitBucket]?
}

public struct AccountUsageSummary: Decodable, Equatable, Sendable {
    public let lifetimeTokens: Int64?
    public let peakDailyTokens: Int64?
    public let longestRunningTurnSec: Int64?
    public let currentStreakDays: Int64?
    public let longestStreakDays: Int64?
}

public struct AccountTokenUsageDailyBucket: Decodable, Equatable, Sendable {
    public let startDate: String
    public let tokens: Int64
}

public struct AccountUsageResponse: Decodable, Equatable, Sendable {
    public let summary: AccountUsageSummary
    public let dailyUsageBuckets: [AccountTokenUsageDailyBucket]?
}

public enum PatchField<Value: Sendable>: Sendable {
    case missing
    case value(Value?)
}

public struct RateLimitWindowPatch: Decodable, Sendable {
    public let usedPercent: PatchField<Double>
    public let windowDurationMins: PatchField<Int>
    public let resetsAt: PatchField<Int64>
}

public struct RateLimitBucketPatch: Decodable, Sendable {
    public let limitId: PatchField<String>
    public let limitName: PatchField<String>
    public let primary: PatchField<RateLimitWindowPatch>
    public let secondary: PatchField<RateLimitWindowPatch>
}

public struct RateLimitsUpdatedParams: Decodable, Sendable {
    public let rateLimits: RateLimitBucketPatch
}

public enum AppServerNotification: Sendable {
    case rateLimitsUpdated(RateLimitsUpdatedParams)
    case other(method: String)
}
~~~

PatchField 的 keyed-container helper 必须用 contains(_:) 区分 missing；键存在且 decodeNil 时产生 value(nil)，否则产生 value(decoded)。RateLimitWindow、RateLimitBucket 和 RateLimitsResponse 分别实现 applying(_:)：missing 保留旧值，value(nil) 清空可空字段，value(patch) 逐字段合并；rateLimitsByLimitId 存在时只同步更新与合并后 limitId 相同的 bucket。

- [ ] **Step 4: 运行 JSON-RPC 模型测试**

Run: rtk swift test --filter JSONRPCModelsTests

Expected: PASS，未知 notification 不报错，null 每日桶保持 nil，稀疏额度更新不会清空 duration 和 resetsAt。

- [ ] **Step 5: 写失败测试，固定周窗口选择而不误选 5 小时窗口**

~~~swift
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
~~~

- [ ] **Step 6: 运行测试并确认 WeeklyQuotaSelector 缺失**

Run: rtk swift test --filter WeeklyQuotaSelectorTests

Expected: FAIL，编译器报告 WeeklyQuotaSelector 不存在。

- [ ] **Step 7: 实现确定性选择算法**

~~~swift
public struct WeeklyQuotaSelector: Sendable {
    public init() {}

    public func select(
        from response: RateLimitsResponse,
        fetchedAt: Date
    ) -> QuotaSnapshot? {
        let buckets: [RateLimitBucket]
        if let byID = response.rateLimitsByLimitId, !byID.isEmpty {
            buckets = byID
                .sorted { $0.key < $1.key }
                .map(\.value)
        } else {
            buckets = [response.rateLimits]
        }

        let candidates = buckets.flatMap { bucket in
            [bucket.primary, bucket.secondary].compactMap { window -> Candidate? in
                guard
                    let window,
                    let duration = window.windowDurationMins,
                    let resetSeconds = window.resetsAt,
                    (9_000...11_000).contains(duration)
                else {
                    return nil
                }
                return Candidate(
                    limitID: bucket.limitId ?? "unknown",
                    window: window,
                    duration: duration,
                    resetSeconds: resetSeconds
                )
            }
        }

        guard let selected = candidates.min(by: Candidate.isPreferred) else {
            return nil
        }

        let resetsAt = Date(
            timeIntervalSince1970: TimeInterval(selected.resetSeconds)
        )
        return QuotaSnapshot(
            limitID: selected.limitID,
            usedPercent: selected.window.usedPercent,
            windowDurationMinutes: selected.duration,
            startsAt: resetsAt.addingTimeInterval(
                -TimeInterval(selected.duration * 60)
            ),
            resetsAt: resetsAt,
            fetchedAt: fetchedAt
        )
    }
}

private struct Candidate {
    let limitID: String
    let window: RateLimitWindow
    let duration: Int
    let resetSeconds: Int64

    static func isPreferred(
        _ lhs: Candidate,
        _ rhs: Candidate
    ) -> Bool {
        let lhsCodexRank = lhs.limitID == "codex" ? 0 : 1
        let rhsCodexRank = rhs.limitID == "codex" ? 0 : 1
        if lhsCodexRank != rhsCodexRank {
            return lhsCodexRank < rhsCodexRank
        }
        let lhsDistance = abs(lhs.duration - 10_080)
        let rhsDistance = abs(rhs.duration - 10_080)
        if lhsDistance != rhsDistance {
            return lhsDistance < rhsDistance
        }
        if lhs.limitID != rhs.limitID {
            return lhs.limitID < rhs.limitID
        }
        return lhs.resetSeconds < rhs.resetSeconds
    }
}
~~~

Candidate.isPreferred 先比较 limitID 是否等于 codex，再比较 abs(duration - 10_080)，最后用 limitID 与 resetSeconds 稳定打破平局。

- [ ] **Step 8: 运行 Task 2 测试和全套测试**

Run: rtk swift test --filter JSONRPCModelsTests

Expected: PASS。

Run: rtk swift test --filter WeeklyQuotaSelectorTests

Expected: PASS。

Run: rtk swift test

Expected: PASS，0 failures，编译输出无 warning。

- [ ] **Step 9: 提交协议模型和额度选择**

~~~bash
rtk git add Sources/UsageCore/AppServer Tests/UsageCoreTests/JSONRPCModelsTests.swift Tests/UsageCoreTests/WeeklyQuotaSelectorTests.swift
rtk git commit -m "[ai] feat(quota): 解析并选择周额度窗口"
~~~

---

### Task 3: 真实 JSONL transport 与并发安全 app-server client

**Files:**
- Create: Sources/UsageCore/AppServer/JSONLLineFramer.swift
- Create: Sources/UsageCore/AppServer/AppServerTransport.swift
- Create: Sources/UsageCore/AppServer/CodexExecutableResolver.swift
- Create: Sources/UsageCore/AppServer/ProcessJSONLTransport.swift
- Create: Sources/UsageCore/AppServer/CodexAppServerClient.swift
- Create: Tests/UsageCoreTests/AppServerClientTests.swift
- Create: Tests/UsageCoreTests/Fixtures/fake-app-server.sh
- Modify: Tests/UsageCoreTests/TestSupport.swift

**Interfaces:**
- Consumes: JSONValue、RPCIncomingMessage、InitializeResult、RateLimitsResponse、RateLimitsUpdatedParams、AppServerNotification、AccountUsageResponse。
- Produces: CodexExecutableResolver.resolve(environment:standardLocations:)、AppServerTransport actor protocol、ProcessJSONLTransport、CodexAppServerClient.initialize()、readRateLimits()、readAccountUsage()、nextNotification()、stop()。

- [ ] **Step 1: 写失败测试，固定菜单栏进程缺少常规 PATH 时的 Codex 可执行文件定位**

~~~swift
func testExecutableResolverUsesPATHThenChatGPTBundleFallback() throws {
    let root = try temporaryDirectory()
    let pathDirectory = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(
        at: pathDirectory,
        withIntermediateDirectories: true
    )
    let pathCodex = pathDirectory.appendingPathComponent("codex")
    try Data("#!/bin/sh\n".utf8).write(to: pathCodex)
    XCTAssertEqual(chmod(pathCodex.path, S_IRUSR | S_IWUSR | S_IXUSR), 0)
    let fallback = root.appendingPathComponent("ChatGPT-codex")
    try Data("#!/bin/sh\n".utf8).write(to: fallback)
    XCTAssertEqual(chmod(fallback.path, S_IRUSR | S_IWUSR | S_IXUSR), 0)

    XCTAssertEqual(
        CodexExecutableResolver().resolve(
            environment: ["PATH": pathDirectory.path],
            standardLocations: [fallback]
        ),
        pathCodex
    )
    XCTAssertEqual(
        CodexExecutableResolver().resolve(
            environment: ["PATH": ""],
            standardLocations: [fallback]
        ),
        fallback
    )
}
~~~

AppServerClientTests.swift import Darwin 取得 chmod 和权限常量；teardown 删除临时目录。

- [ ] **Step 2: 运行 resolver 测试并确认生产类型缺失**

Run: rtk swift test --filter AppServerClientTests/testExecutableResolver

Expected: FAIL，编译器报告 CodexExecutableResolver 不存在。

- [ ] **Step 3: 实现不启动 shell 的可执行文件解析**

~~~swift
public struct CodexExecutableResolver: Sendable {
    public init() {}

    public func resolve(
        environment: [String: String],
        standardLocations: [URL] = [
            URL(
                fileURLWithPath:
                    "/Applications/ChatGPT.app/Contents/Resources/codex"
            )
        ]
    ) -> URL? {
        let pathCandidates = environment["PATH", default: ""]
            .split(separator: ":")
            .map {
                URL(fileURLWithPath: String($0))
                    .appendingPathComponent("codex")
            }
        return (pathCandidates + standardLocations).first {
            FileManager.default.isExecutableFile(
                atPath: $0.standardizedFileURL.path
            )
        }?.standardizedFileURL
    }
}
~~~

- [ ] **Step 4: 写一个假的 JSONL 子进程 fixture**

fake-app-server.sh 逐行读取 stdin，按 method 返回真实 JSON-RPC 形状，并在 initialize 响应前插入未知 notification：

~~~bash
#!/bin/sh
while IFS= read -r line
do
  case "$line" in
    *'"method":"initialize"'*)
      printf '%s\n' '{"method":"remoteControl/status/changed","params":{"state":"idle"}}'
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"codexHome":"/tmp/codex-home","platformFamily":"unix","platformOs":"macos","userAgent":"fake"}}'
      ;;
    *'"method":"account/rateLimits/read"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":1788753600},"secondary":null},"rateLimitsByLimitId":null}}'
      printf '%s\n' '{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":31}}}}'
      ;;
    *'"method":"account/usage/read"'*)
      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"summary":{"lifetimeTokens":1234,"peakDailyTokens":500,"longestRunningTurnSec":30,"currentStreakDays":2,"longestStreakDays":4},"dailyUsageBuckets":[{"startDate":"2026-08-30","tokens":400}]}}'
      ;;
  esac
done
~~~

Run: rtk chmod +x Tests/UsageCoreTests/Fixtures/fake-app-server.sh

- [ ] **Step 5: 写失败集成测试，验证握手、未知通知和两个读取方法**

~~~swift
func testClientCompletesHandshakeAndReadsUsageThroughJSONLProcess() async throws {
    let executable = try XCTUnwrap(
        Bundle.module.url(
            forResource: "fake-app-server",
            withExtension: "sh",
            subdirectory: "Fixtures"
        )
    )
    let transport = ProcessJSONLTransport(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable.path]
    )
    let client = CodexAppServerClient(
        transport: transport,
        requestTimeout: .seconds(2)
    )

    let initialized = try await client.initialize()
    let limits = try await client.readRateLimits()
    let notification = await client.nextNotification()
    let usage = try await client.readAccountUsage()
    await client.stop()

    XCTAssertEqual(initialized.codexHome, "/tmp/codex-home")
    XCTAssertEqual(limits.rateLimits.primary?.usedPercent, 25)
    guard case let .rateLimitsUpdated(update) = notification else {
        return XCTFail("expected rate-limit update")
    }
    guard
        case let .value(windowPatch?) = update.rateLimits.primary,
        case let .value(usedPercent?) = windowPatch.usedPercent
    else {
        return XCTFail("expected sparse primary usedPercent")
    }
    XCTAssertEqual(usedPercent, 31)
    XCTAssertEqual(usage.dailyUsageBuckets?.first?.tokens, 400)
}
~~~

同一测试文件定义不检查调用次数的真实 line-source double：

~~~swift
actor ScriptedTransport: AppServerTransport {
    private var lines: [Data?]

    init(lines: [Data?]) {
        self.lines = lines
    }

    func start() async throws {}
    func send(line: Data) async throws {}

    func nextLine() async throws -> Data? {
        guard !lines.isEmpty else {
            return nil
        }
        return lines.removeFirst()
    }

    func stop() async {
        lines.removeAll()
    }
}

actor StallingTransport: AppServerTransport {
    func start() async throws {}
    func send(line: Data) async throws {}

    func nextLine() async throws -> Data? {
        try await Task.sleep(for: .seconds(60))
        return nil
    }

    func stop() async {}
}
~~~

并写入四个具体测试：

~~~swift
func testRPCErrorPreservesCodeAndMessage() async throws {
    let line = Data(
        #"{"id":1,"error":{"code":-32600,"message":"authentication required"}}"#.utf8
    )
    let client = CodexAppServerClient(
        transport: ScriptedTransport(lines: [line]),
        requestTimeout: .seconds(1)
    )

    do {
        _ = try await client.initialize()
        XCTFail("expected RPC error")
    } catch let error as RPCErrorPayload {
        XCTAssertEqual(error.code, -32600)
        XCTAssertEqual(error.message, "authentication required")
    }
}

func testMalformedLineDoesNotPreventLaterResponse() async throws {
    let malformed = Data("not-json".utf8)
    let response = Data(
        #"{"id":1,"result":{"codexHome":null,"platformFamily":"unix","platformOs":"macos","userAgent":"test"}}"#.utf8
    )
    let client = CodexAppServerClient(
        transport: ScriptedTransport(
            lines: [malformed, response]
        ),
        requestTimeout: .seconds(1)
    )

    let result = try await client.initialize()

    XCTAssertEqual(result.platformOs, "macos")
}

func testEOFClosesPendingRequest() async throws {
    let client = CodexAppServerClient(
        transport: ScriptedTransport(lines: [nil]),
        requestTimeout: .seconds(1)
    )

    await XCTAssertThrowsErrorAsync(
        try await client.initialize()
    ) { error in
        XCTAssertEqual(
            error as? AppServerClientError,
            .transportClosed
        )
    }
}

func testRequestTimeoutRemovesPendingContinuation() async throws {
    let client = CodexAppServerClient(
        transport: StallingTransport(),
        requestTimeout: .milliseconds(50)
    )

    await XCTAssertThrowsErrorAsync(
        try await client.initialize()
    ) { error in
        XCTAssertEqual(
            error as? AppServerClientError,
            .requestTimedOut
        )
    }
    await client.stop()
}
~~~

TestSupport.swift 在 Task 3 增加 import XCTest 和以下 helper；它不读取生产内部状态：

~~~swift
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail(
            "expected expression to throw",
            file: file,
            line: line
        )
    } catch {
        errorHandler(error)
    }
}
~~~

- [ ] **Step 6: 运行测试并确认生产 transport/client 缺失**

Run: rtk swift test --filter AppServerClientTests

Expected: FAIL，编译器报告 ProcessJSONLTransport 与 CodexAppServerClient 不存在。

- [ ] **Step 7: 实现换行 framing 和 transport actor protocol**

~~~swift
public protocol AppServerTransport: Actor {
    func start() async throws
    func send(line: Data) async throws
    func nextLine() async throws -> Data?
    func stop() async
}
~~~

JSONLLineFramer 使用 Data 缓冲；append(_:) 只返回换行前的完整行并保留尾部半行，finish() 丢弃未完成半行且不对外暴露其内容。

ProcessJSONLTransport actor：

- Process 只启动一次，stdin/stdout 使用 Pipe，stderr 指向 FileHandle.nullDevice，生产日志只记录固定错误分类和退出码；
- stdout readabilityHandler 把字节送入 JSONLLineFramer，再送入 AsyncThrowingStream<Data, Error>；
- send(line:) 保证恰好附加一个换行；
- EOF 完成 stream，非零退出转成 transport error；
- stop() 清除 handler、关闭 stdin，并只在进程仍运行时 terminate。

- [ ] **Step 8: 实现按 id 路由的 CodexAppServerClient actor**

公开 API：

~~~swift
public actor CodexAppServerClient {
    public init(
        transport: any AppServerTransport,
        requestTimeout: Duration = .seconds(10)
    )

    public func initialize() async throws -> InitializeResult
    public func readRateLimits() async throws -> RateLimitsResponse
    public func readAccountUsage() async throws -> AccountUsageResponse
    public func nextNotification() async -> AppServerNotification?
    public func stop() async
}

public enum AppServerClientError: Error, Equatable, Sendable {
    case transportClosed
    case requestTimedOut
    case invalidResponse
}
~~~

请求编码形状固定为：

~~~json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"codex_usage_menubar","title":"Codex Usage","version":"0.1.0"}}}
{"jsonrpc":"2.0","method":"initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}
{"jsonrpc":"2.0","id":3,"method":"account/usage/read"}
~~~

实现规则：

- receive loop 在 initialize 时启动且只启动一次；
- id 单调递增，pending continuation 只由 actor 字典持有；
- notification 没有 id 时按 method 解码：account/rateLimits/updated 进入 typed AsyncStream，其他方法忽略；未知 id 响应忽略；
- nextNotification() 从 rate-limit stream 顺序读取，stop/EOF 时 finish stream 并返回 nil；
- result 先从 JSONValue 重新编码，再解码为调用方指定 Decodable 类型；
- error 直接恢复对应 continuation；
- timeout 或 cancellation 必须先从 pending 字典移除，再恢复 continuation；
- EOF/stop 必须一次性失败所有 pending continuation，不能悬挂。

- [ ] **Step 9: 运行 app-server client 测试**

Run: rtk swift test --filter AppServerClientTests

Expected: PASS，握手、未知通知、error、非法行和 EOF 均通过。

- [ ] **Step 10: 运行全套测试并提交**

Run: rtk swift test

Expected: PASS，0 failures，编译输出无 warning，测试进程全部退出。

~~~bash
rtk git add Sources/UsageCore/AppServer Tests/UsageCoreTests/TestSupport.swift Tests/UsageCoreTests/AppServerClientTests.swift Tests/UsageCoreTests/Fixtures/fake-app-server.sh
rtk git commit -m "[ai] feat(app-server): 接入并验证JSONL客户端"
~~~

---

### Task 4: Session Token 解析、累计回退与匿名事件签名

**Files:**
- Create: Sources/UsageCore/Sessions/SessionModels.swift
- Create: Sources/UsageCore/Sessions/SessionLineParser.swift
- Create: Sources/UsageCore/Sessions/SessionUsageAccumulator.swift
- Create: Tests/UsageCoreTests/SessionLineParserTests.swift
- Create: Tests/UsageCoreTests/SessionUsageAccumulatorTests.swift
- Modify: Tests/UsageCoreTests/TestSupport.swift
- Create: Tests/UsageCoreTests/Fixtures/session-last-usage.jsonl
- Create: Tests/UsageCoreTests/Fixtures/session-total-usage.jsonl
- Create: Tests/UsageCoreTests/Fixtures/session-replayed-prefix.jsonl

**Interfaces:**
- Consumes: TokenBreakdown。
- Produces: SessionTokenRecord、SessionTokenEvent、SessionCounterState、SessionLineParser.parse(line:)、SessionUsageAccumulator.ingest(_:)。

- [ ] **Step 1: 创建不含消息内容的 Token fixtures**

session-last-usage.jsonl 包含：

~~~json
{"timestamp":"2026-08-31T01:02:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"reasoning_output_tokens":5},"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"reasoning_output_tokens":5}}}}
~~~

session-total-usage.jsonl 精确包含三行，第三条表示计数器回退：

~~~json
{"timestamp":"2026-08-31T01:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":20,"reasoning_output_tokens":0}}}}
{"timestamp":"2026-08-31T01:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":90,"output_tokens":30,"reasoning_output_tokens":0}}}}
{"timestamp":"2026-08-31T01:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":40,"cached_input_tokens":10,"output_tokens":10,"reasoning_output_tokens":0}}}}
~~~

session-replayed-prefix.jsonl 精确重复 session-last-usage.jsonl 的唯一一行两次，用于验证相同事件得到相同签名。

TestSupport.swift 增加只组装 JSON fixture 的 helper：

~~~swift
func tokenLine(
    timestamp: String,
    input: Int64,
    cached: Int64,
    output: Int64
) -> String {
    let object: [String: Any] = [
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
    let data = try! JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
    )
    return String(decoding: data, as: UTF8.self)
}
~~~

- [ ] **Step 2: 写失败解析测试，固定 last usage 优先和输出不重复计 reasoning**

~~~swift
func testParsesLastUsageWithoutDoubleCountingReasoningOutput() throws {
    let data = try fixtureLine(named: "session-last-usage")

    let record = try XCTUnwrap(SessionLineParser().parse(line: data))

    XCTAssertEqual(
        record.lastUsage,
        TokenBreakdown(
            inputTokens: 100,
            cachedInputTokens: 80,
            outputTokens: 20
        )
    )
    XCTAssertEqual(
        record.occurredAt,
        ISO8601DateFormatter().date(
            from: "2026-08-31T01:02:03.000Z"
        )
    )
}

func testIgnoresNonTokenEventWithoutRetainingPayload() throws {
    let line = Data(
        #"{"timestamp":"2026-08-31T01:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"SECRET_BODY"}}"#.utf8
    )

    XCTAssertNil(try SessionLineParser().parse(line: line))
}
~~~

- [ ] **Step 3: 运行解析测试并确认 SessionLineParser 缺失**

Run: rtk swift test --filter SessionLineParserTests

Expected: FAIL，编译器报告 SessionLineParser 不存在。

- [ ] **Step 4: 用窄 Decodable envelope 实现解析**

SessionModels.swift：

~~~swift
public struct SessionTokenRecord: Equatable, Sendable {
    public let occurredAt: Date
    public let lastUsage: TokenBreakdown?
    public let totalUsage: TokenBreakdown?
    public let schemaVariant: String
}

public struct SessionTokenEvent: Equatable, Sendable {
    public let signature: Data
    public let occurredAt: Date
    public let usage: TokenBreakdown
}

public struct SessionCounterState: Codable, Equatable, Sendable {
    public let previousTotal: TokenBreakdown?
}

public enum SessionParseError: Error, Equatable, Sendable {
    case invalidTokenEvent
}
~~~

SessionLineParser 仅声明 timestamp、type、payload.type、payload.info.last_token_usage 和 total_token_usage 的 CodingKeys。type 或 payload.type 不匹配时返回 nil；负数 token、缓存输入大于输入、无时间戳或时间戳非法时抛 SessionParseError.invalidTokenEvent。reasoning_output_tokens 解码但默认不加入 outputTokens，因为本机当前 schema 的 output_tokens 已是总输出口径。

- [ ] **Step 5: 运行 parser 测试**

Run: rtk swift test --filter SessionLineParserTests

Expected: PASS。

- [ ] **Step 6: 写失败累计测试，固定累计差值、回退和签名**

~~~swift
func testUsesNonNegativeTotalDeltasAndStartsNewSegmentAfterReset() throws {
    let records = try fixtureLines(named: "session-total-usage")
        .compactMap { try SessionLineParser().parse(line: $0) }
    var accumulator = SessionUsageAccumulator()

    let events = try records.compactMap {
        try accumulator.ingest($0)
    }

    XCTAssertEqual(
        events.map(\.usage),
        [
            TokenBreakdown(
                inputTokens: 100,
                cachedInputTokens: 60,
                outputTokens: 20
            ),
            TokenBreakdown(
                inputTokens: 50,
                cachedInputTokens: 30,
                outputTokens: 10
            ),
            TokenBreakdown(
                inputTokens: 40,
                cachedInputTokens: 10,
                outputTokens: 10
            )
        ]
    )
}

func testReplayedRecordProducesSameAnonymousSignature() throws {
    let lines = try fixtureLines(named: "session-replayed-prefix")
    let records = try lines.compactMap {
        try SessionLineParser().parse(line: $0)
    }
    var first = SessionUsageAccumulator()
    var second = SessionUsageAccumulator()

    let left = try XCTUnwrap(first.ingest(records[0]))
    let right = try XCTUnwrap(second.ingest(records[1]))

    XCTAssertEqual(left.signature, right.signature)
}
~~~

- [ ] **Step 7: 运行累计测试并确认 SessionUsageAccumulator 缺失**

Run: rtk swift test --filter SessionUsageAccumulatorTests

Expected: FAIL，编译器报告 SessionUsageAccumulator 不存在。

- [ ] **Step 8: 实现优先级、非负差值和 SHA-256 签名**

~~~swift
public struct SessionUsageAccumulator: Sendable {
    public private(set) var state: SessionCounterState

    public init(
        state: SessionCounterState = SessionCounterState(
            previousTotal: nil
        )
    ) {
        self.state = state
    }

    public mutating func ingest(
        _ record: SessionTokenRecord
    ) throws -> SessionTokenEvent? {
        let usage: TokenBreakdown
        if let last = record.lastUsage {
            usage = last
        } else if let total = record.totalUsage {
            usage = delta(
                current: total,
                previous: state.previousTotal
            )
        } else {
            return nil
        }

        state = SessionCounterState(
            previousTotal: record.totalUsage ?? state.previousTotal
        )
        return SessionTokenEvent(
            signature: signature(for: record),
            occurredAt: record.occurredAt,
            usage: usage
        )
    }
}
~~~

delta 对三个字段分别处理：当前值大于等于前值时相减；任一总计数器回退时整条记录作为新段首值，避免组合出互相不一致的分量。signature(for:) 使用 CryptoKit.SHA256，对 UTC 毫秒时间戳、schemaVariant、last/total 三个数值字段的稳定 UTF-8 串计算 Data(digest)；输入不含路径或正文。

- [ ] **Step 9: 运行 Task 4 与全套测试并提交**

Run: rtk swift test --filter SessionLineParserTests

Expected: PASS。

Run: rtk swift test --filter SessionUsageAccumulatorTests

Expected: PASS。

Run: rtk swift test

Expected: PASS，0 failures，编译输出无 warning。

~~~bash
rtk git add Sources/UsageCore/Sessions Tests/UsageCoreTests/TestSupport.swift Tests/UsageCoreTests/SessionLineParserTests.swift Tests/UsageCoreTests/SessionUsageAccumulatorTests.swift Tests/UsageCoreTests/Fixtures/session-last-usage.jsonl Tests/UsageCoreTests/Fixtures/session-total-usage.jsonl Tests/UsageCoreTests/Fixtures/session-replayed-prefix.jsonl
rtk git commit -m "[ai] feat(sessions): 增量解析并去重Token事件"
~~~

---

### Task 5: SQLite schema、幂等事件写入与文件游标

**Files:**
- Create: Sources/UsageCore/Persistence/UsageStore.swift
- Create: Sources/UsageCore/Persistence/SQLiteConnection.swift
- Create: Sources/UsageCore/Persistence/SQLiteUsageStore.swift
- Create: Tests/UsageCoreTests/SQLiteUsageStoreTests.swift
- Modify: Tests/UsageCoreTests/TestSupport.swift

**Interfaces:**
- Consumes: LocalDay、TokenBreakdown、SessionTokenEvent、SessionCounterState、QuotaSnapshot、QuotaCycle。
- Produces: StoredUsageEvent、FileCursor、OfficialUsageDay、UsageStore actor protocol、SQLiteUsageStore。

- [ ] **Step 1: 写失败测试，固定事件幂等和数据库重开后的游标**

~~~swift
func testDuplicateSignatureIsInsertedOnlyOnce() async throws {
    let databaseURL = try temporaryDatabaseURL()
    let store = try SQLiteUsageStore(databaseURL: databaseURL)
    try await store.migrate()
    let event = StoredUsageEvent(
        signature: Data(repeating: 7, count: 32),
        occurredAt: Date(timeIntervalSince1970: 1788148800),
        localDay: LocalDay(year: 2026, month: 8, day: 31),
        usage: TokenBreakdown(
            inputTokens: 100,
            cachedInputTokens: 40,
            outputTokens: 20
        )
    )

    let firstCount = try await store.insert(events: [event])
    let secondCount = try await store.insert(events: [event])
    let saved = try await store.events(
        from: Date(timeIntervalSince1970: 1788140000),
        to: Date(timeIntervalSince1970: 1788150000)
    )

    XCTAssertEqual(firstCount, 1)
    XCTAssertEqual(secondCount, 0)
    XCTAssertEqual(saved, [event])
}

func testFileCursorSurvivesDatabaseReopen() async throws {
    let databaseURL = try temporaryDatabaseURL()
    let cursor = FileCursor(
        pathHash: Data(repeating: 9, count: 32),
        deviceID: 12,
        inode: 34,
        committedOffset: 567,
        counterState: SessionCounterState(
            previousTotal: TokenBreakdown(
                inputTokens: 10,
                cachedInputTokens: 4,
                outputTokens: 2
            )
        )
    )

    do {
        let store = try SQLiteUsageStore(databaseURL: databaseURL)
        try await store.migrate()
        try await store.save(cursor: cursor)
    }
    let reopened = try SQLiteUsageStore(databaseURL: databaseURL)
    try await reopened.migrate()

    XCTAssertEqual(
        try await reopened.cursor(for: cursor.pathHash),
        cursor
    )
}

func testOfficialQuotaAndCyclesRoundTrip() async throws {
    let store = try SQLiteUsageStore(
        databaseURL: try temporaryDatabaseURL()
    )
    try await store.migrate()
    let fetchedAt = Date(timeIntervalSince1970: 1_788_148_800)
    let official = OfficialUsageDay(
        day: LocalDay(year: 2026, month: 8, day: 30),
        tokens: 400,
        fetchedAt: fetchedAt
    )
    let quota = QuotaSnapshot(
        limitID: "codex",
        usedPercent: 25,
        windowDurationMinutes: 10_080,
        startsAt: fetchedAt.addingTimeInterval(-300),
        resetsAt: fetchedAt.addingTimeInterval(10_080 * 60 - 300),
        fetchedAt: fetchedAt
    )
    let cycle = QuotaCycle(
        startsAt: quota.startsAt,
        endsAt: quota.resetsAt,
        usage: TokenBreakdown(
            inputTokens: 100,
            cachedInputTokens: 40,
            outputTokens: 20
        ),
        displayedTokens: 500,
        status: .partiallyCalibrated,
        boundaryIsEstimated: false
    )

    try await store.upsert(officialDays: [official])
    try await store.save(quota: quota)
    try await store.replace(cycles: [cycle])

    XCTAssertEqual(try await store.officialDays(), [official])
    XCTAssertEqual(try await store.latestQuota(), quota)
    XCTAssertEqual(try await store.cycles(), [cycle])
}

func testPruneRemovesOldDetailsButKeepsNewDetails() async throws {
    let store = try SQLiteUsageStore(
        databaseURL: try temporaryDatabaseURL()
    )
    try await store.migrate()
    let old = storedEvent(
        at: Date(timeIntervalSince1970: 100),
        input: 10,
        output: 2
    )
    let recent = storedEvent(
        at: Date(timeIntervalSince1970: 300),
        input: 20,
        output: 4
    )
    _ = try await store.insert(events: [old, recent])
    try await store.upsert(
        officialDays: [
            OfficialUsageDay(
                day: LocalDay(year: 2026, month: 7, day: 1),
                tokens: 100,
                fetchedAt: recent.occurredAt
            ),
            OfficialUsageDay(
                day: LocalDay(year: 2026, month: 8, day: 1),
                tokens: 200,
                fetchedAt: recent.occurredAt
            )
        ]
    )

    try await store.pruneUsage(
        eventsBefore: Date(timeIntervalSince1970: 200),
        officialDaysBefore: LocalDay(
            year: 2026,
            month: 8,
            day: 1
        )
    )

    XCTAssertEqual(
        try await store.events(
            from: .distantPast,
            to: .distantFuture
        ),
        [recent]
    )
    XCTAssertEqual(
        try await store.officialDays().map(\.tokens),
        [200]
    )
}
~~~

- [ ] **Step 2: 运行测试并确认 SQLiteUsageStore 缺失**

Run: rtk swift test --filter SQLiteUsageStoreTests

Expected: FAIL，编译器报告 SQLiteUsageStore、StoredUsageEvent 和 FileCursor 不存在。

- [ ] **Step 3: 定义 storage types 与 actor protocol**

~~~swift
public struct StoredUsageEvent: Codable, Equatable, Sendable {
    public let signature: Data
    public let occurredAt: Date
    public let localDay: LocalDay
    public let usage: TokenBreakdown
}

public struct FileCursor: Codable, Equatable, Sendable {
    public let pathHash: Data
    public let deviceID: Int64
    public let inode: Int64
    public let committedOffset: Int64
    public let counterState: SessionCounterState
}

public struct OfficialUsageDay: Codable, Equatable, Sendable {
    public let day: LocalDay
    public let tokens: Int64
    public let fetchedAt: Date
}

public protocol UsageStore: Actor {
    func migrate() throws
    func insert(events: [StoredUsageEvent]) throws -> Int
    func events(from: Date, to: Date) throws -> [StoredUsageEvent]
    func cursor(for pathHash: Data) throws -> FileCursor?
    func save(cursor: FileCursor) throws
    func upsert(officialDays: [OfficialUsageDay]) throws
    func officialDays() throws -> [OfficialUsageDay]
    func save(quota: QuotaSnapshot) throws
    func latestQuota() throws -> QuotaSnapshot?
    func replace(cycles: [QuotaCycle]) throws
    func cycles() throws -> [QuotaCycle]
    func pruneUsage(
        eventsBefore: Date,
        officialDaysBefore: LocalDay
    ) throws
}

public enum SQLiteStoreError: Error, Equatable, Sendable {
    case operationFailed(operation: String, code: Int32)
    case closed
    case tooManyCycles(Int)
}
~~~

同一步修改 TestSupport.swift，加入 import CryptoKit 和以下字面事件 helper：

~~~swift
func storedEvent(
    at occurredAt: Date,
    input: Int64,
    cached: Int64 = 0,
    output: Int64
) -> StoredUsageEvent {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = calendar.dateComponents(
        [.year, .month, .day],
        from: occurredAt
    )
    let signatureText = [
        String(occurredAt.timeIntervalSince1970),
        String(input),
        String(cached),
        String(output)
    ].joined(separator: "|")
    return StoredUsageEvent(
        signature: Data(
            SHA256.hash(data: Data(signatureText.utf8))
        ),
        occurredAt: occurredAt,
        localDay: LocalDay(
            year: components.year!,
            month: components.month!,
            day: components.day!
        ),
        usage: TokenBreakdown(
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output
        )
    )
}
~~~

- [ ] **Step 4: 实现 SQLiteConnection 的严格 C API 包装**

SQLiteConnection：

- sqlite3_open_v2 使用 SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX；
- init 后执行 PRAGMA foreign_keys = ON、PRAGMA journal_mode = WAL、PRAGMA synchronous = NORMAL；
- execute(_:) 只运行无参数 schema SQL；
- prepare(_:) 返回 statement wrapper，支持 Int64、Double、String、Data、NULL 绑定；
- 每个 sqlite3_prepare_v2、bind、step、reset 失败都抛 SQLiteStoreError，其中只含 SQLite 错误码和固定操作名，不包含 SQL 参数；
- deinit finalize statement 并 close_v2 connection。

生产 wrapper 不提供执行任意用户 SQL 的公开接口。

- [ ] **Step 5: 实现确定的 schema migration**

SQLiteUsageStore.migrate() 在一个 transaction 内创建：

~~~sql
CREATE TABLE IF NOT EXISTS file_cursors (
  path_hash BLOB PRIMARY KEY NOT NULL,
  device_id INTEGER NOT NULL,
  inode INTEGER NOT NULL,
  committed_offset INTEGER NOT NULL,
  previous_input_tokens INTEGER,
  previous_cached_input_tokens INTEGER,
  previous_output_tokens INTEGER
);

CREATE TABLE IF NOT EXISTS usage_events (
  signature BLOB PRIMARY KEY NOT NULL,
  occurred_at REAL NOT NULL,
  local_day TEXT NOT NULL,
  input_tokens INTEGER NOT NULL CHECK(input_tokens >= 0),
  cached_input_tokens INTEGER NOT NULL CHECK(cached_input_tokens >= 0),
  output_tokens INTEGER NOT NULL CHECK(output_tokens >= 0)
);

CREATE INDEX IF NOT EXISTS usage_events_occurred_at
ON usage_events(occurred_at);

CREATE INDEX IF NOT EXISTS usage_events_local_day
ON usage_events(local_day);

CREATE TABLE IF NOT EXISTS official_usage_days (
  local_day TEXT PRIMARY KEY NOT NULL,
  tokens INTEGER NOT NULL CHECK(tokens >= 0),
  fetched_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS quota_snapshots (
  fetched_at REAL PRIMARY KEY NOT NULL,
  limit_id TEXT NOT NULL,
  used_percent REAL NOT NULL,
  window_duration_minutes INTEGER NOT NULL,
  starts_at REAL NOT NULL,
  resets_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS quota_cycles (
  starts_at REAL PRIMARY KEY NOT NULL,
  ends_at REAL NOT NULL,
  input_tokens INTEGER NOT NULL,
  cached_input_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  displayed_tokens INTEGER NOT NULL,
  status TEXT NOT NULL,
  boundary_is_estimated INTEGER NOT NULL
);

PRAGMA user_version = 1;
~~~

insert(events:) 使用 INSERT OR IGNORE，并通过 sqlite3_changes 计算实际插入数。replace(cycles:) 单 transaction 删除旧 rows、按 startsAt 升序写入新 rows；调用方传入最多 9 个周期，store 仍校验并拒绝更多记录。

pruneUsage(eventsBefore:officialDaysBefore:) 在单 transaction 中删除 occurred_at 早于 cutoff 的 usage_events，以及 local_day 字典序早于 LocalDay.iso8601 cutoff 的 official_usage_days；不删除 file_cursors，避免旧文件下次扫描时重新累计。

- [ ] **Step 6: 运行 SQLite 测试并验证全部 round-trip**

Run: rtk swift test --filter SQLiteUsageStoreTests

Expected: PASS，重复签名计数为 0，游标、official day、quota、cycle 重开数据库后完全相等。

- [ ] **Step 7: 运行全套测试并提交**

Run: rtk swift test

Expected: PASS，0 failures，编译输出无 warning，临时 WAL/SHM 文件在测试 teardown 后删除。

~~~bash
rtk git add Sources/UsageCore/Persistence Tests/UsageCoreTests/TestSupport.swift Tests/UsageCoreTests/SQLiteUsageStoreTests.swift
rtk git commit -m "[ai] feat(storage): 持久化用量事件和游标"
~~~

---

### Task 6: Codex Home 定位与 session 文件增量索引

**Files:**
- Create: Sources/UsageCore/Sessions/CodexHomeResolver.swift
- Create: Sources/UsageCore/Sessions/SessionFileScanner.swift
- Create: Sources/UsageCore/Sessions/SessionUsageIndexer.swift
- Create: Tests/UsageCoreTests/SessionUsageIndexerTests.swift

**Interfaces:**
- Consumes: SessionLineParser、SessionUsageAccumulator、StoredUsageEvent、FileCursor、UsageStore。
- Produces: CodexHomeResolver.resolve(initializedHome:environment:homeDirectory:)、SessionFileScanner.files(in:modifiedSince:)、SessionUsageIndexer.index(codexHome:modifiedSince:calendar:)。

- [ ] **Step 1: 写失败测试，固定 Codex Home 的安全优先级**

~~~swift
func testResolverPrefersInitializedAbsoluteDirectoryThenEnvironment() throws {
    let root = try temporaryDirectory()
    let initialized = root.appendingPathComponent("initialized")
    let environment = root.appendingPathComponent("environment")
    try FileManager.default.createDirectory(
        at: initialized,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: environment,
        withIntermediateDirectories: true
    )

    let selected = CodexHomeResolver().resolve(
        initializedHome: initialized.path,
        environment: ["CODEX_HOME": environment.path],
        homeDirectory: root
    )

    XCTAssertEqual(selected, initialized)
}

func testResolverRejectsRelativeAndMissingDirectories() throws {
    let root = try temporaryDirectory()

    let selected = CodexHomeResolver().resolve(
        initializedHome: "relative/path",
        environment: ["CODEX_HOME": root.appendingPathComponent("missing").path],
        homeDirectory: root.appendingPathComponent("missing-home")
    )

    XCTAssertNil(selected)
}
~~~

- [ ] **Step 2: 运行测试并确认 CodexHomeResolver 缺失**

Run: rtk swift test --filter SessionUsageIndexerTests/testResolver

Expected: FAIL，编译器报告 CodexHomeResolver 不存在。

- [ ] **Step 3: 实现纯函数式目录解析与确定性扫描**

~~~swift
public struct CodexHomeResolver: Sendable {
    public init() {}

    public func resolve(
        initializedHome: String?,
        environment: [String: String],
        homeDirectory: URL
    ) -> URL? {
        let candidates = [
            initializedHome.map(URL.init(fileURLWithPath:)),
            environment["CODEX_HOME"].map(URL.init(fileURLWithPath:)),
            homeDirectory.appendingPathComponent(".codex")
        ].compactMap { $0 }

        return candidates.first {
            $0.path.hasPrefix("/") && isDirectory($0)
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(
            atPath: url.standardizedFileURL.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }
}
~~~

SessionFileScanner 只递归 codexHome/sessions 与 codexHome/archived_sessions，保留扩展名 jsonl 且 modificationDate >= modifiedSince 的 regular file；结果按标准化绝对路径字典序排序。符号链接不跟随，目录不存在时返回空数组。

- [ ] **Step 4: 写失败索引测试，固定完整行 offset、半行和重复扫描**

~~~swift
func testIndexerCommitsOnlyCompleteLinesAndIsIdempotent() async throws {
    let root = try temporaryCodexHome()
    let session = root
        .appendingPathComponent("sessions")
        .appendingPathComponent("rollout.jsonl")
    let complete = tokenLine(
        timestamp: "2026-08-31T01:00:00.000Z",
        input: 100,
        cached: 40,
        output: 20
    )
    let partial = tokenLine(
        timestamp: "2026-08-31T01:01:00.000Z",
        input: 30,
        cached: 10,
        output: 5
    )
    try Data((complete + "\n" + partial).utf8).write(to: session)
    let store = try SQLiteUsageStore(
        databaseURL: try temporaryDatabaseURL()
    )
    try await store.migrate()
    let indexer = SessionUsageIndexer(store: store)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

    let first = try await indexer.index(
        codexHome: root,
        modifiedSince: .distantPast,
        calendar: calendar
    )
    let handle = try FileHandle(forWritingTo: session)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\n".utf8))
    try handle.close()
    let second = try await indexer.index(
        codexHome: root,
        modifiedSince: .distantPast,
        calendar: calendar
    )
    let third = try await indexer.index(
        codexHome: root,
        modifiedSince: .distantPast,
        calendar: calendar
    )

    XCTAssertEqual(first.insertedEventCount, 1)
    XCTAssertEqual(second.insertedEventCount, 1)
    XCTAssertEqual(third.insertedEventCount, 0)
}
~~~

再写两个具体测试：

~~~swift
func testTruncatedFileRestartsAtZeroWithoutLosingNewEvent() async throws {
    let root = try temporaryCodexHome()
    let session = root
        .appendingPathComponent("sessions")
        .appendingPathComponent("truncated.jsonl")
    try Data(
        (
            tokenLine(
                timestamp: "2026-08-31T01:00:00.000Z",
                input: 1_000,
                cached: 400,
                output: 200
            ) + "\n"
        ).utf8
    ).write(to: session)
    let store = try SQLiteUsageStore(
        databaseURL: try temporaryDatabaseURL()
    )
    try await store.migrate()
    let indexer = SessionUsageIndexer(store: store)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    _ = try await indexer.index(
        codexHome: root,
        modifiedSince: .distantPast,
        calendar: calendar
    )
    try Data(
        (
            tokenLine(
                timestamp: "2026-08-31T01:01:00.000Z",
                input: 5,
                cached: 2,
                output: 1
            ) + "\n"
        ).utf8
    ).write(to: session, options: .atomic)

    let result = try await indexer.index(
        codexHome: root,
        modifiedSince: .distantPast,
        calendar: calendar
    )

    XCTAssertEqual(result.insertedEventCount, 1)
}

func testArchivedReplayDoesNotIncreaseEventCount() async throws {
    let root = try temporaryCodexHome()
    let line = tokenLine(
        timestamp: "2026-08-31T01:00:00.000Z",
        input: 100,
        cached: 40,
        output: 20
    ) + "\n"
    try Data(line.utf8).write(
        to: root
            .appendingPathComponent("sessions")
            .appendingPathComponent("active.jsonl")
    )
    let store = try SQLiteUsageStore(
        databaseURL: try temporaryDatabaseURL()
    )
    try await store.migrate()
    let indexer = SessionUsageIndexer(store: store)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    _ = try await indexer.index(
        codexHome: root,
        modifiedSince: .distantPast,
        calendar: calendar
    )
    try Data(line.utf8).write(
        to: root
            .appendingPathComponent("archived_sessions")
            .appendingPathComponent("archived.jsonl")
    )

    let replay = try await indexer.index(
        codexHome: root,
        modifiedSince: .distantPast,
        calendar: calendar
    )

    XCTAssertEqual(replay.insertedEventCount, 0)
}
~~~

- [ ] **Step 5: 运行索引测试并确认 SessionUsageIndexer 缺失**

Run: rtk swift test --filter SessionUsageIndexerTests/testIndexer

Expected: FAIL，编译器报告 SessionUsageIndexer 不存在。

- [ ] **Step 6: 实现 path hash、文件 identity 和增量读取**

公开结果：

~~~swift
public struct SessionIndexResult: Equatable, Sendable {
    public let scannedFileCount: Int
    public let insertedEventCount: Int
}

public actor SessionUsageIndexer {
    public init(store: any UsageStore)

    public func index(
        codexHome: URL,
        modifiedSince: Date,
        calendar: Calendar
    ) async throws -> SessionIndexResult
}
~~~

实现顺序：

1. scanner 产生稳定文件列表；
2. 对标准化绝对路径计算 SHA-256 pathHash，不保存原路径；
3. 用 Darwin.stat 获取 st_dev、st_ino、st_size；
4. identity 相同且 size >= offset 时从 cursor.committedOffset 读取，否则从 0 和空 counter state 开始；
5. 每次只把最后一个换行前的数据交给 SessionLineParser，尾部半行不写数据库；
6. 用传入 Calendar 把 occurredAt 转成 LocalDay，构造 StoredUsageEvent；
7. 先在一个 store transaction 中插入事件，再保存指向最后完整换行后的 cursor；
8. 如果 transaction 失败，事件和 cursor 都不改变。

为保证第 7 条，UsageStore 增加 ingest(events:cursor:) 原子方法；SQLiteUsageStore 在单一 BEGIN IMMEDIATE transaction 内执行 INSERT OR IGNORE 和 cursor UPSERT。原先 insert(events:) 继续供独立测试和导入使用。

- [ ] **Step 7: 运行索引、SQLite 和全套测试**

Run: rtk swift test --filter SessionUsageIndexerTests

Expected: PASS，半行第二次补换行后只入库一次。

Run: rtk swift test --filter SQLiteUsageStoreTests

Expected: PASS，新增原子 ingest 不破坏 round-trip。

Run: rtk swift test

Expected: PASS，0 failures，编译输出无 warning。

- [ ] **Step 8: 提交 resolver 与 indexer**

~~~bash
rtk git add Sources/UsageCore/Sessions Sources/UsageCore/Persistence/UsageStore.swift Sources/UsageCore/Persistence/SQLiteUsageStore.swift Tests/UsageCoreTests/SessionUsageIndexerTests.swift Tests/UsageCoreTests/SQLiteUsageStoreTests.swift
rtk git commit -m "[ai] feat(indexer): 增量索引本机Session用量"
~~~

---

### Task 7: 真实额度周期跟踪与本机/官方用量校准

**Files:**
- Create: Sources/UsageCore/Reconciliation/CycleTracker.swift
- Create: Sources/UsageCore/Reconciliation/UsageReconciler.swift
- Create: Tests/UsageCoreTests/CycleTrackerTests.swift
- Create: Tests/UsageCoreTests/UsageReconcilerTests.swift

**Interfaces:**
- Consumes: QuotaSnapshot、StoredUsageEvent、OfficialUsageDay、UsageDay、QuotaCycle。
- Produces: CycleTracker.update(existing:quota:events:)、UsageReconciler.snapshot(now:calendar:quota:events:officialDays:cycles:lastUpdatedAt:)。

- [ ] **Step 1: 写失败周期测试，固定自然重置、提前重置和历史上限**

~~~swift
func testNewDerivedStartClosesPreviousCycleAndStartsAnother() {
    let oldStart = Date(timeIntervalSince1970: 1_000_000)
    let oldEnd = oldStart.addingTimeInterval(10_080 * 60)
    let old = QuotaCycle(
        startsAt: oldStart,
        endsAt: oldEnd,
        usage: .zero,
        displayedTokens: 0,
        status: .localLive,
        boundaryIsEstimated: false
    )
    let newStart = oldStart.addingTimeInterval(3 * 24 * 60 * 60)
    let quota = QuotaSnapshot(
        limitID: "codex",
        usedPercent: 0,
        windowDurationMinutes: 10_080,
        startsAt: newStart,
        resetsAt: newStart.addingTimeInterval(10_080 * 60),
        fetchedAt: newStart.addingTimeInterval(30)
    )

    let cycles = CycleTracker().update(
        existing: [old],
        quota: quota,
        events: []
    )

    XCTAssertEqual(cycles.count, 2)
    XCTAssertEqual(cycles[0].endsAt, newStart)
    XCTAssertEqual(cycles[1].startsAt, newStart)
}

func testKeepsCurrentAndEightCompletedCycles() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    let duration = TimeInterval(10_080 * 60)
    let cycles = (0..<12).map { index in
        let start = base.addingTimeInterval(
            TimeInterval(index) * duration
        )
        return QuotaCycle(
            startsAt: start,
            endsAt: start.addingTimeInterval(duration),
            usage: .zero,
            displayedTokens: 0,
            status: .localLive,
            boundaryIsEstimated: false
        )
    }
    let current = cycles[11]
    let quota = QuotaSnapshot(
        limitID: "codex",
        usedPercent: 20,
        windowDurationMinutes: 10_080,
        startsAt: current.startsAt,
        resetsAt: current.endsAt,
        fetchedAt: current.startsAt.addingTimeInterval(30)
    )

    let retained = CycleTracker().update(
        existing: cycles,
        quota: quota,
        events: []
    )

    XCTAssertEqual(retained.count, 9)
    XCTAssertEqual(retained.last?.startsAt, quota.startsAt)
}
~~~

- [ ] **Step 2: 运行周期测试并确认 CycleTracker 缺失**

Run: rtk swift test --filter CycleTrackerTests

Expected: FAIL，编译器报告 CycleTracker 不存在。

- [ ] **Step 3: 实现按推导起点识别周期的 tracker**

~~~swift
public struct CycleTracker: Sendable {
    public init() {}

    public func update(
        existing: [QuotaCycle],
        quota: QuotaSnapshot,
        events: [StoredUsageEvent]
    ) -> [QuotaCycle]
}
~~~

算法：

- startsAt 相差不超过 1 秒视为同一周期，只更新 endsAt 和区间事件总量；
- 新 startsAt 晚于当前 startsAt 超过 1 秒时，把当前 endsAt 截到新 startsAt，再创建当前周期；
- 新 startsAt 早于当前 startsAt 时不倒退历史，保留现有周期并更新匹配区间的用量；
- 每个周期 usage 只汇总 startsAt <= occurredAt < endsAt 的本机事件，新建或更新时 displayedTokens 先等于 usage.totalTokens；
- 按 startsAt 升序排序，保留最后 9 条。

- [ ] **Step 4: 运行周期测试**

Run: rtk swift test --filter CycleTrackerTests

Expected: PASS。

- [ ] **Step 5: 写失败校准测试，固定今天、本地历史日和官方完整日**

~~~swift
func testOfficialBucketReplacesOnlyCompletedNaturalDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let now = try date("2026-08-31T12:00:00+08:00")
    let events = [
        storedEvent(
            at: try date("2026-08-30T10:00:00+08:00"),
            input: 100,
            output: 20
        ),
        storedEvent(
            at: try date("2026-08-31T10:00:00+08:00"),
            input: 200,
            output: 30
        )
    ]
    let official = [
        OfficialUsageDay(
            day: LocalDay(year: 2026, month: 8, day: 30),
            tokens: 500,
            fetchedAt: now
        ),
        OfficialUsageDay(
            day: LocalDay(year: 2026, month: 8, day: 31),
            tokens: 900,
            fetchedAt: now
        )
    ]

    let snapshot = UsageReconciler().snapshot(
        now: now,
        calendar: calendar,
        quota: nil,
        events: events,
        officialDays: official,
        cycles: [],
        lastUpdatedAt: now
    )

    XCTAssertEqual(snapshot.today.displayedTokens, 230)
    XCTAssertEqual(snapshot.today.status, .localLive)
    XCTAssertEqual(snapshot.recentDays.last { $0.day.day == 30 }?.displayedTokens, 500)
    XCTAssertEqual(snapshot.recentDays.last { $0.day.day == 30 }?.status, .calibrated)
    XCTAssertEqual(snapshot.status, .unavailable)
}
~~~

再添加两个具体测试：

~~~swift
func testRecentDaysDoNotSkipDateAcrossDaylightSavingTransition() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(
        identifier: "America/Los_Angeles"
    )!
    let now = try date("2026-03-09T00:30:00-07:00")

    let snapshot = UsageReconciler().snapshot(
        now: now,
        calendar: calendar,
        quota: nil,
        events: [],
        officialDays: [],
        cycles: [],
        lastUpdatedAt: now
    )

    XCTAssertEqual(
        snapshot.recentDays.map(\.day.iso8601),
        [
            "2026-03-03",
            "2026-03-04",
            "2026-03-05",
            "2026-03-06",
            "2026-03-07",
            "2026-03-08",
            "2026-03-09"
        ]
    )
}

func testMiddayCycleBoundaryUsesLocalEventsNotWholeOfficialDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let startsAt = try date("2026-08-28T12:00:00+08:00")
    let endsAt = try date("2026-09-04T12:00:00+08:00")
    let now = try date("2026-08-31T12:00:00+08:00")
    let event = StoredUsageEvent(
        signature: Data([1]),
        occurredAt: try date("2026-08-28T13:00:00+08:00"),
        localDay: LocalDay(year: 2026, month: 8, day: 28),
        usage: TokenBreakdown(
            inputTokens: 100,
            cachedInputTokens: 40,
            outputTokens: 20
        )
    )
    let cycle = QuotaCycle(
        startsAt: startsAt,
        endsAt: endsAt,
        usage: event.usage,
        displayedTokens: 120,
        status: .localLive,
        boundaryIsEstimated: false
    )
    let quota = QuotaSnapshot(
        limitID: "codex",
        usedPercent: 30,
        windowDurationMinutes: 10_080,
        startsAt: startsAt,
        resetsAt: endsAt,
        fetchedAt: now
    )
    let official = OfficialUsageDay(
        day: LocalDay(year: 2026, month: 8, day: 28),
        tokens: 1_000,
        fetchedAt: now
    )

    let snapshot = UsageReconciler().snapshot(
        now: now,
        calendar: calendar,
        quota: quota,
        events: [event],
        officialDays: [official],
        cycles: [cycle],
        lastUpdatedAt: now
    )

    XCTAssertEqual(snapshot.currentCycle?.displayedTokens, 120)
    XCTAssertEqual(
        snapshot.currentCycle?.status,
        .partiallyCalibrated
    )
}
~~~

- [ ] **Step 6: 运行校准测试并确认 UsageReconciler 缺失**

Run: rtk swift test --filter UsageReconcilerTests

Expected: FAIL，编译器报告 UsageReconciler 不存在。

- [ ] **Step 7: 实现自然日与周期两种聚合口径**

~~~swift
public struct UsageReconciler: Sendable {
    public init() {}

    public func snapshot(
        now: Date,
        calendar: Calendar,
        quota: QuotaSnapshot?,
        events: [StoredUsageEvent],
        officialDays: [OfficialUsageDay],
        cycles: [QuotaCycle],
        lastUpdatedAt: Date
    ) -> UsageSnapshot
}
~~~

实现规则：

- 先按 StoredUsageEvent.localDay 聚合本机 TokenBreakdown；
- recentDays 固定生成包含今天在内的 7 个本地自然日，缺失日使用零值；
- day < today 且有 official bucket 时 displayedTokens 使用 official tokens、status calibrated；
- today 永远使用 local usage、status localLive；
- currentCycle 只接受 startsAt <= now < endsAt 的 cycle；
- cycle 首尾日期只要不是本地 midnight 就标 partiallyCalibrated；完整中间日期可用官方 tokens 替代本机 total，但 input/cached/output 明细继续保留本机数值，校准后的总量写入 QuotaCycle.displayedTokens；
- quota 为 nil 时整体 status unavailable；quota fetchedAt 距 now 超过 10 分钟时整体 status stale；其他情况取 currentCycle/day 的最弱校准状态；
- cycleHistory 只返回已结束的最近 8 条，按 startsAt 降序。

- [ ] **Step 8: 运行 Task 7 与全套测试并提交**

Run: rtk swift test --filter CycleTrackerTests

Expected: PASS。

Run: rtk swift test --filter UsageReconcilerTests

Expected: PASS，包含时区与 DST fixture。

Run: rtk swift test

Expected: PASS，0 failures，编译输出无 warning。

~~~bash
rtk git add Sources/UsageCore/Reconciliation Tests/UsageCoreTests/CycleTrackerTests.swift Tests/UsageCoreTests/UsageReconcilerTests.swift
rtk git commit -m "[ai] feat(reconcile): 校准自然日和额度周期"
~~~

---

### Task 8: FSEvents 变更流、刷新策略与 UsageService

**Files:**
- Create: Sources/UsageCore/Sessions/SessionDirectoryWatcher.swift
- Create: Sources/UsageCore/Coordination/RefreshPolicy.swift
- Create: Sources/UsageCore/Coordination/UsageService.swift
- Create: Tests/UsageCoreTests/RefreshPolicyTests.swift
- Create: Tests/UsageCoreTests/UsageServiceTests.swift

**Interfaces:**
- Consumes: CodexAppServerClient、CodexHomeResolver、WeeklyQuotaSelector、SessionUsageIndexer、UsageStore、CycleTracker、UsageReconciler。
- Produces: SessionDirectoryWatcher.changes(for:)、RefreshReason、RefreshDecision、RefreshPolicy.decision(now:reason:lastQuotaRefresh:lastOfficialRefresh:consecutiveFailures:)、UsageService.refresh(reason:now:)、UsageService.processNextAccountNotification(now:)、UsageService.currentSnapshot(now:)。

- [ ] **Step 1: 写失败策略测试，固定三种刷新频率和退避上限**

~~~swift
func testPopoverRefreshesMinuteOldQuotaButNotFreshOfficialUsage() {
    let now = Date(timeIntervalSince1970: 10_000)
    let decision = RefreshPolicy().decision(
        now: now,
        reason: .popoverOpened,
        lastQuotaRefresh: now.addingTimeInterval(-61),
        lastOfficialRefresh: now.addingTimeInterval(-120),
        consecutiveFailures: 0
    )

    XCTAssertTrue(decision.refreshQuota)
    XCTAssertFalse(decision.refreshOfficialUsage)
    XCTAssertTrue(decision.indexSessions)
}

func testScheduledRefreshUsesFiveAndThirtyMinuteIntervals() {
    let now = Date(timeIntervalSince1970: 10_000)
    let decision = RefreshPolicy().decision(
        now: now,
        reason: .scheduled,
        lastQuotaRefresh: now.addingTimeInterval(-301),
        lastOfficialRefresh: now.addingTimeInterval(-1_801),
        consecutiveFailures: 0
    )

    XCTAssertTrue(decision.refreshQuota)
    XCTAssertTrue(decision.refreshOfficialUsage)
}

func testBackoffCapsAtFifteenMinutes() {
    XCTAssertEqual(
        RefreshPolicy().retryDelay(consecutiveFailures: 20),
        .seconds(900)
    )
}
~~~

- [ ] **Step 2: 运行策略测试并确认 RefreshPolicy 缺失**

Run: rtk swift test --filter RefreshPolicyTests

Expected: FAIL，编译器报告 RefreshPolicy 不存在。

- [ ] **Step 3: 实现无定时器副作用的纯策略**

~~~swift
public enum RefreshReason: Sendable {
    case startup
    case scheduled
    case popoverOpened
    case wake
    case sessionFilesChanged
    case manual
}

public struct RefreshDecision: Equatable, Sendable {
    public let refreshQuota: Bool
    public let refreshOfficialUsage: Bool
    public let indexSessions: Bool
}

public struct RefreshPolicy: Sendable {
    public init() {}

    public func decision(
        now: Date,
        reason: RefreshReason,
        lastQuotaRefresh: Date?,
        lastOfficialRefresh: Date?,
        consecutiveFailures: Int
    ) -> RefreshDecision

    public func retryDelay(
        consecutiveFailures: Int
    ) -> Duration
}
~~~

规则：startup、wake、manual 三项全 true；sessionFilesChanged 只 index；scheduled 分别以 300 秒和 1800 秒判断；popoverOpened 始终 index，quota 超过 60 秒才读，official 仍按 1800 秒。retryDelay 为 min(30 * 2^failures, 900) 秒，使用移位前先把 failures 夹到 0...5 防止整数溢出。

- [ ] **Step 4: 运行策略测试**

Run: rtk swift test --filter RefreshPolicyTests

Expected: PASS。

- [ ] **Step 5: 写失败 UsageService 测试，固定成功刷新和失败保留旧值**

~~~swift
func testRefreshPersistsRemoteDataIndexesSessionsAndBuildsSnapshot() async throws {
    let fixture = try await ServiceFixture.make()
    let now = Date(timeIntervalSince1970: 1788148800)

    let snapshot = try await fixture.service.refresh(
        reason: .startup,
        now: now
    )

    XCTAssertEqual(snapshot.quota?.remainingPercent, 75)
    XCTAssertEqual(snapshot.today.displayedTokens, 120)
    XCTAssertEqual(
        try await fixture.store.officialDays().first?.tokens,
        400
    )
}

func testRemoteFailureKeepsLastQuotaAndMarksSnapshotStale() async throws {
    let fixture = try await ServiceFixture.make()
    let firstNow = Date(timeIntervalSince1970: 1788148800)
    _ = try await fixture.service.refresh(
        reason: .startup,
        now: firstNow
    )
    await fixture.accountClient.setFailure(
        RPCErrorPayload(
            code: -32600,
            message: "authentication required",
            data: nil
        )
    )

    let snapshot = try await fixture.service.refresh(
        reason: .manual,
        now: firstNow.addingTimeInterval(601)
    )

    XCTAssertEqual(snapshot.quota?.remainingPercent, 75)
    XCTAssertEqual(snapshot.status, .stale)
}

func testSparseNotificationMergesWithLastFullQuota() async throws {
    let fixture = try await ServiceFixture.make()
    let now = Date(timeIntervalSince1970: 1788148800)
    _ = try await fixture.service.refresh(
        reason: .startup,
        now: now
    )
    let update = try JSONDecoder().decode(
        RateLimitsUpdatedParams.self,
        from: Data(
            #"{"rateLimits":{"primary":{"usedPercent":31}}}"#.utf8
        )
    )
    await fixture.accountClient.enqueue(
        .rateLimitsUpdated(update)
    )

    let snapshot = try await fixture.service
        .processNextAccountNotification(
            now: now.addingTimeInterval(5)
        )

    XCTAssertEqual(snapshot?.quota?.remainingPercent, 69)
    XCTAssertEqual(
        snapshot?.quota?.windowDurationMinutes,
        10_080
    )
}
~~~

ServiceFixture 使用真实临时 SQLiteUsageStore 和真实 SessionUsageIndexer；只把外部账户读取边界替换为返回完整官方 JSON 形状的 FakeAccountUsageClient actor。断言只检查真实 UsageService、SQLite 和 indexer 的结果，不检查 fake 调用次数。

UsageServiceTests.swift 中的 fixture 具体实现为：

~~~swift
actor FakeAccountUsageClient: AccountUsageReading {
    let initialized: InitializeResult
    let limits: RateLimitsResponse
    let usage: AccountUsageResponse
    private var failure: RPCErrorPayload?
    private var queuedNotifications: [AppServerNotification] = []

    init(
        initialized: InitializeResult,
        limits: RateLimitsResponse,
        usage: AccountUsageResponse
    ) {
        self.initialized = initialized
        self.limits = limits
        self.usage = usage
    }

    func initialize() async throws -> InitializeResult {
        initialized
    }

    func readRateLimits() async throws -> RateLimitsResponse {
        if let failure {
            throw failure
        }
        return limits
    }

    func readAccountUsage() async throws -> AccountUsageResponse {
        if let failure {
            throw failure
        }
        return usage
    }

    func nextNotification() async -> AppServerNotification? {
        guard !queuedNotifications.isEmpty else {
            return nil
        }
        return queuedNotifications.removeFirst()
    }

    func setFailure(_ value: RPCErrorPayload?) {
        failure = value
    }

    func enqueue(_ value: AppServerNotification) {
        queuedNotifications.append(value)
    }
}

struct ServiceFixture {
    let service: UsageService
    let store: SQLiteUsageStore
    let accountClient: FakeAccountUsageClient

    static func make() async throws -> ServiceFixture {
        let codexHome = try temporaryCodexHome()
        let session = codexHome
            .appendingPathComponent("sessions")
            .appendingPathComponent("service.jsonl")
        try Data(
            (
                tokenLine(
                    timestamp: "2026-08-31T01:00:00.000Z",
                    input: 100,
                    cached: 40,
                    output: 20
                ) + "\n"
            ).utf8
        ).write(to: session)
        let store = try SQLiteUsageStore(
            databaseURL: try temporaryDatabaseURL()
        )
        let client = FakeAccountUsageClient(
            initialized: InitializeResult(
                codexHome: codexHome.path,
                platformFamily: "unix",
                platformOs: "macos",
                userAgent: "test"
            ),
            limits: RateLimitsResponse(
                rateLimits: RateLimitBucket(
                    limitId: "codex",
                    limitName: nil,
                    primary: RateLimitWindow(
                        usedPercent: 25,
                        windowDurationMins: 10_080,
                        resetsAt: 1_788_753_600
                    ),
                    secondary: nil
                ),
                rateLimitsByLimitId: nil
            ),
            usage: AccountUsageResponse(
                summary: AccountUsageSummary(
                    lifetimeTokens: 1_234,
                    peakDailyTokens: 500,
                    longestRunningTurnSec: 30,
                    currentStreakDays: 2,
                    longestStreakDays: 4
                ),
                dailyUsageBuckets: [
                    AccountTokenUsageDailyBucket(
                        startDate: "2026-08-30",
                        tokens: 400
                    )
                ]
            )
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let service = UsageService(
            accountClient: client,
            indexer: SessionUsageIndexer(store: store),
            store: store,
            environment: [:],
            homeDirectory: codexHome.deletingLastPathComponent(),
            calendar: calendar
        )
        return ServiceFixture(
            service: service,
            store: store,
            accountClient: client
        )
    }
}
~~~

- [ ] **Step 6: 运行服务测试并确认 UsageService 缺失**

Run: rtk swift test --filter UsageServiceTests

Expected: FAIL，编译器报告 UsageService 不存在。

- [ ] **Step 7: 定义外部边界协议并让生产类型适配**

~~~swift
public protocol AccountUsageReading: Actor {
    func initialize() async throws -> InitializeResult
    func readRateLimits() async throws -> RateLimitsResponse
    func readAccountUsage() async throws -> AccountUsageResponse
    func nextNotification() async -> AppServerNotification?
}

public protocol SessionUsageIndexing: Actor {
    func index(
        codexHome: URL,
        modifiedSince: Date,
        calendar: Calendar
    ) async throws -> SessionIndexResult
}
~~~

CodexAppServerClient 遵循 AccountUsageReading；SessionUsageIndexer 遵循 SessionUsageIndexing。协议只公开 UsageService 实际需要的方法。

- [ ] **Step 8: 实现 UsageService actor**

~~~swift
public actor UsageService {
    public init(
        accountClient: any AccountUsageReading,
        indexer: any SessionUsageIndexing,
        store: any UsageStore,
        environment: [String: String],
        homeDirectory: URL,
        calendar: Calendar,
        policy: RefreshPolicy = RefreshPolicy()
    )

    public func refresh(
        reason: RefreshReason,
        now: Date
    ) async throws -> UsageSnapshot

    public func processNextAccountNotification(
        now: Date
    ) async throws -> UsageSnapshot?

    public func currentSnapshot(
        now: Date
    ) async throws -> UsageSnapshot
}
~~~

refresh 执行顺序：

1. 每个 service 实例首次刷新调用 store.migrate()，成功后不重复 migration；
2. 首次调用 initialize，保存可选 codexHome；后续不重复握手；
3. RefreshPolicy 决定远端读取和本机 index；
4. 完整 rate-limit 响应经 WeeklyQuotaSelector 选择后写 store；nil 周窗口不覆盖旧 quota；
5. AccountUsageResponse.dailyUsageBuckets 非 nil 时按 yyyy-MM-dd 严格解析为 LocalDay 并 upsert；单个非法日期忽略且计为该刷新失败，但不删除旧日桶；
6. resolver 得到目录后 index 最近 56 天；目录不可用不阻止读取已保存事件；
7. 从 store 读取最近 56 天事件、official days、quota 和 cycles；
8. CycleTracker 更新并保存周期；如已有 9 个保留周期，以最早周期 startsAt 及其 LocalDay 调用 pruneUsage；
9. UsageReconciler 生成 snapshot；
10. 任一远端请求失败时保留旧 quota/official days，增加 consecutiveFailures，并把返回 snapshot 标 stale；只有数据库损坏或 migration 失败才向调用方抛错；
11. 成功远端刷新把 consecutiveFailures 归零并记录对应刷新时间。

currentSnapshot 只读 store 并 reconcile，不启动进程、不扫描文件、不访问网络。

processNextAccountNotification 等待 accountClient.nextNotification()：other 返回 nil；rateLimitsUpdated 与内存中的最后一次完整 RateLimitsResponse 合并，重新选择周窗口并写 store。若尚无完整响应或合并后无法选择周窗口，立即执行一次完整 readRateLimits()；App 壳在独立 Task 中循环调用此方法，从而及时消费稀疏通知。

- [ ] **Step 9: 实现 FSEvents 的合并变更流**

~~~swift
public actor SessionDirectoryWatcher {
    public init(coalescingDelay: Duration = .seconds(1))

    public func changes(
        for directories: [URL]
    ) -> AsyncStream<Void>

    public func stop()
}
~~~

使用 FSEventStreamCreate，flags 包含 kFSEventStreamCreateFlagFileEvents 和 kFSEventStreamCreateFlagUseCFTypes；只监听现存的 sessions 与 archived_sessions。任一事件先触发一次 continuation，随后 1 秒内的事件合并为一次；stop 必须 stop、invalidate、release stream 并 finish continuation。第二阶段 App 壳收到一次 Void 后调用 refresh(reason: .sessionFilesChanged, now:)。

在 UsageServiceTests 增加临时目录集成测试：

~~~swift
func testDirectoryWatcherEmitsAndStopsCleanly() async throws {
    let directory = try temporaryDirectory()
    let watcher = SessionDirectoryWatcher(
        coalescingDelay: .milliseconds(50)
    )
    let stream = await watcher.changes(
        for: [directory]
    )
    let first = expectation(description: "first change")
    let unexpectedSecond = expectation(
        description: "no event after stop"
    )
    unexpectedSecond.isInverted = true
    let consumer = Task {
        var count = 0
        for await _ in stream {
            count += 1
            if count == 1 {
                first.fulfill()
            } else {
                unexpectedSecond.fulfill()
            }
        }
    }
    try Data("one\n".utf8).write(
        to: directory.appendingPathComponent("one.jsonl")
    )
    await fulfillment(of: [first], timeout: 2)

    await watcher.stop()
    try Data("two\n".utf8).write(
        to: directory.appendingPathComponent("two.jsonl")
    )
    await fulfillment(
        of: [unexpectedSecond],
        timeout: 0.3
    )
    consumer.cancel()
}
~~~

- [ ] **Step 10: 运行 Task 8 与全套测试并提交**

Run: rtk swift test --filter RefreshPolicyTests

Expected: PASS。

Run: rtk swift test --filter UsageServiceTests

Expected: PASS，远端失败测试保留 75% quota 并返回 stale。

Run: rtk swift test

Expected: PASS，0 failures，编译输出无 warning，FSEventStream 在测试结束后释放。

~~~bash
rtk git add Sources/UsageCore/Coordination Sources/UsageCore/Sessions/SessionDirectoryWatcher.swift Sources/UsageCore/AppServer/CodexAppServerClient.swift Sources/UsageCore/Sessions/SessionUsageIndexer.swift Tests/UsageCoreTests/RefreshPolicyTests.swift Tests/UsageCoreTests/UsageServiceTests.swift
rtk git commit -m "[ai] feat(service): 编排刷新和用量快照"
~~~

---

### Task 9: 隐私回归、文档和第一阶段整体验收

**Files:**
- Create: Tests/UsageCoreTests/PrivacyBoundaryTests.swift
- Create: README.md
- Modify: Sources/UsageCore/Persistence/UsageStore.swift
- Modify: Sources/UsageCore/Persistence/SQLiteUsageStore.swift

**Interfaces:**
- Consumes: 完整 UsageCore public API。
- Produces: UsageStore.close()、第一阶段使用说明和可重复验收命令。

- [ ] **Step 1: 写失败隐私测试，证明消息正文不会进入事件、快照或 SQLite 文件**

~~~swift
func testMessageBodyNeverReachesStoredArtifacts() async throws {
    let secret = "PRIVATE_PROMPT_7E9D4A"
    let root = try temporaryCodexHome()
    let session = root
        .appendingPathComponent("sessions")
        .appendingPathComponent("privacy.jsonl")
    let content = [
        #"{"timestamp":"2026-08-31T01:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"PRIVATE_PROMPT_7E9D4A"}}"#,
        tokenLine(
            timestamp: "2026-08-31T01:01:00.000Z",
            input: 100,
            cached: 40,
            output: 20
        )
    ].joined(separator: "\n") + "\n"
    try Data(content.utf8).write(to: session)
    let databaseURL = try temporaryDatabaseURL()
    let store = try SQLiteUsageStore(databaseURL: databaseURL)
    try await store.migrate()
    let indexer = SessionUsageIndexer(store: store)
    _ = try await indexer.index(
        codexHome: root,
        modifiedSince: .distantPast,
        calendar: Calendar(identifier: .gregorian)
    )
    let events = try await store.events(
        from: .distantPast,
        to: .distantFuture
    )
    try await store.close()

    let encodedEvents = try JSONEncoder().encode(events)
    let databaseBytes = try Data(contentsOf: databaseURL)
    XCTAssertNil(
        String(data: encodedEvents, encoding: .utf8)?
            .range(of: secret)
    )
    XCTAssertNil(databaseBytes.range(of: Data(secret.utf8)))
}
~~~

再写一个具体失败测试，证明 resolver/indexer 不打开 auth.json：

~~~swift
func testResolverAndIndexerNeverOpenAuthJSON() async throws {
    let root = try temporaryDirectory()
    let auth = root.appendingPathComponent("auth.json")
    try Data("PRIVATE_TOKEN".utf8).write(to: auth)
    XCTAssertEqual(chmod(auth.path, 0), 0)
    defer {
        chmod(auth.path, S_IRUSR | S_IWUSR)
    }
    let resolved = CodexHomeResolver().resolve(
        initializedHome: root.path,
        environment: [:],
        homeDirectory: root.deletingLastPathComponent()
    )
    let store = try SQLiteUsageStore(
        databaseURL: try temporaryDatabaseURL()
    )
    try await store.migrate()
    let indexer = SessionUsageIndexer(store: store)

    let result = try await indexer.index(
        codexHome: try XCTUnwrap(resolved),
        modifiedSince: .distantPast,
        calendar: Calendar(identifier: .gregorian)
    )

    XCTAssertEqual(result.scannedFileCount, 0)
    XCTAssertEqual(result.insertedEventCount, 0)
}
~~~

PrivacyBoundaryTests.swift import Darwin 取得 chmod、S_IRUSR 和 S_IWUSR；defer 在临时目录清理前恢复权限。

- [ ] **Step 2: 运行隐私测试并确认 close API 缺失或数据库仍占用**

Run: rtk swift test --filter PrivacyBoundaryTests

Expected: FAIL，编译器报告 UsageStore 没有 close，或数据库连接未关闭导致读取边界测试不满足。

- [ ] **Step 3: 增加真实生命周期所需的 close**

UsageStore actor protocol 增加 func close() throws。SQLiteUsageStore.close() 执行 PRAGMA wal_checkpoint(TRUNCATE)，finalize 所有 cached statements 并 sqlite3_close_v2；重复调用安全返回。第二阶段 App 退出时也调用该 API，因此它不是测试专用方法。

- [ ] **Step 4: 运行隐私测试**

Run: rtk swift test --filter PrivacyBoundaryTests

Expected: PASS，数据库、编码事件和测试输出不含 secret。

- [ ] **Step 5: 写 README 的可执行使用说明**

README 必须包含：

- 产品目标和菜单栏第二阶段状态；
- 当前第一阶段目录结构；
- 环境要求：Apple Silicon、macOS 13+、Swift 6.2+；
- rtk swift test 和 rtk swift build -c release；
- app-server 只读接口：initialize、account/rateLimits/read、account/usage/read；
- 明确隐私边界与不读取 auth.json；
- Xcode 16+、license 和 App 壳为第二阶段前置条件；
- 指向设计文档和本实施计划的相对链接。

- [ ] **Step 6: 运行格式、测试和 release build 验收**

Run: rtk swift package dump-package

Expected: exit 0，platform 显示 macos 13.0，products 只含 UsageCore。

Run: rtk swift test

Expected: PASS，全部 tests，0 failures，编译输出无 warning。

Run: rtk swift build -c release

Expected: exit 0，生成 arm64-apple-macosx release library，编译输出无 warning。

Run: rtk git status --short

Expected: 只显示 README.md、PrivacyBoundaryTests.swift 和 close API 对应的本任务文件。

- [ ] **Step 7: 提交第一阶段验收**

~~~bash
rtk git add README.md Tests/UsageCoreTests/PrivacyBoundaryTests.swift Sources/UsageCore/Persistence/UsageStore.swift Sources/UsageCore/Persistence/SQLiteUsageStore.swift
rtk git commit -m "[ai] test(core): 验证隐私边界和发布构建"
~~~

---

## Phase 1 Completion Gate

以下条件必须同时满足，才可以创建第二阶段 Xcode App 壳计划：

- rtk swift test 全绿且没有 warning；
- rtk swift build -c release 成功；
- 本机额度方法缺失、未认证或进程退出时仍能返回最后成功快照；
- session 重放、半行、截断、计数器回退和数据库重启不会双计；
- 官方桶只替代已结束自然日，周期边界日保持部分校准；
- 数据库、日志、fixture 输出和公开模型不包含消息正文或凭据；
- Git diff 只包含本计划列出的文件。

第二阶段另建 docs/superpowers/plans/YYYY-MM-DD-codex-usage-app-shell.md，并在 Xcode 16+ 可用、license 已接受后执行。
