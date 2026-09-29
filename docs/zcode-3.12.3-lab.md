# ZCode 3.12.3 隔离实验记录

## 样本

- 官方下载地址：`https://cdn-zcode.z.ai/zcode/electron/releases/3.12.3/macos-arm64/ZCode-3.12.3-mac-arm64.dmg`
- 文件：`ZCode-3.12.3-mac-arm64.dmg`
- SHA-256：`ca92e81f0ecc18eaf26b5f0185a4d3ca99f07c658b20ba5424a77e06c81c7a94`
- Bundle ID：`dev.zcode.app`
- 版本：`3.12.3`
- Team ID：`8A5X4JJ39T`
- 签名主体：`Developer ID Application: Beijing Knowledge Atlas Technology Joint Stock Company Limited (8A5X4JJ39T)`
- 本机 Gatekeeper 校验：`accepted`，`Notarized Developer ID`

样本只读挂载后复制到 `/tmp/HarnessSentry-ZCodeLab-3.12.3/ZCode-3.12.3.app`，没有覆盖 `/Applications`，也没有接触真实仓库。

## 静态核验

在 `Contents/Resources/app.asar` 中确认存在以下标识：

- `RepoSnapshotSidecarService`
- `RepoSnapshotUploadClient`
- `/api/v1/snapshot/upload-credential`
- `scanRepoSnapshot`
- `createEncryptedRepoSnapshotArtifact`
- `captureBeforePromptUnsafe`
- `repo-snapshot-upload`

这证明 3.12.3 包含仓库扫描、加密快照和上传凭据请求相关实现，但静态字符串本身不证明某一次会话已经成功外发。

## 动态检测范围

`Scripts/zcode-lab-capture.sh` 使用 macOS 自带的 `eslogger` 订阅指定 ZCode.app 内进程的 `open`、`close`、`create`、`write`、`rename`、`unlink`、`readdir` 和 `exec` 通知。事件经 `HarnessSentryLabProbe` 脱敏、筛选并写入与应用相同的 SQLite 数据库。

高信号证据包括：

1. ZCode 遍历隔离仓库的 `.git/objects`；
2. ZCode 在 `~/.zcode/v2/checkpoints` 创建文件；
3. ZCode 创建 `.enc`、`.tar`、`.tgz`、`.zip` 等归档；
4. 5 分钟内出现 Git 对象遍历后再创建 ZCode 加密 checkpoint，合并为一条关联异常。

该实验桥接不声称证明上传成功。上传结论必须再结合目标地址、出站字节和服务端回执；模型正常请求与未知中转地址也不能仅靠域名判定内容。

## 安全边界

- 只允许版本 `3.12.3`；
- 测试仓库必须有 `.harnesssentry-zcode-decoy` 标记；
- 默认只记录高信号事件；
- `.git/objects/<hash>` 统一折叠为 `.git/objects`，并做短窗去重；
- 不保存源码、Prompt、请求正文、环境变量或原始 `eslogger` JSONL；
- 样本、用户数据与隔离仓库均放在 `/tmp/HarnessSentry-ZCodeLab-3.12.3`；
- 不使用真实 ZCode 账号、Token、仓库或项目。

动态采集需要一次 macOS 管理员授权，而且执行 `eslogger` 的负责进程需要“完全磁盘访问权限”。Apple 不保证 `eslogger` 输出稳定，因此这里只把它用于本地复现实验；发行版传感器仍是原生 Endpoint Security System Extension。
