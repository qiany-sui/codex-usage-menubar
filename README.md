# Codex Usage Menubar

Codex Usage Menubar 的目标是在 macOS 菜单栏中展示 Codex 的本地 token 用量、官方日用量和周额度周期，并在官方接口暂时不可用时保留最后一次成功快照。

当前仓库完成了第一阶段 `UsageCore` Swift Package：会话增量索引、SQLite 持久化、官方用量读取、周期校准和刷新编排均已实现并覆盖测试。菜单栏 App 壳属于第二阶段，尚未创建。

## 环境要求

- Apple Silicon Mac
- macOS 13 或更高版本
- Swift 6.2 或更高版本
- `rtk` 命令行代理

运行第一阶段验收：

```bash
rtk swift test
rtk swift build -c release
```

第二阶段开始前还需要可用的 Xcode 16 或更高版本、已接受的 Xcode license，以及明确的项目开源 license。上述条件就绪后再创建和签名菜单栏 App 壳。

## 第一阶段目录

```text
Sources/UsageCore/
├── AppServer/       # app-server JSON-RPC 只读客户端
├── Coordination/    # 刷新策略与快照编排
├── Domain/          # 公开用量模型
├── Persistence/     # SQLite 存储与游标
├── Reconciliation/  # 本地、官方数据和额度周期校准
└── Sessions/        # session JSONL 增量索引
Tests/UsageCoreTests/ # 单元、集成和隐私回归测试
docs/superpowers/     # 设计与实施计划
```

Swift Package 当前只导出 `UsageCore` library product，最低部署目标为 macOS 13。

## 数据来源与隐私边界

核心库只调用 Codex `app-server` 的只读方法：

- `initialize`
- `account/rateLimits/read`
- `account/usage/read`

本地 session 索引只提取 token 计数、时间和文件游标。公开模型、日志和 SQLite 数据库不会保存消息正文或凭据；resolver 和 indexer 不读取或打开 `auth.json`。数据库仅保存在本机，关闭存储时会截断 WAL checkpoint 并释放 SQLite 连接。

## 设计资料

- [产品与架构设计](docs/superpowers/specs/2026-08-31-codex-usage-menubar-design.md)
- [第一阶段实施计划](docs/superpowers/plans/2026-08-31-codex-usage-core.md)
