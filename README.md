# Codex Usage Menubar

Codex Usage Menubar 是一个仅在本机运行的 macOS 菜单栏应用，用来查看 Codex 的今日 token 用量、最近 7 天趋势，以及当前周期和最近 8 个已完成周期的额度历史。官方接口暂时不可用时，应用会保留最后一次成功快照并标记数据已过期。

v1 已包含完整的菜单栏 App、`UsageCore`、SQLite 持久化、会话增量索引、官方用量读取、周期校准、自动刷新和安全退出清理。

应用还包含一个轻量后台辅助程序：Codex 桌面应用启动时自动启动 Codex Usage，Codex 真正退出后自动退出 Codex Usage。

## 环境要求

- Apple Silicon Mac；当前产物仅包含 `arm64`
- macOS 13 或更高版本
- Xcode 16.4，并已接受 Xcode License
- 本机已安装 Codex CLI，或已安装内含 `codex` 可执行文件的 ChatGPT 桌面应用
- 命令行示例使用 `rtk` 命令代理

## 用 Xcode 运行

1. 双击 `App/CodexUsage.xcodeproj`，不要打开根目录的 `Package.swift`。
2. 在 Xcode 顶部将 Scheme 选择为 `CodexUsage`，运行目标选择 `My Mac`。
3. 按 `⌘R`。出现 `Build Succeeded` 后，到 macOS 菜单栏寻找饼图图标和额度百分比。
4. 点击菜单栏项目查看概览；应用没有 Dock 图标属于正常行为。
5. 停止调试时，点击 Xcode 左上角的停止按钮或按 `⌘.`。正常退出应用时，请在弹窗底部点击“退出”。

## 跟随 Codex 自动启停

把构建产物放进“应用程序”后，需要手动启动一次 Codex Usage。应用会注册内嵌的后台辅助程序；macOS 首次使用时可能要求在“系统设置 → 通用 → 登录项”中允许它后台运行。

后续替换为新版本并重新启动 Codex Usage 时，应用会在助手发生变化后自动刷新后台注册，不需要手动删除旧登录项。

启用后的行为：

- Codex 启动时，自动启动 Codex Usage；
- Codex 使用 `⌘Q`、菜单“退出”、强制退出或崩溃后，自动退出 Codex Usage；
- 只关闭 Codex 窗口、但 Codex 进程仍在运行时，Codex Usage 保持运行；
- Codex 运行期间手动退出 Codex Usage 后，不会立刻强制重新启动，等下次启动 Codex 时再自动打开。

后台辅助程序只通过 macOS 查询运行中应用的 bundle identifier，不读取 Codex 的窗口、任务、对话或文件内容。

首次启动时，应用会依次尝试使用 Codex 返回的目录、`CODEX_HOME` 和 `~/.codex`。如果仍找不到，会提示选择 Codex Home；请选择内部包含 `sessions` 或 `archived_sessions` 的文件夹。取消后可在选择页重新点击“选择 Codex Home”；已有数据但授权失效时，可点击标题区域的“重新选择”。

弹窗首页显示本周剩余额度、今日总量及输入/缓存/输出明细。点击“最近 7 天”或“历史周期”可在同一弹窗内查看详情，点击左上角返回；刷新按钮位于右上角，“退出”位于底部。

## 构建可双击的 Release App

1. 在 Xcode 菜单选择 Product → Scheme → Edit Scheme。
2. 选择 Run，将 Build Configuration 改为 Release，然后关闭设置。
3. 按 `⌘B` 完成构建。
4. 在 Xcode 左侧 Products 下右键 `Codex Usage.app`，选择 Show in Finder。

命令行可重复生成到固定位置：

```bash
rtk xcodebuild build -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Release
```

产物路径：`DerivedData/Release/Build/Products/Release/Codex Usage.app`。本机命令行构建使用 Xcode 的 “Sign to Run Locally”，适合在当前 Mac 上运行；项目未配置 Developer ID、公证或 Mac App Store 发布流程。

## 测试与无签名构建

运行 `UsageCore` 全套测试：

```bash
rtk swift test
```

运行菜单栏 App 的 Debug 和 Release 测试：

```bash
rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests CODE_SIGNING_ALLOWED=NO
rtk xcodebuild test -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Tests-Release CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES
```

`ENABLE_TESTABILITY=YES` 只作用于 Release 测试命令，不会改变正常 Release App 的构建配置。

验证无签名 Debug 和 Release 构建：

```bash
rtk xcodebuild build -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Debug CODE_SIGNING_ALLOWED=NO
rtk xcodebuild build -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Release CODE_SIGNING_ALLOWED=NO
```

## 数据位置与发布边界

应用数据库只保存在：

```text
~/Library/Application Support/Codex Usage/usage.sqlite
```

目录授权 bookmark 保存在本机应用偏好设置中。仓库和 Codex Home 内不会写入应用数据库。数据按当前周期加最近 8 个已完成周期保留；更早的本地用量事件和官方日桶会被清理。

App Sandbox 当前关闭，因为应用需要读取用户选择的 Codex Home、监听 session 文件变化并启动本机 `codex app-server`。因此 v1 定位为本机直接运行的开源工具，不是 Mac App Store 构建。

## 数据来源与隐私边界

核心库只调用 Codex `app-server` 的只读方法：

- `initialize`
- `account/rateLimits/read`
- `account/usage/read`

本地 session 索引只提取 token 计数、时间和文件游标。公开模型、日志和 SQLite 数据库不会保存消息正文或凭据；resolver 和 indexer 不读取或打开 `auth.json`。应用没有遥测、分析 SDK 或第三方数据上传。关闭应用时会停止目录监听和子进程，并在关闭存储时截断 WAL checkpoint、释放 SQLite 连接。

## 项目结构

```text
App/CodexUsage/          # macOS 菜单栏应用
App/CodexUsageWatcher/   # 跟随 Codex 启停的 LaunchAgent 辅助程序
App/CodexUsageTests/     # App 状态、格式化和工程测试
Sources/UsageCore/
├── AppServer/           # app-server JSON-RPC 只读客户端
├── Coordination/        # 刷新策略与快照编排
├── Domain/              # 公开用量模型
├── Persistence/         # SQLite 存储与游标
├── Reconciliation/      # 本地、官方数据和额度周期校准
└── Sessions/            # session JSONL 增量索引
Tests/UsageCoreTests/    # Core 单元、集成和隐私回归测试
docs/superpowers/        # 设计与实施计划
```

Swift Package 只导出 `UsageCore` library product；App 通过本地 Package 依赖复用它。

## 设计与实施资料

- [Phase 1 产品与架构设计](docs/superpowers/specs/2026-08-31-codex-usage-menubar-design.md)
- [Phase 1 实施计划](docs/superpowers/plans/2026-08-31-codex-usage-core.md)
- [Phase 2 菜单栏 App 设计](docs/superpowers/specs/2026-09-01-codex-usage-menubar-app-design.md)
- [Phase 2 实施计划](docs/superpowers/plans/2026-09-01-codex-usage-menubar-app.md)

## License

本项目采用 [MIT License](LICENSE)。
