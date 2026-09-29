# Endpoint Security 可选组件

> 状态：源码脚手架，可迁移到独立的 Xcode System Extension target；当前 Swift Package 和 Community `.app` **不会构建、嵌入或激活**该组件。

## 它补充什么能力

Community 传感器只能依赖 Harness hook、GUI 应用生命周期和低频进程发现。ES Sensor 获得用户批准后，可在内核已经完成操作时接收 `NOTIFY` 元数据，用于补齐：

- Harness 及其子进程的 `exec`、`fork`、`exit`；
- 文件 `open`、`close`、`write`、`unlink`、`truncate`；
- 稳定的 `(pid, pidversion)` 进程标识、签名 ID、Team ID；
- ES 序号，供主应用识别传感器丢事件/监测空洞。

当前设计仅订阅通知事件，不订阅 `AUTH`，因此不会允许、拒绝或等待被监测程序的系统调用。它也不会读取文件内容、命令参数、环境变量、Prompt、模型响应或网络正文。

Endpoint Security 不提供通用 TCP/HTTPS 出站请求可见性。因此，ES Sensor 本身不能证明某段内容上传到了哪个 URL。上传风险应由主应用将“敏感文件读取/归档/工具执行”与 Hook 或以后独立的 Network Extension 元数据关联；不要把 `uipc_connect`（Unix domain socket）误当成互联网连接。

## 为什么开源 Community 包里不能直接启用

ES Sensor 的生产分发同时需要：

1. 完整 Xcode 创建并打包 System Extension target；
2. Apple Developer Program 团队和 Developer ID 签名；
3. Apple 为该 Team ID 批准 `com.apple.developer.endpoint-security.client` 限制型 entitlement；
4. 宿主 App 使用 `com.apple.developer.system-extension.install`；
5. App 与扩展使用相同 Team ID 签名、Hardened Runtime，并完成公证；
6. 用户批准系统扩展并授予 Full Disk Access。

开源许可不会绕过这些平台要求。未签名、adhoc 签名或未获得 Apple entitlement 的构建仍可正常使用 Community 传感器，但 `es_new_client` 会返回未授权/未许可/非特权错误。

Apple 官方要求 System Extension 位于 App 的 `Contents/Library/SystemExtensions`，宿主从合适的 `/Applications` 目录启动后请求激活。扩展和宿主还必须满足签名、标识符及公证校验。

## 目录说明

```text
EndpointSecurityExtension/
├── Configuration/
│   ├── EndpointSecurityExtension.entitlements  # 扩展：ES entitlement
│   ├── HostApp.entitlements                    # 宿主：安装系统扩展
│   ├── Info.plist                              # SYSX + 使用说明 + Mach service
│   └── EndpointSecurityExtension.xcconfig
├── Sources/
│   ├── main.swift                              # 扩展入口
│   ├── EndpointSecurityMonitor.swift           # 双 ES client 与事件映射
│   ├── ESWireEvent.swift                       # 最小化 IPC 数据模型
│   ├── EventBufferXPC.swift                    # 有界内存队列与只读 XPC
│   ├── ExtensionConfiguration.swift
│   └── HarnessClassifier.swift
└── HostIntegration/
    ├── SystemExtensionController.swift         # 激活/卸载示例
    └── EndpointSecurityXPCClient.swift          # 拉取事件示例
```

这些文件特意不在 `Package.swift` 中。SPM 可编译普通可执行文件，但不能代替 Xcode 完成 System Extension 的产品类型、嵌入、签名与 provisioning 流程。

## Xcode 迁移步骤

1. 用完整 Xcode 建立或打开 macOS App 工程，为现有 App 添加 System Extension/Endpoint Security 扩展 target，部署目标保持 macOS 14。
2. 将 `EndpointSecurityExtension/Sources` 加入扩展 target。`main.swift` 使用顶层入口，不要同时保留模板生成的另一个 `main`。
3. 链接 `libEndpointSecurity.tbd`、`libbsm.tbd`、Foundation 和 Security。
4. 将 `Configuration/Info.plist`、`.xcconfig` 和 `EndpointSecurityExtension.entitlements` 设到扩展 target；把真实 bundle ID 替换成项目命名空间。
5. 将 `HostIntegration/SystemExtensionController.swift` 加入宿主 target，并把 `HostApp.entitlements` 的 System Extension capability 合并到宿主 entitlement。不要覆盖宿主已有键。
6. 让 `HarnessSentryESXPCProtocol` 同时属于宿主和扩展 target，或移到一个只含 IPC 协议的小型共享 framework；把 `EndpointSecurityXPCClient.swift` 加入宿主。
7. 在宿主 target 的 Build Phases 中嵌入扩展，最终路径必须是：

   ```text
   HarnessSentry.app/Contents/Library/SystemExtensions/
   com.harnesssentry.sensor.endpoint-security.systemextension
   ```

8. 确认 App 与扩展使用相同 Team ID，开启 Hardened Runtime。扩展 bundle 的文件名（去掉 `.systemextension`）必须匹配 bundle identifier。
9. 在 Apple Developer 后台申请 Endpoint Security entitlement，重新生成包含相应授权的 provisioning profile。
10. 将签名并公证的 App 放入 `/Applications`。由明确的用户操作调用 `SystemExtensionController.activate`，不要在无提示的首次启动中偷偷安装。

`Info.plist` 中这几个值必须作为一个整体修改：

| 键 | 示例 | 用途 |
|---|---|---|
| `CFBundleIdentifier` | `com.harnesssentry.sensor.endpoint-security` | 扩展激活 ID |
| `NSEndpointSecurityMachServiceName` | `TEAMID.com.harnesssentry.sensor.endpoint-security.xpc` | 系统注册的全局 XPC 端点 |
| `HarnessSentryAllowedClientBundleIdentifier` | `com.harnesssentry.app` | 允许读取事件的宿主签名 ID |
| `HarnessSentryAllowedTeamIdentifier` | `TEAMID` | 允许读取事件的宿主 Team ID |

当前开源 App 是 Developer ID 直发、非 App Sandbox 路线。若以后启用 App Sandbox，不要依赖临时 Mach lookup exception 作为正式设计；注册 App Group，并让 IPC 服务名成为该 App Group ID 的子名称，然后为两端 provision 相同 App Group。

## 数据与性能设计

### 双 client 过滤

`EndpointSecurityMonitor` 使用两个 ES client：

- discovery client 只接收全局 `exec/fork/exit`；
- activity client 反转 process muting，只接收已识别 Harness 进程树的文件事件。

这样不会把全机文件事件送进 Swift 层再做字符串过滤。发现 Harness 后，扩展用其 audit token 选择该进程；其 fork/exec 子树继续继承跟踪。扩展启动前已经运行的 Harness 不会立刻被选中，需由宿主在激活提示中说明“重启编程助手完成深度监测”，或在正式实现中增加一次受控的初始进程种子流程。

### 回调约束

ES 回调只做固定字段拷贝、路径用户名脱敏和一次轻量状态查找，不做以下操作：

- SQLite/文件写入；
- 网络请求；
- 同步 XPC；
- 哈希文件或读取内容；
- 模型推理和复杂规则判断。

映射后的值对象被发送到 `.utility` 队列编码。扩展仅保留最多 2,048 条内存事件；宿主未运行或消费过慢时，淘汰最旧记录并累加 `dropped`，不会形成无限磁盘日志。持久化、默认 2 天保留和磁盘上限仍由主 App 统一负责。

### IPC 安全

扩展只暴露“拉取事件/健康状态”两个只读方法，并按宿主 bundle ID 与 Team ID 校验连接方代码签名。当前 `NSXPCListener` 示例在连接建立时按 PID 校验，适合作为迁移脚手架；发布前建议改成底层 XPC，并对每个请求使用 `SecCodeCreateWithXPCMessage` 做绑定消息发送者 audit token 的校验，以消除 PID 重用窗口。

典型事件（不会包含内容正文）：

```json
{
  "schemaVersion": 1,
  "unixNanoseconds": 1789982021123456789,
  "kind": "file_open",
  "processID": 4231,
  "processVersion": 18,
  "processPath": "~/.local/bin/claude",
  "signingIdentifier": null,
  "teamIdentifier": null,
  "targetPath": "~/Projects/acme/.env",
  "openFlags": 1,
  "sequence": 92,
  "globalSequence": 314,
  "messageVersion": 8
}
```

## 安装、验证和卸载

用户触发安装后，macOS 可能要求管理员/系统设置确认。批准扩展后，还需在“系统设置 → 隐私与安全性 → 完全磁盘访问权限”中允许 ES 扩展。权限未完成时，主 App 应保持降级状态而不是反复弹窗。

只读验证命令：

```bash
systemextensionsctl list
codesign --verify --deep --strict /Applications/HarnessSentry.app
codesign -d --entitlements :- \
  /Applications/HarnessSentry.app/Contents/Library/SystemExtensions/*.systemextension
log stream --predicate 'subsystem == "com.harnesssentry.sensor.endpoint-security"'
```

正常卸载优先由宿主调用 `deactivationRequest`。删除宿主 App 也会让系统管理对应扩展；不要用脚本强删 `/Library/SystemExtensions`。

不要为了日常开发在主力电脑关闭 SIP。若团队尚未获得 entitlement，需要按 Apple 调试文档在隔离测试机/虚拟机中评估相关安全设置，并在测试后恢复。

## 发布前检查清单

- [ ] Apple 已为生产 Team ID 批准 ES entitlement，profile 中可见该键。
- [ ] 宿主和扩展 Team ID 一致，均启用 Hardened Runtime。
- [ ] `.systemextension` 的文件名与 bundle ID 一致。
- [ ] 扩展嵌入 `Contents/Library/SystemExtensions`。
- [ ] App 和扩展一起完成 Developer ID 公证与 stapling。
- [ ] 用户能看到安装目的、降级原因、Full Disk Access 状态和卸载入口。
- [ ] 重启 Harness 后可收到文件元数据；未启用 ES 时 Community 模式仍正常。
- [ ] 压测时没有 AUTH 超时（本设计无 AUTH）、没有未界限队列、没有文件内容或 Prompt 泄漏。
- [ ] 主 App 能根据 `globalSequence` 和 `dropped` 生成“监测空洞”记录。
- [ ] XPC 改为按消息 audit token 验签，或风险经过独立安全评审。

## 官方资料

- [Endpoint Security](https://developer.apple.com/documentation/endpointsecurity)
- [System Extensions](https://developer.apple.com/documentation/systemextensions)
- [Installing System Extensions and Drivers](https://developer.apple.com/documentation/systemextensions/installing-system-extensions-and-drivers)
- [System Extension entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.system-extension.install)
- [Apple Endpoint Security sample](https://developer.apple.com/documentation/endpointsecurity/monitoring-system-events-with-endpoint-security)
