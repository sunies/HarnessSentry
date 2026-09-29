import Foundation

/// Converts Apple's JSON-lines `eslogger` output into the small, redacted
/// event model used by HarnessSentry. This is intentionally a lab bridge:
/// `eslogger` is useful for reproductions, but Apple does not provide schema
/// or performance stability guarantees for application use.
public enum EsloggerEventNormalizer {
    public enum NormalizationError: Error {
        case invalidObject
        case unsupportedEvent
    }

    private static let supportedTypes: [String: BehaviorType] = [
        "open": .fileOpen,
        "readdir": .directoryTraversal,
        "create": .fileCreate,
        "write": .fileWrite,
        "close": .fileWrite,
        "rename": .fileRename,
        "unlink": .fileDelete,
        "exec": .processLaunch,
    ]

    public static func normalize(
        data: Data,
        toolID: String,
        workspacePath: String?,
        sessionPrefix: String = "zcode-lab"
    ) throws -> [BehaviorEvent] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventContainer = root["event"] as? [String: Any]
        else { throw NormalizationError.invalidObject }

        guard let eventName = supportedTypes.keys.first(where: { eventContainer[$0] != nil }),
              let baseBehaviorType = supportedTypes[eventName],
              let payload = eventContainer[eventName]
        else { throw NormalizationError.unsupportedEvent }
        if eventName == "close",
           let close = payload as? [String: Any],
           close["modified"] as? Bool == false {
            throw NormalizationError.unsupportedEvent
        }

        let process = root["process"] as? [String: Any]
        let processPath = string(at: ["executable", "path"], in: process)
        let processID = integer(at: ["audit_token", "pid"], in: process).map(Int32.init)
        let timestamp = parseTimestamp(root["time"]) ?? parseTimestamp(root["timestamp"]) ?? Date()
        let workspace = workspacePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let sessionID = "\(sessionPrefix)-\(processID.map(String.init) ?? "unknown")"

        var targets = Set<String>()
        collectPaths(from: payload, into: &targets)
        collectConstructedPaths(from: payload, into: &targets)

        if eventName == "exec", let executable = string(at: ["target", "executable", "path"], in: payload as? [String: Any]) {
            targets = [executable]
        }
        let leafTargets = targets.filter { candidate in
            !targets.contains { other in other != candidate && other.hasPrefix(candidate + "/") }
        }

        return leafTargets.compactMap { rawTarget in
            guard rawTarget.hasPrefix("/") else { return nil }
            let target = canonicalTarget(rawTarget)
            var behaviorType = baseBehaviorType
            if isArchivePath(target), [.fileCreate, .fileWrite, .fileRename].contains(behaviorType) {
                behaviorType = .archiveCreate
            }
            var metadata = [
                "source": "eslogger-lab",
                "eventName": eventName,
                "schemaVersion": String(describing: root["schema_version"] ?? "unknown"),
                "lab": "true",
            ]
            if let workspace { metadata["cwd"] = workspace }
            return BehaviorEvent(
                timestamp: timestamp,
                sessionID: sessionID,
                toolID: toolID,
                processID: processID,
                processPath: processPath,
                type: behaviorType,
                target: target,
                evidence: .operatingSystem,
                isRaw: true,
                metadata: metadata
            )
        }
    }

    public static func isHighSignal(_ event: BehaviorEvent, workspacePath: String?) -> Bool {
        guard let target = event.target?.lowercased() else { return event.type == .processLaunch }
        if target.contains("/.git/objects") || target.contains("/.zcode/v2/checkpoints") { return true }
        if event.type == .archiveCreate { return true }
        guard let workspacePath else { return false }
        let workspace = URL(fileURLWithPath: workspacePath).standardizedFileURL.path.lowercased()
        return target == workspace || target.hasPrefix(workspace + "/")
    }

    private static func collectPaths(from value: Any, into paths: inout Set<String>) {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if key == "path", let path = child as? String { paths.insert(path) }
                collectPaths(from: child, into: &paths)
            }
        } else if let array = value as? [Any] {
            for child in array { collectPaths(from: child, into: &paths) }
        }
    }

    private static func collectConstructedPaths(from value: Any, into paths: inout Set<String>) {
        if let dictionary = value as? [String: Any] {
            if let newPath = dictionary["new_path"] as? [String: Any],
               let directory = string(at: ["dir", "path"], in: newPath),
               let filename = newPath["filename"] as? String {
                paths.insert(URL(fileURLWithPath: directory).appendingPathComponent(filename).path)
            }
            for child in dictionary.values { collectConstructedPaths(from: child, into: &paths) }
        } else if let array = value as? [Any] {
            for child in array { collectConstructedPaths(from: child, into: &paths) }
        }
    }

    private static func canonicalTarget(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let range = standardized.lowercased().range(of: "/.git/objects") {
            return String(standardized[..<range.upperBound])
        }
        return standardized
    }

    private static func isArchivePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return [".enc", ".tar", ".tgz", ".tar.gz", ".zip", ".gz", ".7z"].contains {
            lower.hasSuffix($0)
        }
    }

    private static func string(at keyPath: [String], in dictionary: [String: Any]?) -> String? {
        var value: Any? = dictionary
        for key in keyPath { value = (value as? [String: Any])?[key] }
        return value as? String
    }

    private static func integer(at keyPath: [String], in dictionary: [String: Any]?) -> Int? {
        var value: Any? = dictionary
        for key in keyPath { value = (value as? [String: Any])?[key] }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
