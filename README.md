# HarnessSentry

HarnessSentry 是一个面向 macOS 编程 Agent/Harness 的本机行为审计工具。它用菜单栏状态、行为时间线和异常证据回答一个问题：编程 Agent 是否在用户请求之外读取、归档或发送了不该接触的数据？

> 当前是早期开发版。规则命中代表“需要核查”，不是对某个产品或进程的恶意判定。请不要把 HarnessSentry 当作 EDR、DLP 或沙箱的替代品。

## 已实现

- 原生 AppKit + SwiftUI 菜单栏应用，正常、异常、基础监测和暂停四种状态；带单实例保护，菜单可直接退出；
- 概览中的最近异常、已加载事件趋势和最近观察到的工具；结构化行为表格与日期筛选、异常详情时间线、证据导出、标记安全、单条/批量删除和“以后允许”规则；
- SQLite WAL 本地存储，默认普通行为保留 2 天、异常保留 30 天、数据库严格上限 200 MB；
- 基于 `NSWorkspace` 通知的 GUI Harness 启动/退出采集，不轮询图形应用；
- 每 10 秒在 utility 队列扫描一次 CLI 进程，只记录已知 Harness 的启动/退出状态变化；
- 16 个可选用户级 A3 集成：Codex、Claude Code、WorkBuddy、Qoder、ZCode、Cursor、Windsurf、GitHub Copilot CLI、Gemini CLI、Qwen Code、Continue、iFlow CLI、Kimi Code CLI、Goose、Cline 和 TRAE；支持安全安装、状态检测、备份和移除；Kiro 与 OpenCode 另按项目安装；
- WorkBuddy 审计日志增量桥接：从当前文件末尾开始低频读取新增记录，原始命令只在内存中分类，不回放历史、不保存正文；
- 本地异常规则：凭据路径访问、`.git/objects` 遍历、工作区外访问、创建归档、非模型网络发送、归档后发送和监测缺口；
- 21 个内置 Harness 适配器：Codex、Claude Code、WorkBuddy、Qoder、ZCode、Cursor、Windsurf、GitHub Copilot、Gemini CLI、Cline、Roo Code、Continue、Kiro、TRAE、Aider、OpenCode、Qwen Code、Kimi Code CLI、iFlow CLI、Goose 和 DeepSeek Harness（`dsh`）；
- 跨进程暂停状态，菜单应用暂停后独立 Hook 也停止落库；
- 低开销资源看门狗，资源压力升高时自动把 CLI 扫描周期从 10 秒调整为 30/60 秒；
- 默认关闭且明确标记的 Mock 异常链，用于在没有系统扩展权限时验证界面、规则和通知；
- 登录启动、系统通知开关、15 项自检、应用图标以及 ad-hoc `.app` 打包脚本；
- Endpoint Security 可用性探测和独立 Sensor 边界。

仓库已包含可迁移到 Xcode target 的 [Endpoint Security 源码脚手架](docs/EndpointSecurity.md)，但真正的事件订阅仍需要带 Apple entitlement 的签名 System Extension。Community 构建目前不会订阅 ES 文件或网络事件；没有 Hook 的适配器只能提供 A1/A2 级进程可见性，不能声称看到了完整文件或上传行为。

## 监测层级

| 层级 | 数据来源 | 当前能力 |
| --- | --- | --- |
| A1 | 低频 CLI 进程扫描 | 已知命令行 Harness 的启动/退出 |
| A2 | `NSWorkspace` | 图形 Harness 的启动/退出及基础归属 |
| A3 | Harness Hook / 插件 / 本机审计桥接 | 16 个用户级集成、Kiro/OpenCode 项目集成、WorkBuddy 增量审计；记录会话 ID、工具类型、脱敏目标和本地规则关联 |
| ES | Endpoint Security System Extension | 仅探测/接口，事件订阅尚未随 Community 构建交付 |

菜单栏在 Community 采集器健康且无异常时保持绿色“保护中”；未启用可选 ES Sensor 不算故障。灰色只表示短暂启动中，橙色“低影响模式”表示本应用资源压力持续偏高并已降低扫描频率，红色表示待处理异常或监测故障。工具列表使用离线的已核对图标或本机已安装 App 的图标；无可靠图标时显示中性终端符号，不再伪造品牌图形。图标只在首次显示时查找并缓存。

规则对 Maven、Gradle、npm、pnpm、Yarn 及其他常见依赖缓存、Android/DevEco/Xcode SDK、系统临时目录，以及当前 Harness 自己管理的 Skill/会话上下文资源的只读访问作边界例外；Harness 数据域从适配器身份动态推导，不靠文件名正则。相对路径按会话工作区还原，避免把 `app/src/...` 错判为 `/src/...`。写入、凭据读取、归档和网络发送不因此放行。Git 推送与对象存储上传会标记为“待核实”，而不是直接定性为代码偷传；已确认的目标可创建按仓库指纹或存储桶限定的允许规则。检测依据和盲区见 [检测策略](docs/detection-policy.md)。

## 隐私边界

HarnessSentry 的原则是记录行为元数据，不复制用户内容：

- 不保存源码内容、Prompt、模型回复、工具输出、凭据或网络请求正文；
- Hook 输入只在当前进程内解析，原始 shell 命令不落盘，只保存命令分类和 SHA-256；
- URL 只保存主机名，路径会把当前用户主目录缩写为 `~`；
- 会保存检测所需的时间、Harness、会话 ID、行为类型、目标路径/主机、进程 ID/路径和证据级别；
- 数据默认位于 `~/Library/Application Support/HarnessSentry/HarnessSentry.sqlite`，不会由 HarnessSentry 主动上传。

完整说明见 [PRIVACY.md](PRIVACY.md)。证据 JSON 可能包含文件名、目录结构和网络主机名，分享前仍应人工检查。

## 环境

- macOS 14 或更高版本；
- Swift 6.2 或更高版本；
- Community 构建与自检不要求完整 Xcode；正式 System Extension 工程、Developer ID 签名和公证需要 Xcode 及对应 Apple 权限。

## 开发运行

```bash
swift run HarnessSentrySelfTest
swift run HarnessSentry
```

应用以菜单栏附件模式运行，不显示 Dock 图标。Debug 构建的弹出菜单中有本地测试异常入口。

## 构建本地 App

```bash
chmod +x Scripts/build-app.sh
Scripts/build-app.sh release
open dist/HarnessSentry.app
```

脚本会构建主程序、`HarnessSentryHook` 与隔离实验使用的 `HarnessSentryLabProbe`，生成图标、组装 `.app` 并执行 ad-hoc 签名。该签名仅适合本机开发测试，不是 Developer ID 签名，也没有经过 Apple 公证。仓库当前不宣称提供可绕过 Gatekeeper 的发行包。

需要生成便于本地分发的 ZIP 和 SHA-256 文件时：

```bash
Scripts/package-release.sh
```

产物名取自应用版本和当前架构，例如 `dist/HarnessSentry-0.4.7-arm64.zip`。脚本会重新构建、检查 ZIP、`Info.plist` 与 ad-hoc 签名；若同版本产物已经存在则报错退出，不会覆盖旧文件。该 ZIP 仍未经过 Developer ID 签名或 Apple 公证。

推送与应用版本一致的标签（例如 `v0.4.7`）后，Community Release workflow 会自动运行自检、生成 ZIP/SHA-256 并创建未公证的 GitHub Release。该流程不需要付费 Apple Developer 账号，但不能消除 Gatekeeper 的首次运行提示。

## 可选：接入 A3 Hooks

Hook 能提供会话级信息，但属于显式 opt-in。可在“工具适配器”页面点击“安装 Hook”；应用会语义合并 JSON、保留其他配置，并在修改前创建备份。HarnessSentry 不会在没有用户操作时修改配置。建议先把最终安装路径固定，例如 `/Applications/HarnessSentry.app`，否则移动应用后配置中的可执行文件路径会失效。

仅生成并检查配置：

```bash
Scripts/print-hook-config.sh codex
Scripts/print-hook-config.sh claude-code
Scripts/print-hook-config.sh workbuddy
Scripts/print-hook-config.sh zcode
Scripts/print-hook-config.sh cursor
Scripts/print-hook-config.sh continue
Scripts/print-hook-config.sh iflow-cli
Scripts/print-hook-config.sh kimi-cli
Scripts/print-hook-config.sh goose
Scripts/print-hook-config.sh cline
Scripts/print-hook-config.sh trae
```

也可以指定自定义 Hook 二进制：

```bash
Scripts/print-hook-config.sh codex /absolute/path/to/HarnessSentryHook
```

各 Harness 的事件名、配置结构和同步策略并不相同，生成器会按官方协议输出对应格式。不要把某个工具的 JSON 复制给另一个工具，也不要直接覆盖已有配置。修改后重启对应 Harness，并在 HarnessSentry 的“行为日志”确认出现 Hook 事件。完整路径、事件和性能边界见 [Hook 集成说明](docs/hook-integration.md)。

## ZCode 3.12.3 隔离复现实验

仓库提供一个只用于研究复现的 `eslogger` 桥接传感器。它订阅指定 ZCode.app 内进程的文件事件，把 `.git/objects` 遍历、checkpoint 和加密归档写入 HarnessSentry 的正式事件库；默认不保存源码、Prompt、请求正文或原始 JSONL，并把大量 Git 对象访问折叠去重。

实验必须使用带 `.harnesssentry-zcode-decoy` 标记的隔离仓库，脚本会拒绝真实项目：

```bash
Scripts/create-zcode-decoy-repo.sh
Scripts/zcode-lab-capture.sh \
  /tmp/HarnessSentry-ZCodeLab-3.12.3/ZCode-3.12.3.app \
  /tmp/HarnessSentry-ZCodeLab-3.12.3/decoy-workspace
```

`eslogger` 需要管理员权限，并要求负责运行它的终端具有“完全磁盘访问权限”。这是实验桥接，不是发布架构；Apple 明确说明 `eslogger` 不是应用 API，正式版仍应使用获得 Endpoint Security entitlement 的原生 System Extension。版本、哈希和复现边界见 [ZCode 实验记录](docs/zcode-3.12.3-lab.md)。

## 性能设计

- 图形应用生命周期由系统通知驱动；
- CLI 扫描通常为 10 秒，并带 2 秒调度余量，只记录状态变化；资源超预算时自动调整为 30/60 秒；
- 支持异步 Hook 的 Harness 默认异步执行；协议只提供同步 Hook 的产品仅接入必要的后置事件，接收器失败时静默成功；
- WorkBuddy 审计桥接每 15 秒检查一次，只读取文件追加部分，单次上限 512 KB；
- Hook 输入有 2 MB 上限，数据库查询和证据条数有上限；
- 留存清理在后台执行，可在设置中选择行为/异常保留时长和 100/200/500 MB 数据库上限；达到阈值后按普通事件、已处置异常、未固定开放异常的顺序严格回收。

“低开销”是实现约束，不是对所有硬件和工作负载的绝对承诺。提交性能问题时，请附 macOS 版本、机器型号、同时运行的 Harness 数量和可复现步骤，但不要上传敏感数据库。

## 验证

```bash
swift build --product HarnessSentry
swift build --product HarnessSentryHook
swift run HarnessSentrySelfTest
Scripts/build-app.sh release
codesign --verify --deep --strict dist/HarnessSentry.app
plutil -lint dist/HarnessSentry.app/Contents/Info.plist
```

GitHub Actions 会在 macOS runner 上执行同样的 Community 构建和自检。CI 产物仍是未做 Developer ID 签名/公证的开发构建。

## 误报与安全记录

规则命中后可以：

1. 查看时间、会话、目标和关联证据；
2. 标记为安全，保留审计结论；
3. 创建精确到 Harness、行为类型和目标的允许规则；
4. 删除异常或允许规则；
5. 导出本地 JSON 供人工复核。

“标记安全”与“以后允许”含义不同。前者只处置当前异常，后者会影响相同模式的后续检测。

## 开源许可证与发布状态

HarnessSentry 采用 [Apache License 2.0](LICENSE) 开源，包含明确的版权与专利授权条款。Developer ID 签名、公证和生产 ES entitlement 尚未完成；这些发行条件不影响源码在 Apache-2.0 下使用和贡献。

贡献方式见 [CONTRIBUTING.md](CONTRIBUTING.md)，安全问题见 [SECURITY.md](SECURITY.md)。

## 后续计划

- 将现有 ES Sensor 脚手架落到独立、签名并嵌入的 Xcode System Extension Target；
- 补充更多 Harness 的官方 Hook/插件适配和真实文件/网络元数据源；
- 增强会话归并、规则去重和可解释性；
- 加入规则导入导出、诱饵仓库向导和经过脱敏的诊断包；
- 在具备 Developer ID 与公证凭据后增加签名发布流水线。
