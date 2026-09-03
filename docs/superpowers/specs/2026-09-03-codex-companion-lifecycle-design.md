# Codex Usage 跟随 Codex 启停设计

## 状态与目标

本文定义 Codex Usage 的伴随运行能力：Codex 桌面应用启动时自动启动 Codex Usage；Codex 桌面应用真正退出时自动退出 Codex Usage。

本机 Codex 桌面应用安装为 `/Applications/ChatGPT.app`，bundle identifier 为 `com.openai.codex`。Codex Usage 安装为 `/Applications/Codex Usage.app`，bundle identifier 为 `com.local.CodexUsage`。

## 行为边界

- 辅助进程启动时，如果 Codex 已在运行，则启动 Codex Usage。
- 收到 Codex 启动事件时，启动 Codex Usage。重复启动请求必须幂等。
- 收到 Codex 终止事件时，等待 1 秒并重新检查所有 `com.openai.codex` 实例；只有确认不存在运行实例时才退出 Codex Usage。
- 关闭 Codex 窗口但 Codex 进程仍在运行时，不退出 Codex Usage。
- Codex 正常退出、强制退出或崩溃后，退出 Codex Usage。
- 用户在 Codex 运行期间手动退出 Codex Usage 后，不立即强制拉起；下次 Codex 启动或辅助进程重启时再启动。
- 本功能不修改 Codex 应用包，不使用 Codex 会话 Hook，也不读取窗口、任务或对话内容。

## 架构

新增 `CodexUsageWatcher` 命令行辅助 Target。它作为 LaunchAgent 随当前用户登录启动，不显示窗口、Dock 或菜单栏项目。辅助进程通过 `NSWorkspace.shared.notificationCenter` 监听应用启动和终止事件，并始终使用 bundle identifier 判断目标应用，不依赖展示名称或安装路径。

主 App 在 `applicationDidFinishLaunching` 中通过 `SMAppService.agent(plistName:)` 幂等注册 LaunchAgent。LaunchAgent plist 和辅助可执行文件嵌入 `Codex Usage.app`：

```text
Codex Usage.app/
└── Contents/
    ├── Library/LaunchAgents/com.local.CodexUsage.Watcher.plist
    └── MacOS/CodexUsageWatcher
```

注册状态为 `notRegistered` 或 `notFound` 时调用 `register()`；后者兼容后台项目数据库尚无记录的首次安装。主 App 保存内嵌助手的 SHA-256 指纹；服务已经启用但助手指纹变化时，注销并重新注册一次，以刷新 macOS 保存的代码签名要求。等待用户批准时不覆盖用户选择。注册失败只写入统一日志，不阻断用量统计主流程；XCTest 宿主进程不执行真实注册。

## 组件边界

### `CompanionLifecyclePolicy`

纯 Swift 决策器，将初始状态、Codex 启动事件和延迟终止复核转换为动作。它不调用 AppKit，可用确定性单元测试覆盖。

### `CodexApplicationWatcher`

AppKit 适配层，负责：

- 订阅和过滤 `NSWorkspace` 通知；
- 查询指定 bundle identifier 是否仍有运行实例；
- 通过 `NSWorkspace.openApplication` 启动主 App；
- 通过 `NSRunningApplication.terminate()` 请求主 App 正常退出；
- 取消旧的延迟复核，避免连续终止事件重复执行。

辅助程序通过 `_NSGetExecutablePath` 获取自身的绝对路径，再按 `Contents/MacOS` 结构定位所属 App，不依赖 `launchd` 传入的相对启动参数。`NSWorkspace` 的启动完成回调使用非主线程隔离处理，避免 Swift 6 在 LaunchServices 回调队列触发执行器断言。

### `CompanionServiceRegistration`

主 App 的 ServiceManagement 适配层，负责注册已嵌入的 LaunchAgent。它不提供额外设置页；助手指纹未变化时，不注销或重启已启用的服务。

## 错误处理与恢复

- 启动 Codex Usage 失败、退出请求被拒绝或 LaunchAgent 注册失败时记录 `Logger` 错误；辅助进程继续监听后续事件。
- 辅助进程使用 LaunchAgent `KeepAlive` 保持运行；异常退出由系统重新启动。
- 辅助进程自身启动时先检查 Codex 当前状态，覆盖登录、升级或辅助进程重启期间漏掉启动通知的情况。
- Codex 终止后延迟复核，覆盖应用更新造成的快速退出与重启；复核时发现任一 Codex 实例则不关闭 Codex Usage。

## 隐私与权限

辅助进程只读取系统运行中应用的 bundle identifier，不读取应用内容、文件或网络数据。使用 macOS 13+ 的 `SMAppService` 注册，系统可能要求用户在“系统设置 → 通用 → 登录项”中允许后台项目。

## 测试与验收

自动测试覆盖：

- 辅助进程初始启动且 Codex 已运行时请求启动 Codex Usage；
- 初始无 Codex 时不做操作；
- Codex 启动事件请求启动 Codex Usage；
- Codex 终止后复核仍有实例时保持 Codex Usage；
- Codex 终止后复核没有实例时退出 Codex Usage；
- App 构建产物包含 LaunchAgent plist 和可执行的辅助程序。
- 助手能从嵌入式可执行文件路径定位所属 App，并拒绝 App 包外路径；
- 测试宿主不注册真实后台服务，已启用服务只在助手指纹变化时刷新。

构建验收覆盖 Swift Package 测试、App Debug/Release 测试和 Debug/Release 构建。真实 Codex 退出会终止当前开发会话，因此本轮只验证辅助服务已注册、运行且能识别当前 Codex；最终退出联动由用户在安装后执行一次 `⌘Q` 验收。

## 非目标

- 不在 Codex Usage 中增加开关、状态页或通知。
- 不保证关闭 Codex 最后一个窗口时退出 Codex Usage，因为 macOS 关闭窗口不等于退出应用。
- 不通过轮询脚本、AppleScript、Hammerspoon 或修改 Codex 应用包实现。
- 不在本功能中增加自动更新、签名公证或 Mac App Store 支持。
