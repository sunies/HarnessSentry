import Foundation

public struct RuleEvaluation: Sendable {
    public let incident: Incident
    public let evidenceEventIDs: [UUID]

    public init(incident: Incident, evidenceEventIDs: [UUID]) {
        self.incident = incident
        self.evidenceEventIDs = evidenceEventIDs
    }
}

/// Deterministic, local-only rules. One event creates at most one incident so
/// repeated hook delivery cannot generate duplicate alerts.
public enum AnomalyRuleEngine {
    public static func evaluate(event: BehaviorEvent, recentEvents: [BehaviorEvent] = []) -> RuleEvaluation? {
        let target = event.target?.lowercased() ?? ""
        let cwd = event.metadata["cwd"]?.lowercased()

        if isCredentialPath(target) {
            return finding(
                event: event,
                title: "访问敏感凭据路径",
                summary: "\(displayName(event.toolID)) 访问了凭据或密钥相关路径：\(event.target ?? "已脱敏路径")。",
                severity: event.sessionID == nil ? 94 : 86,
                evidenceIDs: [event.id]
            )
        }

        if target.contains("/.git/objects") || target.contains(".git/objects") {
            return finding(
                event: event,
                title: "遍历 Git 对象数据库",
                summary: "检测到对 .git/objects 的读取或遍历，这可能用于绕过工作区文件边界收集仓库内容。",
                severity: 78,
                evidenceIDs: [event.id]
            )
        }

        if event.type == .networkUpload {
            let commandClass = event.metadata["commandClass"]
            let archive = recentEvents.first {
                $0.toolID == event.toolID &&
                ($0.sessionID == event.sessionID || event.sessionID == nil) &&
                $0.type == .archiveCreate &&
                abs($0.timestamp.timeIntervalSince(event.timestamp)) <= 300
            }
            if let archive {
                return finding(
                    event: event,
                    title: "代码归档后发生网络发送",
                    summary: "5 分钟内先创建归档，随后向 \(event.target ?? "未确认目标") 发起发送；请核对用户任务、仓库或存储桶与授权。",
                    severity: 96,
                    evidenceIDs: [archive.id, event.id]
                )
            }
            if commandClass == "git-push" {
                return finding(
                    event: event,
                    title: "Git 推送待核实",
                    summary: "检测到向 \(event.target ?? "未解析远端") 的 Git 推送。单凭 push 无法判定是否偷传；请核对任务授权、工作区和远端仓库。",
                    severity: event.target == nil ? 70 : 60,
                    evidenceIDs: [event.id]
                )
            }
            if commandClass == "object-storage-upload" {
                return finding(
                    event: event,
                    title: "对象存储上传待核实",
                    summary: "检测到向 \(event.target ?? "未解析存储桶") 上传。请核对任务授权、存储桶归属与上传内容；仅凭 OSS/S3 地址无法判定意图。",
                    severity: event.target == nil ? 78 : 72,
                    evidenceIDs: [event.id]
                )
            }
            return finding(
                event: event,
                title: "网络发送待核实",
                summary: "\(displayName(event.toolID)) 通过工具调用向 \(event.target ?? "未确认目标") 发送数据；请核对任务与目的地。",
                severity: 82,
                evidenceIDs: [event.id]
            )
        }

        if event.type == .archiveCreate {
            if event.toolID == "zcode",
               target.contains("/.zcode/v2/checkpoints") || target.hasSuffix(".enc") {
                let traversal = recentEvents.first {
                    $0.toolID == event.toolID &&
                    $0.target?.lowercased().contains("/.git/objects") == true &&
                    abs($0.timestamp.timeIntervalSince(event.timestamp)) <= 300
                }
                if let traversal {
                    return finding(
                        event: event,
                        title: "ZCode 遍历 Git 并创建仓库快照",
                        summary: "5 分钟内检测到 ZCode 遍历 .git/objects，随后在 checkpoint 目录创建加密归档；这符合问题版本的仓库快照链，是否外发仍需网络证据确认。",
                        severity: 96,
                        evidenceIDs: [traversal.id, event.id]
                    )
                }
                return finding(
                    event: event,
                    title: "ZCode 创建加密仓库快照",
                    summary: "检测到 ZCode 在 checkpoint 目录创建加密归档；请检查前序 Git 遍历和后续网络行为。",
                    severity: 86,
                    evidenceIDs: [event.id]
                )
            }
            return finding(
                event: event,
                title: "会话中创建代码归档",
                summary: "检测到归档工具调用：\(event.target ?? "目标未暴露")。若任务未要求打包，应检查后续网络行为。",
                severity: 58,
                evidenceIDs: [event.id]
            )
        }

        if let cwd,
           !target.isEmpty,
           (target.hasPrefix("/") || target.hasPrefix("~/")),
           !isWithin(target, root: cwd),
           !isExpectedDevelopmentRead(target: target, type: event.type),
           [.fileOpen, .fileCreate, .fileWrite, .directoryTraversal].contains(event.type) {
            return finding(
                event: event,
                title: "访问会话工作区之外的路径",
                summary: "\(displayName(event.toolID)) 在会话工作区之外执行了 \(event.type.rawValue)：\(event.target ?? "已脱敏路径")。",
                severity: 68,
                evidenceIDs: [event.id]
            )
        }

        if event.type == .monitorGap {
            return finding(
                event: event,
                title: "监测链路出现缺口",
                summary: event.target ?? "传感器暂时不可用，期间行为证据可能不完整。",
                severity: 72,
                evidenceIDs: [event.id]
            )
        }
        return nil
    }

    private static func finding(event: BehaviorEvent, title: String, summary: String, severity: Int, evidenceIDs: [UUID]) -> RuleEvaluation {
        let isMock = event.metadata["mock"] == "true"
        return RuleEvaluation(
            incident: Incident(
                id: event.id,
                createdAt: event.timestamp,
                updatedAt: event.timestamp,
                toolID: event.toolID,
                sessionID: event.sessionID,
                title: isMock ? "[Mock] \(title)" : title,
                summary: isMock ? "模拟测试事件，不代表真实行为。\(summary)" : summary,
                severity: severity,
                evidence: event.evidence
            ),
            evidenceEventIDs: evidenceIDs
        )
    }

    private static func isCredentialPath(_ path: String) -> Bool {
        ["/.ssh/", "/.aws/", "/.gnupg/", "/.kube/config", "/.config/gcloud/", "/.docker/config.json", "/.env", "/.npmrc", "/.pypirc", "id_rsa", "id_ed25519", ".pem", ".p12"].contains {
            path.contains($0)
        }
    }

    private static func isWithin(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Dependency caches and SDKs are routinely read outside a project's cwd.
    /// Only read/traversal events are exempt; writes, archives, uploads and
    /// credential paths retain their normal evaluation.
    private static func isExpectedDevelopmentRead(target: String, type: BehaviorType) -> Bool {
        guard type == .fileOpen || type == .directoryTraversal else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path.lowercased()
        let path = target == home ? "~" :
            (target.hasPrefix(home + "/") ? "~" + String(target.dropFirst(home.count)) : target)
        return developmentReadRoots.contains { isWithin(path, root: $0) }
    }

    private static let developmentReadRoots: [String] = [
        // Temporary fixtures, compiler scratch data and test sandboxes. Reads
        // are routine; writes, archives and uploads still follow their own
        // rules, and credential checks run before this exception.
        "/tmp", "/private/tmp", "/var/folders", "/private/var/folders",
        // Java and Android
        "~/.m2/repository", "~/.gradle/caches", "~/.gradle/wrapper/dists", "~/.gradle/jdks",
        "~/.sdkman/candidates", "~/.jenv/versions", "~/library/android/sdk", "~/android/sdk",
        "/library/java/javavirtualmachines", "/applications/android studio.app/contents",
        "/applications/deveco-studio.app/contents/sdk", "~/library/huawei/sdk", "~/openharmony/sdk",
        // Node.js, package managers and globally installed modules
        "~/.npm/_cacache", "~/.npm/_npx", "~/.pnpm-store", "~/library/pnpm/store",
        "~/.cache/yarn", "~/library/caches/yarn", "~/.yarn/berry/cache",
        "~/.bun/install/cache", "~/.nvm/versions/node", "~/.fnm/node-versions",
        "~/.volta/tools/image/node", "~/.asdf/installs/nodejs",
        "/opt/homebrew/lib/node_modules", "/usr/local/lib/node_modules",
        // Python, Go and Rust
        "~/.cache/pip", "~/.cache/uv", "~/.uv/cache", "~/.pyenv/versions",
        "~/.local/share/virtualenvs", "~/library/caches/pypoetry/virtualenvs",
        "~/miniconda3", "~/anaconda3", "~/go/pkg/mod", "~/.cache/go-build",
        "~/.cargo/registry", "~/.cargo/git", "~/.rustup/toolchains",
        // Swift, Apple SDKs and other common package caches
        "~/library/developer/xcode/deriveddata/sourcepackages",
        "~/library/developer/coresimulator/profiles/runtimes",
        "~/.swiftpm", "~/library/caches/org.swift.swiftpm",
        "/applications/xcode.app/contents/developer", "/library/developer/commandlinetools",
        "/library/developer/coresimulator", "/opt/homebrew/cellar", "/usr/local/cellar",
        "~/.nuget/packages", "~/.pub-cache", "~/.composer/cache", "~/library/caches/composer",
    ]

    private static func displayName(_ id: String) -> String {
        BuiltInAdapters.all.first(where: { $0.id == id })?.displayName ?? id
    }
}
