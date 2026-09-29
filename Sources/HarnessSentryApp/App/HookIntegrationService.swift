import Foundation
import HarnessSentryCore

enum HookIntegrationTarget: String, CaseIterable, Hashable, Sendable {
    case codex
    case claudeCode = "claude-code"
    case workBuddy = "workbuddy"
    case qoder
    case zcode
    case cursor
    case windsurf
    case copilot
    case geminiCLI = "gemini-cli"
    case qwenCode = "qwen-code"
    case continueCLI = "continue"
    case iFlowCLI = "iflow-cli"
    case kimiCLI = "kimi-cli"
    case goose
    case cline
    case trae

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .workBuddy: "WorkBuddy"
        case .qoder: "Qoder"
        case .zcode: "ZCode"
        case .cursor: "Cursor"
        case .windsurf: "Windsurf"
        case .copilot: "GitHub Copilot CLI"
        case .geminiCLI: "Gemini CLI"
        case .qwenCode: "Qwen Code"
        case .continueCLI: "Continue"
        case .iFlowCLI: "iFlow CLI"
        case .kimiCLI: "Kimi Code CLI"
        case .goose: "Goose"
        case .cline: "Cline"
        case .trae: "TRAE"
        }
    }

    fileprivate func configurationURL(homeDirectory: URL) -> URL {
        switch self {
        case .codex:
            homeDirectory.appendingPathComponent(".codex/hooks.json")
        case .claudeCode:
            homeDirectory.appendingPathComponent(".claude/settings.json")
        case .workBuddy:
            homeDirectory.appendingPathComponent(".workbuddy/settings.json")
        case .qoder:
            homeDirectory.appendingPathComponent(".qoder/settings.json")
        case .zcode:
            homeDirectory.appendingPathComponent(".zcode/cli/config.json")
        case .cursor:
            homeDirectory.appendingPathComponent(".cursor/hooks.json")
        case .windsurf:
            homeDirectory.appendingPathComponent(".codeium/windsurf/hooks.json")
        case .copilot:
            homeDirectory.appendingPathComponent(".copilot/hooks/harnesssentry.json")
        case .geminiCLI:
            homeDirectory.appendingPathComponent(".gemini/settings.json")
        case .qwenCode:
            homeDirectory.appendingPathComponent(".qwen/settings.json")
        case .continueCLI:
            homeDirectory.appendingPathComponent(".continue/settings.json")
        case .iFlowCLI:
            homeDirectory.appendingPathComponent(".iflow/settings.json")
        case .kimiCLI:
            homeDirectory.appendingPathComponent(".kimi-code/config.toml")
        case .goose:
            homeDirectory.appendingPathComponent(".agents/plugins/harnesssentry/hooks/hooks.json")
        case .cline:
            homeDirectory.appendingPathComponent(".cline/plugins/harnesssentry.js")
        case .trae:
            homeDirectory.appendingPathComponent(".trae-cn/hooks.json")
        }
    }

    fileprivate var storageKind: HookStorageKind {
        switch self {
        case .kimiCLI: .kimiTOML
        case .cline: .ownedFile
        default: .json
        }
    }
}

private enum HookStorageKind: Equatable {
    case json
    case kimiTOML
    case ownedFile
}

enum HookIntegrationStatus: Equatable, Sendable {
    case notInstalled(configurationURL: URL)
    case installed(configurationURL: URL)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

enum HookIntegrationAction: String, Equatable, Sendable {
    case installed
    case updated
    case alreadyInstalled
    case removed
    case alreadyRemoved
}

struct HookIntegrationResult: Equatable, Sendable {
    let target: HookIntegrationTarget
    let action: HookIntegrationAction
    let configurationURL: URL
    let backupURL: URL?
}

enum HookIntegrationServiceError: Error, LocalizedError, Sendable {
    case hookExecutableUnavailable(URL)
    case configurationTooLarge(URL, Int)
    case cannotRead(URL, String)
    case invalidConfiguration(URL, String)
    case cannotCreateDirectory(URL, String)
    case cannotCreateBackup(URL, String)
    case cannotWrite(URL, String)

    var errorDescription: String? {
        switch self {
        case .hookExecutableUnavailable(let url):
            "Hook 接收器不存在或不可执行：\(url.path)"
        case .configurationTooLarge(let url, let bytes):
            "Hook 配置超过 4 MB 安全上限（\(bytes) bytes）：\(url.path)"
        case .cannotRead(let url, let reason):
            "无法读取 Hook 配置 \(url.path)：\(reason)"
        case .invalidConfiguration(let url, let reason):
            "Hook 配置格式无效 \(url.path)：\(reason)"
        case .cannotCreateDirectory(let url, let reason):
            "无法创建配置目录 \(url.path)：\(reason)"
        case .cannotCreateBackup(let url, let reason):
            "无法在修改前创建备份 \(url.path)：\(reason)"
        case .cannotWrite(let url, let reason):
            "无法安全写入 Hook 配置 \(url.path)：\(reason)"
        }
    }
}

/// Owns user-level Hook configuration I/O. The actor serializes changes made
/// through this service; it never edits project-level Harness configuration.
actor HookIntegrationService {
    private static let maximumConfigurationBytes = 4 * 1_024 * 1_024

    private let homeDirectory: URL
    private let hookExecutableURL: URL

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        hookExecutableURL: URL? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.hookExecutableURL = hookExecutableURL ?? Self.defaultHookExecutableURL()
    }

    func status(for target: HookIntegrationTarget) throws -> HookIntegrationStatus {
        let configurationURL = target.configurationURL(homeDirectory: homeDirectory)
        guard let data = try readConfiguration(at: configurationURL) else {
            return .notInstalled(configurationURL: configurationURL)
        }
        if target.storageKind == .kimiTOML || target.storageKind == .ownedFile {
            let installed = String(data: data, encoding: .utf8)?.contains(ManagedHookArtifactBuilder.marker) == true
            return installed ? .installed(configurationURL: configurationURL) : .notInstalled(configurationURL: configurationURL)
        }
        do {
            let installed = try HookConfigurationEditor.containsHarnessSentryHandler(
                in: data,
                adapterID: target.rawValue
            )
            if target == .goose, installed, !gooseManifestIsOwned() {
                return .notInstalled(configurationURL: configurationURL)
            }
            return installed
                ? .installed(configurationURL: configurationURL)
                : .notInstalled(configurationURL: configurationURL)
        } catch {
            throw HookIntegrationServiceError.invalidConfiguration(
                configurationURL,
                error.localizedDescription
            )
        }
    }

    func install(_ target: HookIntegrationTarget) throws -> HookIntegrationResult {
        guard FileManager.default.isExecutableFile(atPath: hookExecutableURL.path) else {
            throw HookIntegrationServiceError.hookExecutableUnavailable(hookExecutableURL)
        }

        let configurationURL = target.configurationURL(homeDirectory: homeDirectory)
        let existingData = try readConfiguration(at: configurationURL)
        switch target.storageKind {
        case .kimiTOML:
            return try installKimi(target, existingData: existingData, at: configurationURL)
        case .ownedFile:
            return try installOwnedFile(target, existingData: existingData, at: configurationURL)
        case .json:
            break
        }
        if target == .goose {
            try ensureGooseManifest()
        }
        let wasInstalled: Bool
        let mutation: HookConfigurationMutation
        do {
            wasInstalled = try existingData.map {
                try HookConfigurationEditor.containsHarnessSentryHandler(in: $0, adapterID: target.rawValue)
            } ?? false
            mutation = try HookConfigurationEditor.installing(
                in: existingData,
                executablePath: hookExecutableURL.standardizedFileURL.path,
                adapterID: target.rawValue
            )
        } catch {
            throw HookIntegrationServiceError.invalidConfiguration(
                configurationURL,
                error.localizedDescription
            )
        }

        guard mutation.changed else {
            return HookIntegrationResult(
                target: target,
                action: .alreadyInstalled,
                configurationURL: configurationURL,
                backupURL: nil
            )
        }

        let backupURL = try write(
            mutation.data,
            replacing: existingData,
            at: configurationURL
        )
        return HookIntegrationResult(
            target: target,
            action: wasInstalled ? .updated : .installed,
            configurationURL: configurationURL,
            backupURL: backupURL
        )
    }

    func uninstall(_ target: HookIntegrationTarget) throws -> HookIntegrationResult {
        let configurationURL = target.configurationURL(homeDirectory: homeDirectory)
        guard let existingData = try readConfiguration(at: configurationURL) else {
            return HookIntegrationResult(
                target: target,
                action: .alreadyRemoved,
                configurationURL: configurationURL,
                backupURL: nil
            )
        }
        switch target.storageKind {
        case .kimiTOML:
            return try uninstallKimi(target, existingData: existingData, at: configurationURL)
        case .ownedFile:
            return try uninstallOwnedFile(target, existingData: existingData, at: configurationURL)
        case .json:
            break
        }

        let mutation: HookConfigurationMutation
        do {
            mutation = try HookConfigurationEditor.removing(
                from: existingData,
                adapterID: target.rawValue
            )
        } catch {
            throw HookIntegrationServiceError.invalidConfiguration(
                configurationURL,
                error.localizedDescription
            )
        }
        guard mutation.changed else {
            return HookIntegrationResult(
                target: target,
                action: .alreadyRemoved,
                configurationURL: configurationURL,
                backupURL: nil
            )
        }

        let backupURL = try write(
            mutation.data,
            replacing: existingData,
            at: configurationURL
        )
        if target == .goose {
            try removeGooseOwnedFiles(configurationURL: configurationURL)
        }
        return HookIntegrationResult(
            target: target,
            action: .removed,
            configurationURL: configurationURL,
            backupURL: backupURL
        )
    }

    private func installKimi(
        _ target: HookIntegrationTarget,
        existingData: Data?,
        at url: URL
    ) throws -> HookIntegrationResult {
        let existing = try utf8Text(existingData, at: url)
        let block = ManagedHookArtifactBuilder.kimiBlock(executablePath: hookExecutableURL.standardizedFileURL.path)
        let updated = try replacingManagedBlock(in: existing, with: block, at: url)
        guard updated != existing else {
            return HookIntegrationResult(target: target, action: .alreadyInstalled, configurationURL: url, backupURL: nil)
        }
        let wasInstalled = existing.contains(ManagedHookArtifactBuilder.marker)
        let backup = try write(Data(updated.utf8), replacing: existingData, at: url)
        return HookIntegrationResult(
            target: target,
            action: wasInstalled ? .updated : .installed,
            configurationURL: url,
            backupURL: backup
        )
    }

    private func uninstallKimi(
        _ target: HookIntegrationTarget,
        existingData: Data,
        at url: URL
    ) throws -> HookIntegrationResult {
        let existing = try utf8Text(existingData, at: url)
        guard existing.contains(ManagedHookArtifactBuilder.marker) else {
            return HookIntegrationResult(target: target, action: .alreadyRemoved, configurationURL: url, backupURL: nil)
        }
        let updated = try replacingManagedBlock(in: existing, with: nil, at: url)
        let backup = try write(Data(updated.utf8), replacing: existingData, at: url)
        return HookIntegrationResult(target: target, action: .removed, configurationURL: url, backupURL: backup)
    }

    private func installOwnedFile(
        _ target: HookIntegrationTarget,
        existingData: Data?,
        at url: URL
    ) throws -> HookIntegrationResult {
        let generated: Data
        do {
            generated = try ManagedHookArtifactBuilder.data(
                executablePath: hookExecutableURL.standardizedFileURL.path,
                adapterID: target.rawValue
            )
        } catch {
            throw HookIntegrationServiceError.invalidConfiguration(url, error.localizedDescription)
        }
        if existingData == generated {
            return HookIntegrationResult(target: target, action: .alreadyInstalled, configurationURL: url, backupURL: nil)
        }
        if let existingData,
           String(data: existingData, encoding: .utf8)?.contains(ManagedHookArtifactBuilder.marker) != true {
            throw HookIntegrationServiceError.invalidConfiguration(
                url,
                "该路径已有非 HarnessSentry 文件，未覆盖"
            )
        }
        let backup = try write(generated, replacing: existingData, at: url)
        return HookIntegrationResult(
            target: target,
            action: existingData == nil ? .installed : .updated,
            configurationURL: url,
            backupURL: backup
        )
    }

    private func uninstallOwnedFile(
        _ target: HookIntegrationTarget,
        existingData: Data,
        at url: URL
    ) throws -> HookIntegrationResult {
        guard String(data: existingData, encoding: .utf8)?.contains(ManagedHookArtifactBuilder.marker) == true else {
            return HookIntegrationResult(target: target, action: .alreadyRemoved, configurationURL: url, backupURL: nil)
        }
        let backup = makeBackupURL(for: url)
        do {
            try FileManager.default.copyItem(at: url, to: backup)
            try FileManager.default.removeItem(at: url)
        } catch {
            throw HookIntegrationServiceError.cannotWrite(url, error.localizedDescription)
        }
        return HookIntegrationResult(target: target, action: .removed, configurationURL: url, backupURL: backup)
    }

    private func ensureGooseManifest() throws {
        let url = homeDirectory.appendingPathComponent(".agents/plugins/harnesssentry/plugin.json")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.7"
        let expected = try JSONSerialization.data(withJSONObject: [
            "name": "harnesssentry",
            "version": version,
            "description": "Local, redacted behavior metadata bridge for HarnessSentry",
        ], options: [.prettyPrinted, .sortedKeys])
        if let existing = try readConfiguration(at: url) {
            guard let object = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
                  object["name"] as? String == "harnesssentry" else {
                throw HookIntegrationServiceError.invalidConfiguration(url, "插件目录已被其他插件占用")
            }
            if existing == expected { return }
        }
        _ = try write(expected, replacing: try readConfiguration(at: url), at: url)
    }

    private func gooseManifestIsOwned() -> Bool {
        let url = homeDirectory.appendingPathComponent(".agents/plugins/harnesssentry/plugin.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["name"] as? String == "harnesssentry"
    }

    private func removeGooseOwnedFiles(configurationURL: URL) throws {
        let manifestURL = homeDirectory.appendingPathComponent(".agents/plugins/harnesssentry/plugin.json")
        guard gooseManifestIsOwned() else { return }
        do {
            if FileManager.default.fileExists(atPath: configurationURL.path) {
                try FileManager.default.removeItem(at: configurationURL)
            }
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                try FileManager.default.removeItem(at: manifestURL)
            }
        } catch {
            throw HookIntegrationServiceError.cannotWrite(configurationURL, error.localizedDescription)
        }
    }

    private func utf8Text(_ data: Data?, at url: URL) throws -> String {
        guard let data else { return "" }
        guard let text = String(data: data, encoding: .utf8) else {
            throw HookIntegrationServiceError.invalidConfiguration(url, "文件不是 UTF-8 文本")
        }
        return text
    }

    private func replacingManagedBlock(in text: String, with replacement: String?, at url: URL) throws -> String {
        let begin = "# BEGIN \(ManagedHookArtifactBuilder.marker)"
        let end = "# END \(ManagedHookArtifactBuilder.marker)"
        let beginRange = text.range(of: begin)
        let endRange = text.range(of: end)
        let hasDuplicateBegin = beginRange.map { text[$0.upperBound...].contains(begin) } ?? false
        let hasDuplicateEnd = endRange.map { text[$0.upperBound...].contains(end) } ?? false
        guard (beginRange == nil) == (endRange == nil), !hasDuplicateBegin, !hasDuplicateEnd else {
            throw HookIntegrationServiceError.invalidConfiguration(url, "HarnessSentry 管理标记不完整或重复")
        }
        if let beginRange, let endRange {
            guard beginRange.lowerBound < endRange.lowerBound else {
                throw HookIntegrationServiceError.invalidConfiguration(url, "HarnessSentry 管理标记顺序错误")
            }
            let blockRange = beginRange.lowerBound..<endRange.upperBound
            var updated = text
            updated.replaceSubrange(blockRange, with: replacement ?? "")
            return updated
        }
        guard let replacement else { return text }
        let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        return text + separator + (text.isEmpty ? "" : "\n") + replacement + "\n"
    }

    private func readConfiguration(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= Self.maximumConfigurationBytes else {
                throw HookIntegrationServiceError.configurationTooLarge(url, data.count)
            }
            return data
        } catch let error as HookIntegrationServiceError {
            throw error
        } catch {
            throw HookIntegrationServiceError.cannotRead(url, error.localizedDescription)
        }
    }

    private func write(_ data: Data, replacing existingData: Data?, at url: URL) throws -> URL? {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw HookIntegrationServiceError.cannotCreateDirectory(directory, error.localizedDescription)
        }

        let existingPermissions: Int? = if existingData != nil {
            (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
        } else {
            nil
        }

        let backupURL: URL?
        if existingData != nil {
            let candidate = makeBackupURL(for: url)
            do {
                try fileManager.copyItem(at: url, to: candidate)
                backupURL = candidate
            } catch {
                throw HookIntegrationServiceError.cannotCreateBackup(candidate, error.localizedDescription)
            }
        } else {
            backupURL = nil
        }

        do {
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: existingPermissions ?? 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw HookIntegrationServiceError.cannotWrite(url, error.localizedDescription)
        }
        return backupURL
    }

    private func makeBackupURL(for configurationURL: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: Date())
        let nonce = UUID().uuidString.prefix(8).lowercased()
        return configurationURL.appendingPathExtension("harnesssentry-backup-\(stamp)-\(nonce)")
    }

    private static func defaultHookExecutableURL() -> URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/HarnessSentryHook")
        if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            return bundled
        }
        return Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("HarnessSentryHook") ?? bundled
    }
}
