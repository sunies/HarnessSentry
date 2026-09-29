import CryptoKit
import Foundation

public enum HookNormalizationError: Error, CustomStringConvertible, Sendable {
    case invalidJSON
    case inputTooLarge

    public var description: String {
        switch self {
        case .invalidJSON: "Hook 输入不是有效的 JSON 对象"
        case .inputTooLarge: "Hook 输入超过 2 MB 安全上限"
        }
    }
}

/// Converts Codex/Claude-compatible hook JSON to privacy-preserving metadata.
/// Prompt text, tool output and raw shell commands are never retained.
public enum HookEventNormalizer {
    public static let maximumInputBytes = 2 * 1_024 * 1_024

    public static func normalize(
        data: Data,
        adapterID: String,
        eventNameOverride: String? = nil,
        source: String = "hook"
    ) throws -> BehaviorEvent {
        guard data.count <= maximumInputBytes else { throw HookNormalizationError.inputTooLarge }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookNormalizationError.invalidJSON
        }

        let eventName = eventNameOverride
            ?? string(object["hook_event_name"] ?? object["hookEventName"] ?? object["event_name"] ?? object["eventName"] ?? object["agent_action_name"])
            ?? "Unknown"
        let inputValue = object["tool_input"] ?? object["toolInput"] ?? object["tool_args"] ?? object["toolArgs"] ?? object["tool_info"]
        let input = dictionary(inputValue)
        let toolName = string(object["tool_name"] ?? object["toolName"] ?? input["mcp_tool_name"])
            ?? inferredToolName(eventName)
        let sessionID = string(object["session_id"] ?? object["sessionId"] ?? object["trajectory_id"])
        let rawCwd = string(object["cwd"] ?? input["cwd"])
        let cwd = sanitizedPath(rawCwd)
        let rawCommand = string(input["command"] ?? input["command_line"])
        let classifiedCommand = rawCommand.map(commandClass)
        let directTarget = firstString(in: input, keys: ["file_path", "path", "directory", "destination", "target", "url"])
        let commandTarget = rawCommand.flatMap { command -> String? in
            switch classifiedCommand {
            case "git-push": gitPushTarget(command: command, cwd: rawCwd)
            case "object-storage-upload": objectStorageTarget(command)
            default: firstPathOrHost(command, cwd: rawCwd)
            }
        }
        let target = classifiedCommand == "git-push" || classifiedCommand == "object-storage-upload"
            ? commandTarget
            : (sanitizedTarget(directTarget, cwd: rawCwd) ?? commandTarget)
        let type = behaviorType(eventName: eventName, toolName: toolName, command: rawCommand)

        var metadata: [String: String] = [
            "source": source,
            "hookEvent": eventName,
            "toolName": toolName,
        ]
        if let cwd { metadata["cwd"] = cwd }
        if let toolUseID = string(object["tool_use_id"] ?? object["toolUseId"]) {
            metadata["toolUseID"] = String(toolUseID.prefix(128))
        }
        if let rawCommand {
            metadata["commandSHA256"] = SHA256.hash(data: Data(rawCommand.utf8)).map { String(format: "%02x", $0) }.joined()
            metadata["commandClass"] = classifiedCommand
        }

        let eventID = stableEventID(
            adapterID: adapterID,
            sessionID: sessionID,
            eventName: eventName,
            toolName: toolName,
            toolUseID: metadata["toolUseID"]
        )

        return BehaviorEvent(
            id: eventID ?? UUID(),
            timestamp: timestamp(object["timestamp"]),
            sessionID: sessionID.map { String($0.prefix(256)) },
            toolID: adapterID,
            type: type,
            target: target,
            evidence: .correlated,
            isRaw: false,
            metadata: metadata
        )
    }

    private static func behaviorType(eventName: String, toolName: String, command: String?) -> BehaviorType {
        let normalizedEvent = eventName.lowercased().replacingOccurrences(of: "_", with: "")
        if normalizedEvent.contains("readcode") { return .fileOpen }
        if normalizedEvent.contains("writecode") { return .fileWrite }
        if normalizedEvent.contains("mcptool") { return .networkConnect }
        guard normalizedEvent.contains("tool") || normalizedEvent.contains("runcommand") else { return .hookEvent }
        let tool = toolName.lowercased()
        if ["read", "view", "notebookread"].contains(tool) { return .fileOpen }
        if ["glob", "grep", "search", "list", "ls"].contains(tool) { return .directoryTraversal }
        if ["write", "create", "notebookedit"].contains(tool) { return .fileCreate }
        if ["edit", "multiedit", "apply_patch"].contains(tool) { return .fileWrite }
        if ["delete", "remove", "unlink"].contains(tool) { return .fileDelete }
        if ["move", "rename"].contains(tool) { return .fileRename }
        if tool.contains("web") || tool.contains("fetch") || tool.contains("http") { return .networkConnect }

        guard let command = command?.lowercased() else { return .hookEvent }
        if command.range(of: #"(^|\s)(zip|tar|7z|ditto)\s|\bgit\s+bundle\s+create\b"#, options: .regularExpression) != nil { return .archiveCreate }
        if isObjectStorageUpload(command) { return .networkUpload }
        if command.range(of: #"\baws\s+s3\s+(cp|sync|mv)\b|\bossutil\s+(cp|sync|mv)\b"#, options: .regularExpression) != nil { return .networkConnect }
        if command.range(of: #"(^|\s)(scp|sftp|rsync|rclone|nc|ncat|socat)\s|\bgit\s+push\b|\bgh\s+release\s+upload\b"#, options: .regularExpression) != nil { return .networkUpload }
        if command.range(of: #"\b(curl|wget)\b"#, options: .regularExpression) != nil {
            let uploadFlags = [" -t ", " --upload-file ", " --form ", " -d ", " --data ", " --data-binary ", " --json ", " --post-data ", " --post-file ", " --body-data ", " --body-file "]
            return uploadFlags.contains(where: { " \(command) ".contains($0) }) ? .networkUpload : .networkConnect
        }
        if command.range(of: #"\b(requests|httpx)\.(post|put|patch)\b|\baxios\.(post|put|patch)\b|\bfetch\s*\([^\n]*(method\s*:\s*['\"](post|put|patch))"#, options: .regularExpression) != nil { return .networkUpload }
        if command.range(of: #"(^|\s)(find|fd)\s|\brg\s+--files\b"#, options: .regularExpression) != nil { return .directoryTraversal }
        if command.range(of: #"(^|\s)(cat|sed|head|tail|less)\s"#, options: .regularExpression) != nil { return .fileOpen }
        return .hookEvent
    }

    private static func inferredToolName(_ eventName: String) -> String {
        let normalized = eventName.lowercased().replacingOccurrences(of: "_", with: "")
        if normalized.contains("readcode") { return "Read" }
        if normalized.contains("writecode") { return "Edit" }
        if normalized.contains("runcommand") { return "Bash" }
        if normalized.contains("mcptool") { return "MCP" }
        return ""
    }

    private static func commandClass(_ command: String) -> String {
        let lower = command.lowercased()
        if lower.range(of: #"\bgit\s+push\b"#, options: .regularExpression) != nil { return "git-push" }
        if isObjectStorageUpload(lower) { return "object-storage-upload" }
        return switch behaviorType(eventName: "PreToolUse", toolName: "Bash", command: command) {
        case .archiveCreate: "archive"
        case .networkUpload: "network-upload"
        case .directoryTraversal: "traversal"
        case .fileOpen: "file-read"
        default: "other-redacted"
        }
    }

    private static func objectStorageTarget(_ command: String) -> String? {
        if let range = command.range(
            of: #"\b(s3|gs|oss|cos)://[A-Za-z0-9._-]+"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            return String(command[range]).lowercased()
        }
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        if let index = tokens.firstIndex(of: "--bucket"), tokens.indices.contains(index + 1) {
            return "s3://\(tokens[index + 1].lowercased())"
        }
        return nil
    }

    private static func isObjectStorageUpload(_ command: String) -> Bool {
        let lower = command.lowercased()
        if lower.range(of: #"\baws\s+s3api\s+put-object\b"#, options: .regularExpression) != nil {
            return true
        }
        return lower.range(
            of: #"\b(?:aws\s+s3|ossutil)\s+(?:cp|sync|mv)\s+(?:--[^\s]+\s+)*[^\s]+\s+(?:s3|oss)://"#,
            options: .regularExpression
        ) != nil
    }

    private static func gitPushTarget(command: String, cwd: String?) -> String? {
        guard let pushRange = command.range(of: #"\bgit\s+push\b"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let arguments = command[pushRange.upperBound...]
            .split(whereSeparator: { $0.isWhitespace || ";|&".contains($0) })
            .map(String.init)
        let remoteArgument = arguments.first(where: { !$0.hasPrefix("-") })
        let remoteURL: String?
        if let remoteArgument, remoteArgument.contains(":") || remoteArgument.contains("@") {
            remoteURL = remoteArgument
        } else if let remoteArgument, remoteArgument.contains(".") && remoteArgument.contains("/") {
            remoteURL = remoteArgument
        } else {
            remoteURL = gitConfiguredRemote(named: remoteArgument, cwd: cwd)
        }
        guard let remoteURL, let identity = gitRemoteIdentity(remoteURL) else { return nil }
        let digest = SHA256.hash(data: Data(identity.fingerprintMaterial.utf8))
            .prefix(6).map { String(format: "%02x", $0) }.joined()
        return "git:\(identity.host)#\(digest)"
    }

    private static func gitConfiguredRemote(named requestedName: String?, cwd: String?) -> String? {
        guard let cwd, cwd.hasPrefix("/") else { return nil }
        var directory = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        for _ in 0..<10 {
            let config = directory.appendingPathComponent(".git/config")
            if let attributes = try? FileManager.default.attributesOfItem(atPath: config.path),
               let size = attributes[.size] as? NSNumber, size.intValue <= 256 * 1_024,
               let content = try? String(contentsOf: config, encoding: .utf8) {
                var remotes: [String: String] = [:]
                var currentRemote: String?
                for rawLine in content.split(whereSeparator: \.isNewline) {
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("[") {
                        currentRemote = nil
                        if line.hasPrefix("[remote \"") && line.hasSuffix("\"]") {
                            currentRemote = String(line.dropFirst(9).dropLast(2))
                        }
                    } else if let currentRemote,
                              let range = line.range(of: #"^url\s*="#, options: [.regularExpression, .caseInsensitive]) {
                        remotes[currentRemote] = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    }
                }
                if let requestedName { return remotes[requestedName] }
                return remotes.count == 1 ? remotes.values.first : nil
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return nil
    }

    private static func gitRemoteIdentity(_ remote: String) -> (host: String, fingerprintMaterial: String)? {
        if let components = URLComponents(string: remote),
           let scheme = components.scheme?.lowercased(), ["https", "http", "ssh", "git"].contains(scheme),
           let host = components.host?.lowercased(), !components.path.isEmpty {
            return (host, host + components.path)
        }
        if let at = remote.firstIndex(of: "@"),
           let colon = remote[at...].firstIndex(of: ":") {
            let host = String(remote[remote.index(after: at)..<colon]).lowercased()
            let path = String(remote[remote.index(after: colon)...])
            guard !host.isEmpty, !path.isEmpty else { return nil }
            return (host, host + "/" + path)
        }
        return nil
    }

    private static func firstPathOrHost(_ command: String, cwd: String?) -> String? {
        if let range = command.range(of: #"https?://[^\s'\"]+"#, options: .regularExpression),
           let host = URL(string: String(command[range]))?.host {
            return host
        }
        // Require a token boundary and retain the complete relative path. The
        // old expression started at any slash, so `app/src/main/...` became
        // `/src/main/...` and was then incorrectly classified as a root-level
        // path outside the workspace.
        let pattern = #"(?:^|[\s\"'=])((?:~/|/|\.\.?/|[A-Za-z0-9._-]+/)[^\s'\";|&)]*)"#
        guard let range = command.range(of: pattern, options: .regularExpression) else { return nil }
        let token = String(command[range])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'=,;)]}"))
        guard !token.isEmpty, !token.contains("*") else { return nil }
        return sanitizedTarget(token, cwd: cwd)
    }

    private static func sanitizedTarget(_ value: String?, cwd: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if let url = URL(string: value), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
            return url.host
        }
        if !value.hasPrefix("/"), !value.hasPrefix("~"), let cwd, cwd.hasPrefix("/") {
            return sanitizedPath(URL(fileURLWithPath: cwd).appendingPathComponent(value).standardizedFileURL.path)
        }
        return sanitizedPath(value)
    }

    private static func sanitizedPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let abbreviated = path == home ? "~" : path.replacingOccurrences(of: home + "/", with: "~/")
        return String(abbreviated.prefix(2_048))
    }

    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { string(dictionary[$0]) }.first
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func dictionary(_ value: Any?) -> [String: Any] {
        if let dictionary = value as? [String: Any] { return dictionary }
        if let string = value as? String,
           let data = string.data(using: .utf8),
           let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dictionary
        }
        return [:]
    }

    private static func timestamp(_ value: Any?) -> Date {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        if let string = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string) {
                return date
            }
            if let raw = Double(string) {
                return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
            }
        }
        return Date()
    }

    private static func stableEventID(
        adapterID: String,
        sessionID: String?,
        eventName: String,
        toolName: String,
        toolUseID: String?
    ) -> UUID? {
        guard let toolUseID, !toolUseID.isEmpty else { return nil }
        let material = [adapterID, sessionID ?? "", eventName, toolName, toolUseID].joined(separator: "\u{1f}")
        var bytes = Array(SHA256.hash(data: Data(material.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
