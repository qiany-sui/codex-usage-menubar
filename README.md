# Codex Usage Menubar

Codex Usage Menubar 是一个仅在本机运行的 macOS 菜单栏应用，用来查看 Codex 的今日 token 用量、最近 7 天趋势，以及当前周期和最近 8 个已完成周期的额度历史。官方接口暂时不可用时，应用会保留最后一次成功快照并标记数据已过期。

v1 已包含完整的菜单栏 App、`UsageCore`、SQLite 持久化、会话增量索引、官方用量读取、周期校准、自动刷新和安全退出清理。

刷新时先显示本地最新统计，再并行读取官方额度和用量；各项结果返回后及时更新页面。已有启动、手动、唤醒或弹窗刷新正在进行时，重复打开弹窗会复用该轮刷新。

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

后续替换为新版本并重新启动 Codex Usage 时，应用会在主程序、助手、启动配置或安装路径发生变化后自动刷新后台注册，不需要手动删除旧登录项。仅更新主程序时也会刷新，避免旧注册失效导致无法跟随 Codex 启动。

替换应用时，不要把旧版本改名后继续留在 `/Applications` 或 `~/Applications`。即使目录名变成 `Codex Usage.app.backup-*`，macOS 仍可能按包内相同的 bundle identifier 将它收录为另一个启动台项目。需要保留旧版本时，请先移到“废纸篓”或 Applications 目录之外，再复制并启动新版本。

启用后的行为：

- Codex 启动时，自动启动 Codex Usage；
- Codex 使用 `⌘Q`、菜单“退出”、强制退出或崩溃后，自动退出 Codex Usage；
- 只关闭 Codex 窗口、但 Codex 进程仍在运行时，Codex Usage 保持运行；
- Codex 运行期间手动退出 Codex Usage 后，不会立刻强制重新启动，等下次启动 Codex 时再自动打开。

后台辅助程序只通过 macOS 查询运行中应用的 bundle identifier，不读取 Codex 的窗口、任务、对话或文件内容。

首次启动时，应用会依次尝试使用 Codex 返回的目录、`CODEX_HOME` 和 `~/.codex`。如果仍找不到，会提示选择 Codex Home；请选择内部包含 `sessions` 或 `archived_sessions` 的文件夹。取消后可在选择页重新点击“选择 Codex Home”；已有数据但授权失效时，可点击标题区域的“重新选择”。

弹窗首页显示本周剩余额度、今日总量及输入/缓存/输出明细。首页卡片可滚动，底部导航和退出入口保持可见；点击“最近 7 天”或“历史周期”可在同一弹窗内查看详情，点击左上角返回。刷新按钮位于右上角，加载、目录选择和错误页面也保留退出入口。数据已过期时，菜单栏保留最后额度并显示时钟标记，悬停可查看上次额度更新时间。

“最近 7 天”的每日列表按日期倒序排列，今天位于最上方；柱状图保持从旧到新的时间顺序。每日列表显示“当日额度消耗”：直接计算官方已用额度的当日增量，例如 38% → 45% 显示 7%，与 Token 数量无关。按本地自然日统计，今天统计到最近的额度快照。重置日显示重置时间，并分别展示“重置前 / 重置后”的消耗；一天多次重置时按时间顺序显示各段；点击日期行可打开独立详情卡，查看完整 Token 数值、每段时间范围和记录完整性说明，七天列表保持原位；点击卡片外部或关闭按钮可收起，较长详情可在卡片内滚动。每段百分比对应各自周期额度，不把跨重置合计显示成当前周期消耗，Token 列仍为全天总量。零点、日末和重置前使用不超过 10 分钟的记录；跨夜空档只有在同周期两侧读数相同时才能确认边界值。边界记录不足但有可确认增量时显示“已记录消耗”并标注“记录不完整”；重置日各段分别保留已记录增量，不合并成完整的全天百分比。没有可确认增量的分段显示“记录不足”，无重置日显示 `--`。数据精度和延迟取决于官方额度快照；“Token 状态”仅表示 Token 校准状态，缺失的额度记录不会凭空补成 0。

会话索引同时补采 `token_count.rate_limits` 中的周额度快照，补齐应用退出或接口暂时失败时遗漏的历史记录。升级后自动重扫保留范围内的日志，Token 按原事件签名去重。日志额度仅补充主动读取已确认的周期，排除并发会话携带的回退旧值和与后续主动读取冲突的值；当前额度和刷新状态仍以主动读取为准。补采后同周期跨夜读数一致即可重算两天的完整消耗，确实无法确认的缺口仍标为记录不完整。

主界面“今日 Token”旁同步显示当日额度消耗；重置日沿用最近 7 天的分段口径，点击可查看每日详情。“当前周期 Token”和历史周期列表显示各自“额度已用”百分比：当前周期使用最新官方累计已用值，已结束周期仅采用该周期结束前 10 分钟内的最后一条官方记录，不把提前重置等同于额度耗尽。已结束周期缺少临近结束的记录时，保留该周期“最后记录”的已用百分比并标注“记录不完整”，悬停可查看采集时间；它不代表周期结束时的最终值。同周期读数下降、没有可用记录或只有估算边界时仍显示“额度记录不足”，不使用当前周期数值倒推。

历史周期列表支持点按周期行打开独立详情卡，查看完整 Token 数值、精确到分钟的起止时间及周期内每天的 Token 和额度消耗，关闭详情后保留列表位置。每日明细只统计属于该周期的时段，支持最近 7 天以外的历史周期；完整自然日有官方 Token 时标“官方校准”，首尾不足一天、今天或没有官方日数据时标“本地统计”。周期全部使用本地记录时显示“本地统计”，混用官方和本地记录时显示“部分校准”，详情说明具体来源；额度的“已记录”表示仅有可确认的部分增量，缺失记录不补成 0。

历史周期结合官方额度记录识别重置：连续额度记录中已用额度仍为 0 时的起点修正归入同一次重置，后续刷新会自动修复已有碎片并重新汇总 Token。已发生额度消耗后的真实重置会保留，因此前后两个真实周期可能共享同一天作为边界日期。

右上角的调色盘菜单可切换“环形仪表”和“极光卡片”。默认使用“极光卡片”，原“原生精修”或“霓光仪表”的已存偏好会迁移到“极光卡片”。选择会自动保存，下次启动继续使用；深浅色跟随 macOS，趋势和历史页的强调色随样式切换。缓存 Token 已包含在输入 Token 中，明细标为“其中缓存”。

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
rtk xcodebuild build -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Unsigned-Release CODE_SIGNING_ALLOWED=NO
```

签名交付与无签名 Release 构建使用不同输出目录，避免覆盖待安装产物；交付规则见 [AGENTS.md](AGENTS.md)。

## 数据位置与发布边界

应用数据库只保存在：

```text
~/Library/Application Support/Codex Usage/usage.sqlite
```

目录授权 bookmark 保存在本机应用偏好设置中。仓库和 Codex Home 内不会写入应用数据库。数据至少覆盖最近 7 个本地自然日，同时保留当前周期加最近 8 个已完成周期；两个范围之外的本地用量事件、官方日桶和额度快照会被清理。每个额度标识会额外保留清理边界前的最后一条快照，用于跨日边界计算。

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
