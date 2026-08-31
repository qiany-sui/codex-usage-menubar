# Codex Usage 菜单栏工具设计

## 状态与决策

- 产品形态：仅支持 Apple Silicon、macOS 13+ 的本地菜单栏应用，工作名为 **Codex Usage**。
- 已批准路线：先以 SwiftPM + Swift 6.2.4 完成并验证 `UsageCore`，再用 Xcode 16+ 创建标准 SwiftUI macOS App 壳。
- 当前环境：Apple Silicon；Command Line Tools 提供 Swift 6.2.4；现有 Xcode 15.2 只提供 Swift 5.9.2，因此不能用于最终 Swift 6 App 构建。
- 第一阶段不手写 `.xcodeproj`，也不引入 XcodeGen、Tuist、Electron、Node.js、Tauri 或 WebView。

## 产品目标

菜单栏常驻文本只显示周额度剩余百分比，例如：

```text
◔ 62%
```

点击后展示：

- Codex 周额度剩余百分比、进度条、重置时间和剩余时长；
- 今日 Token、本机输入/缓存输入/输出明细；
- 当前额度周期 Token 和校准状态；
- 最近 7 天趋势；
- 最近 8 个已结束额度周期；
- 最后更新时间、手动刷新和退出。

Token 主口径固定为 `inputTokens + outputTokens`。`cachedInputTokens` 是输入 Token 的子集，只做明细，不重复加入总量。Token 活动量不用于反推额度百分比。

## v1 范围

v1 面向个人、单账号、单 Mac：

- 不包含多账号、云同步、通知、费用估算、自动更新和开机启动；
- 不消费额度重置券；
- 不读取、复制、解析或写回 `auth.json`；
- 不读取、保存或上传提示词、回复正文、账号邮箱、Account ID、Cookie、OAuth Token 或 API Key；
- 不调用私有 HTTP 接口，只通过本机 `codex app-server` 的稳定 JSON-RPC 方法读取账户数据。

## 分阶段架构

### 第一阶段：UsageCore

根目录 Swift package 提供一个 macOS-only library：

```text
Package.swift
Sources/UsageCore/
  Domain/
  AppServer/
  Sessions/
  Persistence/
  Reconciliation/
  Coordination/
Tests/UsageCoreTests/
  Fixtures/
```

职责：

- `Domain`：稳定的额度、Token、自然日、周期和 UI 快照模型；
- `AppServer`：解析 Codex 可执行文件、管理 JSONL/JSON-RPC 子进程、读取额度与官方日桶；
- `Sessions`：只读扫描 session JSONL，增量解析 Token 事件并去除 fork/subagent 重放前缀；
- `Persistence`：用系统 SQLite3 保存数值、匿名签名、文件游标、官方日桶、额度快照和最近 8 个周期；
- `Reconciliation`：融合本机实时事件、官方完整自然日和额度周期；
- `Coordination`：组织启动、定时刷新、睡眠唤醒、退避和统一 `UsageSnapshot` 输出。

第一阶段必须可用以下命令独立验证：

```bash
swift test
```

### 第二阶段：原生 App 壳

安装并切换到 Xcode 16+、接受 Xcode license 后创建标准 macOS App target：

```text
App/CodexUsage.xcodeproj
App/CodexUsage/
  CodexUsageApp.swift
  UsageViewModel.swift
  UsagePopoverView.swift
  Assets.xcassets
  Info.plist
```

App 壳使用 SwiftUI `MenuBarExtra(.window)`，设置 `LSUIElement=true` 隐藏 Dock 图标，只依赖本地 `UsageCore` package。构建配置固定 `arm64`、最低 macOS 13，并使用 `CODE_SIGNING_ALLOWED=NO` 完成 CI/本地无签名验证；安装包签名与公证不属于 v1 第一阶段。

## 数据源与协议

### Codex app-server

依据[官方 Codex App Server 文档](https://developers.openai.com/codex/app-server)：

- 默认 stdio transport 是每行一条 JSON 的 JSONL；
- 每条连接必须先请求 `initialize`，成功后发送 `initialized` 通知；
- `account/rateLimits/read` 获取 ChatGPT/Codex 额度窗口；
- `account/rateLimits/updated` 是稀疏通知，必须与已有完整快照合并；
- `account/usage/read` 获取 Token 汇总和可选的每日桶。

本机 `codex-cli 0.151.0-alpha.7.2` schema 还在 `initialize` 响应中返回 `codexHome`。实现可以优先使用该字段，但不能把它视为跨版本必需字段。

请求只依赖稳定字段；所有未知字段忽略，所有可选或可空字段按缺失处理。以下情况必须降级为明确状态而不是清空旧数据：

- JSON-RPC `-32601`（方法不存在）；
- JSON-RPC `-32600`（未认证或请求不兼容）；
- 非 JSON 行、未知通知、未知响应 ID；
- 子进程退出、超时或协议握手失败。

### Codex Home 定位

只读定位顺序：

1. `initialize.result.codexHome` 存在且为绝对目录时使用；
2. App 进程显式传入的 `CODEX_HOME` 存在且为绝对目录时使用；
3. 使用 `FileManager.default.homeDirectoryForCurrentUser/.codex`；
4. 仍不可用时返回“不可用”，第二阶段 App 壳允许用户选择目录并保存 security-scoped bookmark。

绝不通过读取认证文件反推目录。

## 额度规则

从 `rateLimitsByLimitId`（非空时优先）或兼容字段 `rateLimits` 收集 `primary`、`secondary` 窗口：

1. 只保留同时含 `usedPercent`、`windowDurationMins`、`resetsAt` 的窗口；
2. 周窗口必须在 `9,000...11,000` 分钟内；
3. `limitId == "codex"` 优先；同优先级选择最接近 `10,080` 分钟的窗口；
4. 没有周窗口时显示“周额度不可用”，不拿 5 小时窗口冒充；
5. 剩余百分比为 `clamp(100 - usedPercent, 0...100)`；
6. 周期起点为 `resetsAt - windowDurationMins * 60`。

每 5 分钟读取完整额度；Popover 打开且缓存超过 60 秒时立即读取。稀疏更新只覆盖通知中实际存在的字段。刷新失败时保留最后成功值并标为“数据过期”。

## Session Token 规则

### 读取边界

- 只读取 `sessions` 与 `archived_sessions` 下的 JSONL；
- 只解码 session metadata 和 `event_msg.payload.type == "token_count"` 所需字段；
- 不把整行 JSON、其他 payload 或消息正文写入日志与数据库；
- 首次启动回扫最近 8 个额度周期；之后用文件游标增量读取；
- 文件尾没有换行的半行保留到下次解析；文件缩短或 inode 变化时从头重新建立该文件游标。

### 计量

优先使用 `last_token_usage`：

```text
input = input_tokens
cachedInput = cached_input_tokens
output = output_tokens
total = input + output
```

若只有 `total_token_usage`，使用同一逻辑 session 内相邻累计值的非负增量；首次累计值视为从零开始。累计值回退时开始新段，以新累计值作为该段首个增量。

本机当前 session schema 的 `output_tokens` 已采用完整输出口径；`reasoning_output_tokens` 只用于兼容解码，不额外累加，防止双计。未来如官方 schema 改变，必须先增加能复现新口径的 fixture 和失败测试，再调整计量。

### 去重

每个 Token 事件生成 SHA-256 匿名签名，输入仅包含：

- 事件时间戳；
- `last_token_usage` 或 `total_token_usage` 的数值字段；
- Token 事件的 schema 变体标识。

签名不含消息正文、路径、账号或凭据。相同前缀被 fork、subagent 或归档文件重放时签名相同，SQLite 唯一约束保证只累计一次。v1 将时间戳与全部计数都完全相同的事件视为同一重放事件；这是明确的低概率取舍，不引入路径相关标识破坏跨文件去重。

## 校准与周期

- “今日”按事件首次入库时的 Mac 本地自然日统计，之后切换时区不重写历史；
- 当前自然日始终使用本机实时值；
- 已结束自然日如有官方 `dailyUsageBuckets`，展示值由官方值替代本机值；
- 额度周期完整覆盖的自然日可使用官方桶；
- 周期起止落在自然日中间时，边界日按本机带时间戳事件切分，状态为“部分校准”；
- 其他设备在边界日产生的 Token 无法精确切分，v1 明确保留这一限制；
- 检测到推导出的新周期起点晚于现有周期起点时，关闭旧周期并创建新周期；
- 只保留当前周期和最近 8 个已结束周期的明细。

统一展示状态：

- `本机实时`；
- `已校准`；
- `部分校准`；
- `数据过期`；
- `不可用`。

## SQLite 数据

数据库默认放在第二阶段 App container 的 Application Support 目录；第一阶段测试使用临时文件或 `:memory:`。

表只保存：

- schema 版本；
- 文件路径的不可逆哈希、inode、已提交到完整换行处的读取偏移和累计计数器；
- Token 事件签名、时间、本地日期和数值；
- 官方每日桶；
- 额度快照与周期边界；
- 刷新时间和错误分类。

未完成的半行只保存在进程内存中；持久化偏移停在该半行起点，重启后重新读取，避免把可能含消息正文的半行写入数据库。不保存原始 JSONL、提示词、回复正文、账号身份或认证信息。

## 验证与验收

第一阶段自动化测试必须覆盖：

- JSON-RPC 初始化、乱序响应、未知通知、错误、EOF、超时和非零退出；
- 额度多桶选择、缺失字段、稀疏合并和百分比夹取；
- 精确单次用量、累计增量、缓存输入、截断行、文件截断、计数器回退；
- fork/subagent/归档重放去重；
- SQLite 重启后游标和唯一签名仍生效；
- 官方日桶替换已结束日期时不重复计算；
- 本地时区、夏令时、周期跨日、自然重置和提前重置；
- 保留最近 8 个周期；
- fixture、数据库和测试日志中不存在凭据或消息正文。

第一阶段完成标准：

- `swift test` 全绿且无编译 warning；
- 新 session 完整行经增量索引后能生成正确 `UsageSnapshot`；
- 额度刷新失败不会清空最后成功值；
- 核心库不访问私有网络接口或认证文件；
- 公开 API 足够让第二阶段 App 壳只负责展示、刷新触发和生命周期桥接。

完整产品验收标准：

- 菜单栏只显示周额度剩余百分比；
- 完整 Token 事件写入后目标 2 秒内更新今日和周期数据；
- 空闲 CPU 目标低于 1%，不采用每秒全目录扫描；
- Xcode 16+ 下 `arm64`、macOS 13 deployment target 构建通过。
