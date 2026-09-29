# 检测策略与误报边界

HarnessSentry 把“观察到行为”与“认定为恶意”分开。当前 Community 版可为 Codex、Claude Code、WorkBuddy、Qoder、ZCode、Cursor、Windsurf、GitHub Copilot CLI、Gemini CLI、Qwen Code、Continue、iFlow CLI、Kimi Code CLI、Goose、Cline 和 TRAE 安装用户级 A3 Hook/插件，Kiro 与 OpenCode 使用项目级集成；WorkBuddy 还可读取本机审计日志的新增记录。其余适配器（包括 DeepSeek Harness 的 `dsh`）目前主要提供进程级可见性。没有 ES Sensor 时，仍不能宣称捕获了任何 Harness 的全部文件和网络行为。

## Git 推送和对象存储

正常发布、CI、备份和偷传都可能表现为 `git push`、`aws s3 cp` 或 `ossutil cp`。仅看 GitHub、GitLab、S3、OSS 这类域名，或者上传字节数，无法判断用户意图。系统会保留时间、会话、工具、命令类别与脱敏目标，并以“待核实”提示，而不是称其为“偷代码”。核对时应同时看：

1. 用户任务是否明确要求推送/上传，或是否经过明确批准；
2. 操作是否发生在当前仓库和会话，目标远端或存储桶是否与项目惯用目标一致；
3. 是否紧接着读取凭据、遍历 `.git/objects`、读取其他工作区或打包源码；
4. 若有系统级证据，发送进程、实际目标和字节量是否与 Hook 声称一致。

Hook 不保存 Prompt 或原始命令，因此第 1 点不能自动证明。Git 远端从当前工作区的 `.git/config` 以只读方式解析，最多检查 10 层父目录和 256 KB 配置；本地只存远端主机加仓库身份哈希，不存完整仓库 URL 或凭据。只有目标明确时才能建立“以后允许”；即使是同一个 Git 主机，换了仓库也不会命中旧规则。OSS/S3 规则限定到具体存储桶。无法解析远端时仍提示核对，但不提供过宽的永久允许规则。下载命令不会标记为上传。

标记单条“安全”只处理该记录，不表示今后所有类似行为均安全。用户选择“以后允许”前，应核对真实远端、任务与权限；中转站、自建 Git/对象存储以及同名伪装目标仍需按实际控制方判断。

## 工作区外的常见开发路径

只读打开或遍历 Maven、Gradle、npm、pnpm、Yarn、Node 版本管理器、Python/Go/Rust 包缓存、Android/DevEco/Xcode/Java SDK，以及 `/tmp`、`/private/tmp` 和当前用户系统临时目录中的测试夹具，属于常见开发行为，不因“工作区外”单独报警。相对路径先按会话工作区还原，避免把 `app/src/...` 从中间截成根目录路径。目录边界按完整路径段匹配，不放行整个 `~/.cache`、`~/Library` 或其他项目目录。

例外不适用于写入/创建、归档、上传或凭据路径。`.npmrc`、`.pypirc`、SSH/AWS 密钥等仍按敏感路径处理。对未列出的自定义缓存或 SDK 位置，先保留提示，用户可在核对后处理记录；不会根据目录名的模糊匹配全局放行。
