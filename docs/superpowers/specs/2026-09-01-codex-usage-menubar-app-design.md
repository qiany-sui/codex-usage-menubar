# Codex Usage Phase 2 原生 App 设计

## 状态与适用范围

本文定义 Codex Usage 第二阶段原生 macOS App 壳的产品与技术设计。第一阶段 `UsageCore` 已完成，当前基线为 165 个自动化测试全部通过。

本文补充并细化 [`2026-08-31-codex-usage-menubar-design.md`](./2026-08-31-codex-usage-menubar-design.md) 中的“第二阶段：原生 App 壳”。若两份文档在 App 界面、交互、签名或交付方式上存在差异，以本文为准；额度口径、Session 解析、校准、隐私和 SQLite 规则仍沿用原设计。

本设计已确认以下产品决策：

- 交付完整可用的 v1 菜单栏应用，不做空壳或仅供演示的原型；
- 仅支持 Apple Silicon、macOS 13+；
- 使用纯 SwiftUI `MenuBarExtra(.window)`；
- 使用现代深色视觉风格；
- 概览、7 天趋势和周期历史在同一弹窗内切换；
- 交付可由 Xcode 运行并可双击启动的本地 `.app`；
- 使用 MIT License。

## 目标与非目标

### 目标

用户启动应用后，不需要配置账号或理解 Codex 内部数据结构，即可在菜单栏看到周额度剩余百分比。点击菜单栏后，可查看：

- 周额度剩余百分比、重置时间和剩余时长；
- 今日 Token 总量及输入、缓存输入、输出明细；
- 当前额度周期 Token 和校准状态；
- 最近 7 天趋势；
- 最近 8 个已完成额度周期；
- 最后更新时间、刷新状态、手动刷新和退出。

应用默认自动发现本机 Codex 数据并持续更新。找不到目录时，才要求用户选择一次 Codex Home。

### 非目标

v1 不包含：

- 多账号和账号切换；
- 云同步、遥测或第三方分析；
- 费用估算和预算提醒；
- 系统通知；
- 登录时启动；
- 自动更新；
- 安装器、Developer ID 公证或 Mac App Store 发布；
- Intel Mac；
- 额度重置券消费或任何会改变 Codex 账号状态的操作。

## 用户体验

### 菜单栏

应用设置 `LSUIElement=true`，不显示 Dock 图标和常规主窗口。菜单栏使用紧凑文本：

```text
◔ 62%
```

显示规则：

- 有有效额度：`◔ 62%`；
- 尚无可用数据：`◔ --`；
- SQLite 无法使用等致命错误：`◔ !`。

局部数据源失败但仍有旧额度时，菜单栏继续显示最后成功值，不用错误图标替换可用信息。具体过期状态在弹窗中说明。

### 弹窗外观

弹窗固定为 `410 × 440 pt`，三个页面保持相同尺寸，避免切换时窗口跳动。界面强制使用深色配色，不依赖系统当前浅色或深色模式：

- 近黑背景和低对比度细边框；
- 紫色到蓝色的少量强调色；
- 系统字体和 SF Symbols；
- 不堆叠大量独立卡片；
- 不使用外部字体、图标库或 UI 框架；
- 界面文案使用简体中文。

视觉层级依靠字号、留白、细分隔线和一处强调色建立。顶部可使用很细的紫蓝渐变线作为品牌识别，但不得大面积使用高饱和渐变。

### 概览页

概览从上到下展示：

1. 标题、刷新状态和手动刷新按钮；
2. 周额度剩余大数字、重置倒计时和细进度条；
3. 今日 Token 主数字；
4. 输入、缓存输入和输出三个次级明细；
5. 当前周期 Token 和校准状态；
6. “最近 7 天”和“历史周期”入口；
7. 最后更新时间和退出入口。

“今日 Token”与输入、缓存输入、输出不是四个同级指标。今日总量必须是主数字；三个明细使用更小字号和次级颜色。`cachedInputTokens` 是 `inputTokens` 的子集，任何图表都不得把缓存输入画成可与输入、输出相加的组成比例。

### 详情页切换

点击“最近 7 天”或“历史周期”后，在同一弹窗内从右侧滑入详情页，概览向左滑出。详情页左上角提供返回按钮。启用“减少动态效果”时取消滑动，只做无动画内容替换。

7 天趋势页展示：

- 7 天总 Token；
- 日均 Token；
- 每日趋势折线或柱状图；
- 每天的日期和 Token 数；
- 对应日期的校准状态。

周期历史页展示当前周期和最多 8 个已完成周期。列表可滚动，每一项包含起止时间、Token 总量和校准状态。当前周期与已完成周期必须在视觉上区分。

## 项目结构与组件边界

使用标准 Xcode macOS App Target：

```text
App/
  CodexUsage.xcodeproj/
  CodexUsage/
    CodexUsageApp.swift
    AppContainer.swift
    UsageViewModel.swift
    UsagePopoverView.swift
    OverviewView.swift
    TrendDetailView.swift
    CycleHistoryView.swift
    UsageTheme.swift
    UsageFormatters.swift
    CodexHomeBookmarkStore.swift
    Assets.xcassets/
    Info.plist
  CodexUsageTests/
```

App Target 只依赖仓库根目录的本地 `UsageCore` package，不复制核心逻辑。

### `CodexUsageApp`

负责应用生命周期、创建 `MenuBarExtra(.window)`、提供菜单栏标签，以及把系统睡眠唤醒事件转发给 View Model。它不访问 SQLite，也不组织刷新策略。

### `AppContainer`

作为唯一的依赖组装入口，创建：

- `CodexAppServerClient`；
- `SessionUsageIndexer`；
- `SQLiteUsageStore`；
- `UsageService`；
- `SessionDirectoryWatcher`；
- `UsageViewModel`。

SQLite 默认路径为：

```text
~/Library/Application Support/Codex Usage/usage.sqlite
```

目录由 App 启动时创建。不得把数据库放进仓库、Codex Home 或临时目录。

### `UsageViewModel`

使用 `@MainActor ObservableObject`，只保存 UI 需要的状态：

- 当前 `UsageSnapshot`；
- 首次加载、刷新中、过期和致命错误状态；
- 当前页面：概览、趋势或周期历史；
- 目录选择状态；
- 启动、定时、通知、目录监听和重试任务。

View Model 不计算 Token、额度百分比、自然日或周期。所有这些规则由 `UsageCore` 提供。

为使 App 状态转换可测试，App Target 定义最小的 `UsageServicing` 与 `SessionChangeWatching` 协议，并让 `UsageService`、`SessionDirectoryWatcher` 适配这些协议。协议只暴露 View Model 实际使用的方法，不设计额外扩展点。

### SwiftUI Views

`UsagePopoverView` 只负责页面路由和转场。三个页面视图只接收格式化前所需的值和用户动作闭包，不直接持有 Service、Watcher 或 SQLite 连接。

`UsageTheme` 集中存放颜色、字号、间距和转场时长。`UsageFormatters` 负责百分比、Token 缩写、日期、重置倒计时和最后更新时间格式化。格式化逻辑独立测试，不散落在视图中。

## UsageCore 的最小补充

App 在第一次成功刷新后需要知道最终采用的 Codex Home，才能监听 `sessions` 与 `archived_sessions`。当前 `UsageService` 内部完成目录解析，但不公开结果。因此 Phase 2 在 `UsageCore` 增加一个只读方法：

```swift
public func resolvedCodexHome() -> URL?
```

该方法复用现有 `CodexHomeResolver`，不读取认证文件，也不改变既有解析顺序。除此之外，不为 App 修改领域模型或持久化规则。

用户通过目录选择器选择 Codex Home 后，App 解析 security-scoped bookmark，并以显式 `CODEX_HOME` 环境值重新组装 `UsageService`。重新组装前取消旧任务并停止旧 Watcher，避免同时运行两套服务。

## 生命周期与数据流

### 启动

1. 解析已保存的 Codex Home bookmark；
2. 创建 Application Support 目录和依赖；
3. 调用 `refresh(reason: .startup, now:)`，完成迁移、额度读取、官方日桶读取和 Session 增量索引；
4. 把返回的 `UsageSnapshot` 发布到主线程；
5. 查询最终 Codex Home，并启动目录监听；
6. 启动账户通知循环和 60 秒调度循环。

首次刷新完成前显示轻量加载状态，菜单栏显示 `◔ --`。数据库已有旧数据但部分来源刷新失败时，展示旧快照并标记过期。

### 自动更新

- 目录监听仅覆盖 Codex Home 下现存的 `sessions` 和 `archived_sessions`；
- FSEvents 在第一次变化时立即触发，1 秒窗口内的连续变化合并；
- 收到目录变化后调用 `.sessionFilesChanged`，只增量索引本机 Session；
- 账户额度通知通过 `processNextAccountNotification(now:)` 处理；
- 通知流返回 `nil` 或遇到 EOF 时结束当前消费循环，按失败退避重新连接，禁止无等待空转；
- 每 60 秒调用一次 `.scheduled`，实际是否读取额度和官方日桶由 `RefreshPolicy` 决定；
- 打开 Popover 时调用 `.popoverOpened`；
- Mac 唤醒时调用 `.wake`；
- 手动刷新调用 `.manual`。

`UsageService` 继续负责串行化刷新，因此 View Model 不自行加第二套数据库锁或刷新队列。完整 Token 事件写入后，界面更新目标为 2 秒以内。

### 重试与退出

刷新失败后使用 `RefreshPolicy.retryDelay`，从 30 秒指数退避到最长 15 分钟。新目录事件、账户通知、Popover 打开和手动刷新仍可触发正常刷新，不需要等待退避计时器。

应用退出时：

- 取消调度、通知、重试和目录监听任务；
- 调用 Watcher 的 `stop()`；
- 释放 `CodexAppServerClient`，确保其子进程终止；
- 不遗留后台辅助进程。

## 目录选择与权限

Codex Home 自动解析继续采用 app-server 返回值、显式 `CODEX_HOME`、`~/.codex` 的顺序。自动解析全部失败时才弹出 `NSOpenPanel`。已保存 bookmark 在后续启动时恢复为显式 `CODEX_HOME`，再组装 `UsageService`；app-server 返回的有效绝对目录仍拥有最高优先级。

选择器只允许目录。选中目录必须至少包含 `sessions` 或 `archived_sessions` 之一，否则显示说明并允许重新选择。选择成功后保存 security-scoped bookmark；失效时重新请求选择。

v1 关闭 App Sandbox（`ENABLE_APP_SANDBOX=NO`），原因是应用需要在没有每次授权的情况下读取 `~/.codex` 并启动本机 Codex 可执行文件。隐私边界由明确的只读路径、解析白名单、持久化模型和自动化测试保证。此配置也意味着 v1 不面向 Mac App Store。

## 状态与错误处理

### 非致命失败

以下情况保留最后成功快照，并显示紧凑的“数据可能已过期”状态和最后更新时间：

- app-server 初始化、额度读取或官方日桶读取失败；
- Session 目录暂时不可读；
- 子进程退出、超时、未知通知或协议错误；
- 部分 JSONL 行或官方日桶无效。

各区域独立降级。额度不可用时，今日与周期 Token 仍可显示；Session 索引失败时，最后成功额度仍可显示。界面提供手动刷新，但不弹出阻塞式错误对话框。

### 无数据

没有任何快照且自动解析不到 Codex Home 时，显示目录选择引导。用户取消后保留引导和“选择目录”按钮，不反复自动弹窗。

### 致命失败

SQLite 无法创建、迁移或读取时显示致命错误页和“重试”。v1 不自动删除或重建数据库，也不提供未经确认的数据清理按钮。错误信息不得包含 JSONL 原文、凭据或对话内容。

## 隐私与保留

App 延续 `UsageCore` 的隐私规则：

- 只读取 `sessions` 和 `archived_sessions` 中统计所需的 JSONL 字段；
- 不保存原始 JSONL、提示词、回复正文、邮箱、Account ID、Cookie、OAuth Token、API Key 或 `auth.json`；
- 不发送遥测，不引入第三方分析 SDK；
- 不调用私有 HTTP 接口；
- 只保留当前周期和最近 8 个已完成周期的用量明细；
- 过期事件与官方日桶由现有 9 周期清理策略删除；
- bookmark 只用于恢复用户明确选择的 Codex Home 访问权限。

## 测试策略

### UsageCore 回归

继续运行：

```bash
swift test
```

现有 165 个测试必须全部通过。为 `resolvedCodexHome()` 增加目录优先级、无效目录和未初始化状态测试。

### App 单元测试

`CodexUsageTests` 使用假的 Service、Watcher 和时钟，覆盖：

- 启动成功、启动失败和旧快照降级；
- 定时、Popover 打开、唤醒、目录变化和手动刷新原因映射；
- 连续事件不会造成 UI 状态倒退；
- 退避调度、手动重试和任务取消；
- 目录选择、bookmark 保存、恢复和失效；
- 概览、趋势、周期历史路由与返回；
- 加载、过期、无数据和致命错误状态；
- 百分比、Token、日期、倒计时和更新时间格式化；
- 菜单栏 `◔ 62%`、`◔ --`、`◔ !` 映射。

视图不依赖第三方快照测试库。核心布局通过 Preview 固定数据和人工视觉检查验证；状态与格式化逻辑通过单元测试验证。

### 构建与手动验收

自动构建覆盖 Debug 与 Release，CI 或无签名验证使用 `CODE_SIGNING_ALLOWED=NO`。本机交付使用 Xcode 的 “Sign to Run Locally”，无需付费 Apple Developer 账号。

手动验收覆盖：

- Xcode 16.4 能打开工程、构建并运行；
- 菜单栏出现且 Dock 不出现图标；
- 概览展示完整数据，今日总量与三个明细层级正确；
- 详情页在同一 Popover 内切换并返回；
- “减少动态效果”下不执行滑动动画；
- 目录自动发现和手动选择都能工作；
- 新完整 Token 事件目标 2 秒内反映到 UI；
- 空闲 CPU 目标低于 1%；
- 睡眠恢复、手动刷新、过期数据和离线状态可用；
- 退出应用后没有遗留 Codex 子进程或 FSEvents 监听；
- Release `.app` 可双击启动。

## 交付与文档

Phase 2 完成时交付：

- `App/CodexUsage.xcodeproj` 与 App 源码；
- App 层自动化测试；
- 根目录 `LICENSE`，内容为 MIT License；
- README 中面向 Xcode 新手的操作说明，包括：
  - 打开哪个工程；
  - 如何选择 Scheme；
  - 如何运行和停止；
  - 如何构建 Release；
  - 在哪里找到 `.app`；
  - 如何退出菜单栏应用；
- 本机 Release 构建产物的明确路径。

不把 DerivedData、`.app`、数据库、用户 bookmark、Xcode 用户状态或临时视觉 Demo 提交到 Git。

## 完成标准

Phase 2 只有同时满足以下条件才算完成：

1. `UsageCore` 和 App 测试全部通过；
2. Debug、Release 构建无错误，关键目标无新增 warning；
3. 菜单栏、概览、趋势、周期历史和错误状态均可实际操作；
4. 自动更新、睡眠恢复、目录选择和退出清理通过验证；
5. 隐私边界和 9 周期保留规则没有回归；
6. 生成的本地 `.app` 可双击运行；
7. README 与 MIT License 完整；
8. v1 非目标功能没有被顺带加入。
