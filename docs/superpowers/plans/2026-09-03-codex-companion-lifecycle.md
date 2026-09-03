# Codex Usage 跟随 Codex 启停 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Codex Usage 在 Codex 桌面应用启动时自动启动，并在 Codex 真正退出后自动退出。

**Architecture:** 在现有 App 内嵌一个由 `SMAppService` 注册的 LaunchAgent 辅助可执行文件。辅助进程使用 `NSWorkspace` 事件驱动监听 `com.openai.codex`，并通过纯 Swift 策略对象决定启动、延迟复核和退出动作。

**Tech Stack:** Swift 6、SwiftUI、AppKit、ServiceManagement、XCTest、Xcode 16.4

**Spec:** `docs/superpowers/specs/2026-09-03-codex-companion-lifecycle-design.md`

## Global Constraints

- 仅支持 Apple Silicon、macOS 13+。
- Codex bundle identifier 固定为 `com.openai.codex`；Codex Usage 固定为 `com.local.CodexUsage`。
- 不修改 Codex，不使用会话 Hook，不读取窗口、任务或对话内容。
- 只在 Codex 真正退出后关闭 Codex Usage；关闭窗口不触发退出。
- 用户手动退出 Codex Usage 后不立即强制拉起。
- 本轮不新增设置页、开关、通知、第三方依赖或自动更新。
- 保留现有 `.idea/` 与 `.superpowers/` 未跟踪目录，不纳入改动。

---

### Task 1: 生命周期决策策略

**Files:**
- Create: `App/CodexUsage/CompanionLifecyclePolicy.swift`
- Create: `App/CodexUsageTests/CompanionLifecyclePolicyTests.swift`
- Modify: `App/CodexUsage.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `CompanionLifecyclePolicy.action(for:) -> CompanionLifecycleAction`
- Produces events: `initialState(codexRunning:)`, `codexLaunched`, `terminationCheck(codexRunning:)`
- Produces actions: `none`, `launchUsage`, `terminateUsage`

- [x] **Step 1: Write failing policy tests**

  Add literal expectations for initial running/not-running state, launch events, termination checks with another Codex instance, and termination checks with no Codex instance.

- [x] **Step 2: Run the focused tests and verify RED**

  Run:

  ```bash
  rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO -only-testing:CodexUsageTests/CompanionLifecyclePolicyTests
  ```

  Expected: compilation fails because `CompanionLifecyclePolicy` does not exist.

- [x] **Step 3: Implement the minimal pure policy**

  Map `initialState(true)` and `codexLaunched` to `launchUsage`; map `terminationCheck(false)` to `terminateUsage`; all other inputs map to `none`.

- [x] **Step 4: Run the focused tests and verify GREEN**

  Expected: all lifecycle policy tests pass with zero failures.

### Task 2: LaunchAgent 辅助进程与 App 嵌入

**Files:**
- Create: `App/CodexUsageWatcher/CodexUsageWatcherMain.swift`
- Create: `App/CodexUsageWatcher/CodexApplicationWatcher.swift`
- Create: `App/CodexUsage/CompanionAppLocator.swift`
- Create: `App/CodexUsageTests/CompanionAppLocatorTests.swift`
- Create: `App/CodexUsage/LaunchAgents/com.local.CodexUsage.Watcher.plist`
- Modify: `App/CodexUsageTests/ProjectSmokeTests.swift`
- Modify: `App/CodexUsage.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `CompanionLifecyclePolicy.action(for:)`
- Produces: embedded executable `Contents/MacOS/CodexUsageWatcher`
- Produces: embedded plist `Contents/Library/LaunchAgents/com.local.CodexUsage.Watcher.plist`
- Produces: `CompanionAppLocator.containingAppURL(forExecutableURL:)`

- [x] **Step 1: Write a failing bundle integration test**

  Resolve the hosted `Codex Usage.app` bundle and assert the watcher executable exists and is executable, the LaunchAgent plist exists, its label is `com.local.CodexUsage.Watcher`, and `BundleProgram` points to `Contents/MacOS/CodexUsageWatcher`.

- [x] **Step 2: Run the focused smoke test and verify RED**

  Expected: the hosted app does not contain the helper executable or LaunchAgent plist.

- [x] **Step 3: Add the watcher target and event-driven adapter**

  Configure an `arm64`, macOS 13 command-line target. On startup, reconcile current Codex state; filter `NSWorkspace.didLaunchApplicationNotification` and `.didTerminateApplicationNotification` by bundle identifier; delay termination verification by one second; launch/terminate only `com.local.CodexUsage`.

- [x] **Step 4: Embed the helper and LaunchAgent plist**

  Add a target dependency and Copy Files phases so both artifacts land at the paths required by `SMAppService.agent(plistName:)`. Configure the plist with `RunAtLoad=true`, `KeepAlive=true`, `ProcessType=Background`, and `LimitLoadToSessionType=Aqua`.

- [x] **Step 5: Run focused policy and smoke tests and verify GREEN**

  Expected: policy tests and packaging integration test pass.

### Task 3: 主 App 幂等注册辅助服务

**Files:**
- Create: `App/CodexUsage/CompanionServiceRegistration.swift`
- Create: `App/CodexUsageTests/CompanionServiceRegistrationTests.swift`
- Modify: `App/CodexUsage/CodexUsageApp.swift`
- Modify: `App/CodexUsage.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `CompanionServiceRegistration.shouldRegister(status:isTestProcess:) -> Bool`
- Produces: `CompanionServiceRegistration.shouldRefreshRegistration(...) -> Bool`
- Produces: `CompanionServiceRegistration.registerIfNeeded()`

- [x] **Step 1: Write failing registration decision tests**

  Verify `SMAppService.Status.notRegistered` and `notFound` request registration; `enabled` and `requiresApproval` do not repeatedly register.

- [x] **Step 2: Run the focused tests and verify RED**

  Expected: compilation fails because `CompanionServiceRegistration` does not exist.

- [x] **Step 3: Implement registration and connect app launch**

  Add `applicationDidFinishLaunching` to call `registerIfNeeded()`. Use `Logger` for registration errors without changing App UI or failing application startup.

- [x] **Step 4: Run focused tests and verify GREEN**

  Expected: registration decision tests pass with zero failures.

### Task 4: 文档、全量验证与本机安装

**Files:**
- Modify: `README.md`
- Replace after successful verification: `/Applications/Codex Usage.app`

**Interfaces:**
- Consumes: built Release app from `DerivedData/Release/Build/Products/Release/Codex Usage.app`

- [x] **Step 1: Document companion behavior and one-time approval**

  Explain actual-quit semantics, the possible “登录项” approval, and that the app must be launched once after installation to register the helper.

- [x] **Step 2: Run all automated verification**

  Run `rtk swift test`, Debug/Release App tests, and Debug/Release unsigned builds. Every command must exit 0 with zero test failures.

- [x] **Step 3: Build the locally signed Release app**

  Build for `platform=macOS,arch=arm64` with the existing Sign to Run Locally configuration and inspect the embedded helper/plist.

- [x] **Step 4: Replace the installed app recoverably**

  Quit only Codex Usage, move the current `/Applications/Codex Usage.app` to a timestamped backup, copy the verified Release app into `/Applications`, then launch it once to register the helper.

- [x] **Step 5: Verify installed state without closing Codex**

  Confirm the installed app bundle contains both embedded artifacts and the LaunchAgent registration is enabled or explicitly awaiting user approval. Do not quit Codex because that would interrupt the active development task; ask the user to perform the final `⌘Q` behavior check.
