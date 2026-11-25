# Codex Usage

Codex Usage 是一个在本机运行的用量工具。macOS 菜单栏和 Windows 任务栏托盘使用同一套紧凑的 Tauri 面板与 Rust 统计核心。可查看今日 Token、周额度、最近 7 天趋势、当前额度周期和最近 8 个已结束周期。收起面板后会继续后台刷新，点击「退出」可结束采集。

查看官方额度需要安装并登录 [Codex CLI](https://github.com/openai/codex)。应用会查找 PATH、官方安装位置和支持的 npm 安装布局。自定义 CLI 路径可通过 `CODEX_CLI_PATH` 指定。官方暂时不可用时仍会显示本机用量与最近成功读取的额度。

首次启动时，应用会尝试使用已选择的目录、Codex 返回的目录、`CODEX_HOME` 和用户目录下的 `.codex`。可以右键点击菜单栏或托盘图标，选择「选择目录…」，再选择包含 `sessions` 或 `archived_sessions` 的 Codex Home。

## macOS

支持 Apple Silicon 和 macOS 13 及以上。双击 `Codex Usage.app`，也可通过菜单栏图标随时打开用量窗口。

构建需要 Rust、Node.js 和 Xcode Command Line Tools。在项目根目录运行：

```bash
rtk npm ci
rtk proxy env APPLE_SIGNING_IDENTITY=- npm run tauri -- build --ci --bundles app -- --locked
```

本机签名产物位于 `target/release/bundle/macos/Codex Usage.app`。调试可以运行 `rtk npm run tauri -- dev`。升级本机应用时，按 [AGENTS.md](AGENTS.md) 执行备份、安装和启动台核验。

## Windows 11 x64

运行 x64 安装程序 `*-setup.exe`，安装后可通过开始菜单和任务栏右下角的托盘打开应用。Windows 需要 WebView2。系统缺少运行时时，安装程序会尝试安装。

在 GitHub Actions 的 **Desktop build** 中下载 `Codex-Usage-windows-x64`，或在安装 [Tauri Windows 构建依赖](https://v2.tauri.app/start/prerequisites/#windows)的 Windows x64 电脑上运行：

```powershell
npm ci
cargo test --locked -p usage-core
.\Windows\Package.ps1
```

安装程序位于 `target/x86_64-pc-windows-msvc/release/bundle/nsis/`。Windows 版从开始菜单或托盘手动启动。

## macOS 下跟随 Codex 自动启停

把构建产物放进“应用程序”后，需要手动启动一次 Codex Usage。应用会注册内嵌的后台辅助程序；macOS 首次使用时可能要求在“系统设置 → 通用 → 登录项”中允许它后台运行。

如果 macOS 拒绝运行临时签名的助手，需用同一个 Apple 签发的签名身份签署主程序和助手。构建时将 `APPLE_SIGNING_IDENTITY=-` 换成钥匙串中的签名身份。手动打开菜单栏应用仍可查看统计。[Apple 签名说明](https://developer.apple.com/forums/thread/799910)

后续替换为新版本并重新启动 Codex Usage 时，应用会在主程序、助手、启动配置或安装路径发生变化后自动刷新后台注册，不需要手动删除旧登录项。仅更新主程序时也会刷新，避免旧注册失效导致无法跟随 Codex 启动。

发布新的 macOS 构建时，请递增 `src-tauri/tauri.macos.conf.json` 中的 `bundle.macOS.bundleVersion`。本机实测替换同一构建号的临时签名应用时，系统可能继续按旧构建校验后台助手。

替换应用时，不要把旧版本改名后继续留在 `/Applications` 或 `~/Applications`。即使目录名变成 `Codex Usage.app.backup-*`，macOS 仍可能按包内相同的 bundle identifier 将它收录为另一个启动台项目。需要保留旧版本时，请先移到“废纸篓”或 Applications 目录之外，再复制并启动新版本。

启用后的行为：

- Codex 启动时，自动启动 Codex Usage；
- Codex 使用 `⌘Q`、菜单“退出”、强制退出或崩溃后，自动退出 Codex Usage；
- 只关闭 Codex 窗口、但 Codex 进程仍在运行时，Codex Usage 保持运行；
- Codex 运行期间手动退出 Codex Usage 后，不会立刻强制重新启动，等下次启动 Codex 时再自动打开。

后台辅助程序只通过 macOS 查询运行中应用的 bundle identifier，不读取 Codex 的窗口、任务、对话或文件内容。

## 用量与额度口径

弹窗首页显示本周剩余额度、今日总量及输入/缓存/输出明细。底部可打开「最近 7 天」和「历史周期」，在子页左上角返回概览。右上角可刷新或切换「极光卡片」与「环形仪表」，macOS 升级后会继续使用旧版保存的样式。首页底部显示最近一次取得周额度的时间和退出入口。额度读取失败或读数已过期时，菜单栏保留上次额度，首页提示额度状态。超过预计重置时间尚未取得新额度时，首页会提示等待新额度。

首页“今日 Token”和“最近 7 天”的单日详情会按模型显示本机用量。首页的列表默认收拢，点击“按模型”即可展开或收拢。点按模型行可展开输入、其中缓存和输出。升级后会重扫保留范围内的本地日志，为旧记录补上模型名。缺少模型归属的本地用量列为“未知模型”。单日详情显示本机记录合计，便于和账户校准总量对照。七天趋势和周期明细对已结束的完整自然日采用相同规则：有当天的官方 Token 记录就采用官方数值，包括明确返回的 0；缺少当天的官方记录时显示本机用量并标注“本地统计”。

“最近 7 天”的每日列表按日期倒序排列，今天位于最上方。横条按七天最高单日 Token 对比。每日列表显示“当日额度消耗”：直接计算官方已用额度的当日增量，例如 38% → 45% 显示 7%，与 Token 数量无关。按本地自然日统计，今天统计到最近的额度快照。重置日显示重置时间，并分别展示“重置前 / 重置后”的消耗；一天多次重置时按时间顺序显示各段；点击日期行可打开独立详情卡，查看完整 Token 数值、每段时间范围和记录完整性说明，七天列表保持原位；点击卡片外部或关闭按钮可收起，较长详情可在卡片内滚动。每段百分比对应各自周期额度，不把跨重置合计显示成当前周期消耗，Token 列仍为全天总量。零点、日末和重置前使用不超过 10 分钟的记录；跨夜空档只有在同周期两侧读数相同时才能确认边界值。边界记录不足但有可确认增量时显示“已记录消耗”并标注“记录不完整”；重置日各段分别保留已记录增量，不合并成完整的全天百分比。没有可确认增量的分段显示“记录不足”，无重置日显示 `—`。数据精度和延迟取决于官方额度快照；“Token 状态”仅表示 Token 校准状态，缺失的额度记录不会凭空补成 0。

会话索引同时补采 `token_count.rate_limits` 中的周额度快照，补齐应用退出或接口暂时失败时遗漏的历史记录。升级后自动重扫保留范围内的日志，Token 按原事件签名去重。日志额度仅补充主动读取已确认的周期，排除并发会话携带的回退旧值和与后续主动读取冲突的值；当前额度和刷新状态仍以主动读取为准。补采后同周期跨夜读数一致即可重算两天的完整消耗，确实无法确认的缺口仍标为记录不完整。

主界面“今日 Token”旁同步显示当日额度消耗；点按“当日额度消耗”即可在首页打开当天详情，关闭后仍在首页。重置日沿用最近 7 天的分段口径。“当前周期 Token”和历史周期列表显示各自“额度已用”百分比：当前周期使用最新官方累计已用值，已结束周期仅采用该周期结束前 10 分钟内的最后一条官方记录，不把提前重置等同于额度耗尽。已结束周期缺少临近结束的记录时，保留该周期“最后记录”的已用百分比并标注“记录不完整”，悬停可查看采集时间；它不代表周期结束时的最终值。同周期读数下降、没有可用记录或只有估算边界时仍显示“额度记录不足”，不使用当前周期数值倒推。

历史周期列表支持点按周期行打开独立详情卡，查看完整 Token 数值、精确到分钟的起止时间及周期内每天的 Token 和额度消耗，关闭详情后保留列表位置。每日明细只统计属于该周期的时段，支持最近 7 天以外的历史周期；完整自然日有官方 Token 时标“官方校准”，首尾不足一天、今天或没有官方日数据时标“本地统计”。周期全部使用本地记录时显示“本地统计”，混用官方和本地记录时显示“部分校准”，详情说明具体来源；额度的“已记录”表示仅有可确认的部分增量，缺失记录不补成 0。

历史周期结合官方额度记录识别重置：连续额度记录中已用额度仍为 0 时的起点修正归入同一次重置，后续刷新会自动修复已有碎片并重新汇总 Token。已发生额度消耗后的真实重置会保留，因此前后两个真实周期可能共享同一天作为边界日期。

界面深浅色跟随系统。缓存 Token 已包含在输入 Token 中，明细标为「其中缓存」。

## SQLite 数据兼容

Rust 应用直接打开原有数据库：

- macOS：`~/Library/Application Support/Codex Usage/usage.sqlite`
- Windows：`%LOCALAPPDATA%\Codex Usage\usage.sqlite`

沿用 Swift SQLite v3 表结构、Unix 时间戳、事件去重签名和文件游标。较早版本数据库沿用原有升级逻辑，重新补扫日志并保留旧数据。升级前请退出旧版应用。Mac 上已保存的 Codex Home 会在可解析时继续使用。

macOS 和 Windows 各自读取本机 Codex 日志与本机数据库。官方已结束自然日以账号接口返回的值校准，两端都可显示当前账号的周额度。

## 测试

```bash
rtk cargo test --locked --workspace
rtk proxy node --check ui/app.js
```

macOS 上改动后台助手时，用 `rtk cargo test --locked --workspace --features codex-usage/macos-watcher` 一并运行助手测试。

Rust 测试使用 `crates/usage-core/tests/fixtures/` 中的 JSONL 会话样例验证日志续读和去重，并验证旧版 Swift 写出的 SQLite v3 数据、早期库升级、事务回滚和额度周期。Windows CI 在 x64 上执行 Core 测试、构建 NSIS 安装包，并检查打包前的应用能启动。

## 数据来源与隐私边界

核心库只调用 Codex `app-server` 的只读方法：

- `initialize`
- `account/rateLimits/read`
- `account/usage/read`

本地 session 索引只提取 token 计数、模型标识、时间和文件游标。公开模型、日志和 SQLite 数据库不会保存消息正文或凭据；resolver 和 indexer 不读取或打开 `auth.json`。应用没有遥测、分析 SDK 或第三方数据上传。退出时停止监听、退出子进程并为 SQLite 执行 WAL checkpoint。

## 项目结构

```text
crates/usage-core/   # Rust 统计、数据库、日志和 Codex app-server
src-tauri/          # 桌面应用、托盘、目录对话框和系统集成
ui/                 # macOS 和 Windows 共用的界面
Windows/            # Windows 构建和启动测试
```

## License

本项目采用 [MIT License](LICENSE)。
