# Hook 集成说明

HarnessSentry 的 A3 接收器从标准输入读取 Harness 发送的单个 JSON 对象，提取行为元数据后静默退出。它不返回权限决定、不阻止工具调用，也不会由接收器自行修改 Harness 配置。

## 支持范围

| Harness | 安装范围 | 配置位置 |
| --- | --- | --- |
| Codex | 用户级 | `~/.codex/hooks.json` |
| Claude Code | 用户级 | `~/.claude/settings.json` |
| WorkBuddy | 用户级 | `~/.workbuddy/settings.json` |
| Qoder | 用户级 | `~/.qoder/settings.json` |
| ZCode | 用户级 | `~/.zcode/cli/config.json` |
| Cursor | 用户级 | `~/.cursor/hooks.json` |
| Windsurf | 用户级 | `~/.codeium/windsurf/hooks.json` |
| GitHub Copilot CLI | 用户级、独立文件 | `~/.copilot/hooks/harnesssentry.json` |
| Gemini CLI | 用户级 | `~/.gemini/settings.json` |
| Qwen Code | 用户级 | `~/.qwen/settings.json` |
| Continue CLI | 用户级 | `~/.continue/settings.json` |
| iFlow CLI | 用户级 | `~/.iflow/settings.json` |
| Kimi Code CLI | 用户级、TOML 管理块 | `~/.kimi-code/config.toml` |
| Goose | 用户级、独立插件 | `~/.agents/plugins/harnesssentry/` |
| Cline CLI | 用户级、独立插件 | `~/.cline/plugins/harnesssentry.js` |
| TRAE | 用户级 | `~/.trae-cn/hooks.json` |
| Kiro | 项目级 | `<project>/.kiro/hooks/harnesssentry.json` |
| OpenCode | 项目级、独立插件 | `<project>/.opencode/plugins/harnesssentry/index.ts` |

WorkBuddy 另有只读审计日志桥接。它不要求修改 WorkBuddy 配置：HarnessSentry 启动时从当天日志末尾开始，每 15 秒读取一次新增部分；不会导入旧记录，单次最多读取 512 KB，命令正文经分类和哈希后即丢弃。

其他适配器当前仍是 A1/A2 进程可见性。表中“支持 A3”不等于拥有系统级文件或网络监控；完整覆盖仍需要 Endpoint Security Sensor。

暂未标为 A3 的内置适配器不是简单漏项：Roo Code 没有公开的用户级生命周期 Hook，仓库里的任务事件属于扩展内部 API；Aider 提供脚本调用方式但没有可订阅的 Agent 生命周期 Hook；DeepSeek Harness 处于明确会发生破坏性变更的 developer preview，插件还要按 `DSH_HOME` 与 profile 安装，当前不能安全地写成一个通用全局安装按钮。它们继续使用 A1/A2 与通用规则，等出现稳定、可卸载且能保留用户配置的协议后再升级。

## 从应用内安装

打开“工具适配器”，在支持的工具行点击“安装 Hook”。只有这次明确操作才会修改配置。安装器会：

- 对共享 JSON 做语义合并，不覆盖无关 Hook 或顶层设置；
- 对 Kimi 只替换有明确起止标记的 TOML 管理块；Goose、Cline 使用 HarnessSentry 独占的插件路径；
- 修改前在同一目录创建时间戳备份；
- 使用原子写入并保留原文件权限，新文件使用 `0600`；
- 检测重复安装；卸载时只删除 HarnessSentry handler；
- 按各 Harness 的配置结构生成事件名和参数，不跨产品复用 JSON。

Kiro 和 OpenCode 不假定用户级全局位置。点击对应的“项目 Hook/项目插件”后选择项目目录，安装器分别只修改 `.kiro/hooks/harnesssentry.json` 和 `.opencode/plugins/harnesssentry/index.ts`。

应用移动到其他路径后，应再次点击安装以更新接收器路径。部分 Harness 会审查或提示信任外部 Hook；安装后按产品提示确认并重启对应 Harness。

## 手工生成配置

只生成配置、不写用户目录：

```bash
Scripts/print-hook-config.sh codex
Scripts/print-hook-config.sh claude-code
Scripts/print-hook-config.sh workbuddy
Scripts/print-hook-config.sh qoder
Scripts/print-hook-config.sh zcode
Scripts/print-hook-config.sh cursor
Scripts/print-hook-config.sh windsurf
Scripts/print-hook-config.sh copilot
Scripts/print-hook-config.sh gemini-cli
Scripts/print-hook-config.sh qwen-code
Scripts/print-hook-config.sh continue
Scripts/print-hook-config.sh iflow-cli
Scripts/print-hook-config.sh kimi-cli
Scripts/print-hook-config.sh goose
Scripts/print-hook-config.sh cline
Scripts/print-hook-config.sh trae
```

脚本按以下顺序寻找接收器：

1. `/Applications/HarnessSentry.app/Contents/MacOS/HarnessSentryHook`
2. 仓库的 `dist/HarnessSentry.app/Contents/MacOS/HarnessSentryHook`
3. 本地 Swift debug 构建产物

也可把自定义绝对路径作为第二个参数。脚本只向标准输出打印对应的 JSON、TOML 管理块或插件源码，不读取或写入 Harness 配置。生成结果必须按目标 Harness 的规则安装或合并，不要覆盖完整配置文件。

## 事件与性能边界

事件集合由目标 Harness 决定。通常包含会话开始、工具执行结果和会话/Agent 结束；Windsurf 只接入读取、写入、命令和 MCP 的后置事件；Kiro 使用 SessionStart、AgentSpawn、PostToolUse 和 Stop。

支持异步处理的 Harness 默认使用异步 Hook。其他格式只安装必要的后置事件并设置 5 秒超时；Cline 与 OpenCode 插件也只派生不等待的本地接收器进程。Kimi 的官方格式只写 `event`、`command`、`timeout` 三个允许字段；Goose 使用合法的 `.*` 正则而不是无效的 `*`。如果某个 Harness 明显变慢，应先移除该 Hook 并提交可复现信息。

接收器输入上限为 2 MB；数据库写入失败或 JSON 不可识别时静默成功，避免破坏被监测工具。暂停 HarnessSentry 后，独立接收器会检查共享状态并停止落库。

## 数据最小化

接收器不会把原始 JSON 落盘，并丢弃 Prompt、模型回复、工具结果和原始命令。持久化字段限于：

- 会话 ID、事件名和工具名；
- 当前工作目录和脱敏目标路径，或 URL 主机名；
- 原始命令的 SHA-256 与粗粒度分类；
- Harness 标识、时间和规则证据级别。

因此，Hook 可以提供“某会话执行了疑似归档或发送命令”的证据，但不能证明传输完成，也不能恢复上传内容。系统级结论需与 Endpoint Security 或网络元数据交叉验证。

## 排查与卸载

没有事件时，先确认配置中的接收器路径存在且可执行、应用与 Harness 使用同一 macOS 用户、产品没有禁用用户 Hook，并避免用户级与项目级重复配置。也可把一个无敏感数据的最小 JSON 从终端传给接收器，检查“行为日志”是否出现事件。

优先在“工具适配器”中点击“移除 Hook”；Kiro 与 OpenCode 使用各自的项目菜单。删除 Hook/插件不会删除已经保存的本地审计记录。Kimi 卸载只移除带 HarnessSentry 起止标记的块；Cline/OpenCode 仅在文件仍带管理标记时删除，避免误删用户文件。

协议以各产品官方文档为准：[Codex](https://developers.openai.com/zh-Hans/docs/hooks)、[Claude Code](https://code.claude.com/docs/en/hooks)、[Qoder](https://docs.qoder.com/cli/hooks)、[ZCode](https://zcode.z.ai/en/docs/hooks)、[Cursor](https://prod.cursor.com/docs/hooks)、[Windsurf](https://docs.windsurf.com/de/windsurf/cascade/hooks)、[GitHub Copilot](https://docs.github.com/en/copilot/reference/hooks-reference)、[Gemini CLI](https://github.com/google-gemini/gemini-cli/blob/main/docs/hooks/index.md)、[Qwen Code](https://qwenlm.github.io/qwen-code-docs/en/users/features/hooks/)、[Kimi Code](https://www.kimi.com/code/docs/kimi-code-cli/customization/hooks.html)、[iFlow](https://docs.iflow.cn/cli/examples/hooks/)、[Goose](https://goose-docs.ai/docs/guides/context-engineering/hooks/)、[Cline](https://github.com/cline/cline/blob/main/.agents/skills/cline-sdk/references/plugins/REFERENCE.md)、[TRAE](https://docs.trae.cn/ide_hook-configuration-reference)、[Kiro](https://kiro.dev/docs/hooks/) 和 [OpenCode](https://opencode.ai/v2/docs/build/plugins)。
