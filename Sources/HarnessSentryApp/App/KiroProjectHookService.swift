import Foundation
import HarnessSentryCore

struct KiroProjectHookResult: Sendable {
    let configurationURL: URL
    let backupURL: URL?
}

actor KiroProjectHookService {
    private let hookExecutableURL: URL

    init(hookExecutableURL: URL? = nil) {
        self.hookExecutableURL = hookExecutableURL ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/HarnessSentryHook")
    }

    func install(projectURL: URL) throws -> KiroProjectHookResult {
        guard FileManager.default.isExecutableFile(atPath: hookExecutableURL.path) else {
            throw HookIntegrationServiceError.hookExecutableUnavailable(hookExecutableURL)
        }
        let url = configurationURL(projectURL: projectURL)
        let data = try HookConfigurationBuilder.kiroProjectData(executablePath: hookExecutableURL.path)
        return try write(data, to: url)
    }

    func remove(projectURL: URL) throws -> URL? {
        let url = configurationURL(projectURL: projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let backup = backupURL(for: url)
        do {
            try FileManager.default.copyItem(at: url, to: backup)
            try FileManager.default.removeItem(at: url)
            return backup
        } catch {
            throw HookIntegrationServiceError.cannotWrite(url, error.localizedDescription)
        }
    }

    private func configurationURL(projectURL: URL) -> URL {
        projectURL.standardizedFileURL
            .appendingPathComponent(".kiro/hooks", isDirectory: true)
            .appendingPathComponent("harnesssentry.json")
    }

    private func write(_ data: Data, to url: URL) throws -> KiroProjectHookResult {
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
        return KiroProjectHookResult(configurationURL: url, backupURL: backup)
    }

    private func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("harnesssentry-backup-\(Int(Date().timeIntervalSince1970))")
    }
}
