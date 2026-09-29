import Foundation
import HarnessSentryCore

struct OpenCodeProjectPluginResult: Sendable {
    let configurationURL: URL
    let backupURL: URL?
}

actor OpenCodeProjectPluginService {
    private let hookExecutableURL: URL

    init(hookExecutableURL: URL? = nil) {
        self.hookExecutableURL = hookExecutableURL ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/HarnessSentryHook")
    }

    func install(projectURL: URL) throws -> OpenCodeProjectPluginResult {
        guard FileManager.default.isExecutableFile(atPath: hookExecutableURL.path) else {
            throw HookIntegrationServiceError.hookExecutableUnavailable(hookExecutableURL)
        }
        let url = pluginURL(projectURL: projectURL)
        let data = Data(ManagedHookArtifactBuilder.openCodeProjectPlugin(
            executablePath: hookExecutableURL.path
        ).utf8)
        if let existing = try? Data(contentsOf: url),
           existing != data,
           String(data: existing, encoding: .utf8)?.contains(ManagedHookArtifactBuilder.marker) != true {
            throw HookIntegrationServiceError.invalidConfiguration(url, "该路径已有非 HarnessSentry 插件，未覆盖")
        }
        return try write(data, to: url)
    }

    func remove(projectURL: URL) throws -> URL? {
        let url = pluginURL(projectURL: projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard String(data: data, encoding: .utf8)?.contains(ManagedHookArtifactBuilder.marker) == true else {
            throw HookIntegrationServiceError.invalidConfiguration(url, "该文件不归 HarnessSentry 管理，未删除")
        }
        let backup = backupURL(for: url)
        do {
            try FileManager.default.copyItem(at: url, to: backup)
            try FileManager.default.removeItem(at: url)
            return backup
        } catch {
            throw HookIntegrationServiceError.cannotWrite(url, error.localizedDescription)
        }
    }

    private func pluginURL(projectURL: URL) -> URL {
        projectURL.standardizedFileURL
            .appendingPathComponent(".opencode/plugins/harnesssentry", isDirectory: true)
            .appendingPathComponent("index.ts")
    }

    private func write(_ data: Data, to url: URL) throws -> OpenCodeProjectPluginResult {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw HookIntegrationServiceError.cannotCreateDirectory(url.deletingLastPathComponent(), error.localizedDescription)
        }
        let backup: URL?
        if manager.fileExists(atPath: url.path) {
            let candidate = backupURL(for: url)
            do {
                try manager.copyItem(at: url, to: candidate)
                backup = candidate
            } catch {
                throw HookIntegrationServiceError.cannotCreateBackup(candidate, error.localizedDescription)
            }
        } else {
            backup = nil
        }
        do {
            try data.write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw HookIntegrationServiceError.cannotWrite(url, error.localizedDescription)
        }
        return OpenCodeProjectPluginResult(configurationURL: url, backupURL: backup)
    }

    private func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("harnesssentry-backup-\(Int(Date().timeIntervalSince1970))")
    }
}
