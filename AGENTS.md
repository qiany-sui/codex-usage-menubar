# 项目协作约定

## 本机应用交付

本项目日常使用的应用安装在 `/Applications/Codex Usage.app`。修改 App 或 UsageCore 的功能、界面或运行行为后，**默认必须完成构建、安装、启动台入口更新、重启和运行验证，才能报告交付完成**。从启动台点击 Codex Usage 图标，也必须打开本次交付的新版。只生成 `DerivedData` 中的新版或提供产物链接，不代表用户已经在使用新版；重启旧的已安装应用也不会自动更新。

纯文档修改、只读调查，以及用户明确要求仅修改代码或生成构建产物时，不需要安装和重启。

交付步骤：

1. 运行与改动相关的测试，并构建本机签名的 Release App。命令使用 `rtk` 前缀，构建和测试说明见 [README.md](README.md)。
2. 核对构建产物和签名，再退出当前运行的 Codex Usage。仅操作该应用，不退出 Codex 桌面应用。
3. 将旧版备份到 Applications 目录之外，例如 `DerivedData/Install-Backups/<时间戳>/Codex Usage.app`。不要把改名后的旧版留在 `/Applications` 或 `~/Applications`，避免重复的启动台项目。
4. 用新版完整替换 `/Applications/Codex Usage.app`，保留现有用量数据库和用户偏好设置。若替换失败，恢复旧版并说明实际状态。
5. 更新并核验启动台中的 Codex Usage 入口，确保关联 `/Applications/Codex Usage.app` 的新版。若存在指向旧构建副本的失效或重复入口，定位并仅修复本应用的入口，保留其他应用和启动台布局。
6. 退出正在运行的 Codex Usage 后，从启动台点击其图标重新启动。核对实际运行进程的可执行文件路径为 `/Applications/Codex Usage.app/Contents/MacOS/Codex Usage`，并比较该可执行文件与本次 Release 产物的 SHA-256，确认启动台打开的是新版。
7. 打开受影响的页面，验证新增功能或修复结果。若启动台或界面自动检查不可用，先完成安装、从明确安装路径启动和进程核验，并分别说明尚未完成的启动台或页面验证；直接启动安装路径不能替代启动台入口核验。

只有完成实际安装和重启后，才在交付说明中写“已安装并重启”；若被权限或其他问题阻止，应明确说明停在哪一步以及还需要什么操作。

### Release 构建命令

```bash
rtk xcodebuild build -project App/CodexUsage.xcodeproj -scheme CodexUsage -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/Release
```

产物：`DerivedData/Release/Build/Products/Release/Codex Usage.app`。用于实际安装的版本应保留本机签名；无签名测试产物不作为默认交付版本。
