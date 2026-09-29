import Foundation

public enum HookConfigurationStyle: Sendable, Equatable {
    case grouped
    case zcodeNested
    case cursorFlat
    case windsurfFlat
    case copilotFlat
}

public enum HookConfigurationBuilder {
    public static let supportedAdapterIDs = [
        "codex", "claude-code", "workbuddy", "qoder", "zcode", "cursor", "windsurf",
        "copilot", "gemini-cli", "qwen-code", "continue", "iflow-cli", "goose", "trae",
    ]

    public static func style(for adapterID: String) -> HookConfigurationStyle {
        switch adapterID {
        case "zcode": .zcodeNested
        case "cursor": .cursorFlat
        case "windsurf": .windsurfFlat
        case "copilot": .copilotFlat
        default: .grouped
        }
    }

    public static func data(executablePath: String, adapterID: String) throws -> Data {
        let configuration: [String: Any]
        switch style(for: adapterID) {
        case .grouped:
            configuration = groupedConfiguration(executablePath: executablePath, adapterID: adapterID)
        case .zcodeNested:
            let grouped = groupedConfiguration(executablePath: executablePath, adapterID: adapterID)
            configuration = [
                "hooks": [
                    "enabled": true,
                    "timeoutMs": 5_000,
                    "maxOutputBytes": 1_024,
                    "events": grouped["hooks"] as? [String: Any] ?? [:],
                ]
            ]
        case .cursorFlat:
            configuration = cursorConfiguration(executablePath: executablePath, adapterID: adapterID)
        case .windsurfFlat:
            configuration = windsurfConfiguration(executablePath: executablePath, adapterID: adapterID)
        case .copilotFlat:
            configuration = copilotConfiguration(executablePath: executablePath, adapterID: adapterID)
        }
        return try JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys])
    }

    public static func kiroProjectData(executablePath: String) throws -> Data {
        let events = ["SessionStart", "AgentSpawn", "PostToolUse", "Stop"]
        let hooks: [[String: Any]] = events.map { event in
            [
                "name": "HarnessSentry \(event)",
                "description": "Send redacted Kiro behavior metadata to the local HarnessSentry database",
                "trigger": event,
                "matcher": event == "PostToolUse" ? "*" : "",
                "action": [
                    "type": "command",
                    "command": shellCommand(executablePath: executablePath, adapterID: "kiro", event: event),
                ],
                "timeout": 5,
                "enabled": true,
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: ["version": "v1", "hooks": hooks],
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func groupedConfiguration(executablePath: String, adapterID: String) -> [String: Any] {
        let events: [(String, String?)] = adapterID == "gemini-cli"
            ? [("SessionStart", nil), ("AfterTool", "*"), ("SessionEnd", nil)]
            : [("SessionStart", nil), ("PostToolUse", "*"), ("PostToolUseFailure", "*"), ("Stop", nil)]
        var hooks: [String: Any] = [:]
        for (event, matcher) in events {
            var handler: [String: Any] = [
                "type": "command",
                "command": shellCommand(executablePath: executablePath, adapterID: adapterID, event: event),
                "timeout": adapterID == "gemini-cli" ? 5_000 : 5,
            ]
            if !["gemini-cli", "iflow-cli", "goose", "trae"].contains(adapterID) {
                handler["async"] = true
            }
            var group: [String: Any] = ["hooks": [handler]]
            if let matcher {
                group["matcher"] = adapterID == "goose" ? ".*" : matcher
            }
            if adapterID == "qoder" { group["async"] = true }
            hooks[event] = [group]
        }
        if adapterID == "trae" {
            return ["version": 1, "hooks": hooks]
        }
        return ["hooks": hooks]
    }

    private static func cursorConfiguration(executablePath: String, adapterID: String) -> [String: Any] {
        let events = [
            ("sessionStart", "SessionStart"),
            ("postToolUse", "PostToolUse"),
            ("postToolUseFailure", "PostToolUseFailure"),
            ("stop", "Stop"),
        ]
        var hooks: [String: Any] = [:]
        for (event, normalizedEvent) in events {
            hooks[event] = [["command": shellCommand(
                executablePath: executablePath,
                adapterID: adapterID,
                event: normalizedEvent
            )]]
        }
        return ["version": 1, "hooks": hooks]
    }

    private static func copilotConfiguration(executablePath: String, adapterID: String) -> [String: Any] {
        let events = ["SessionStart", "PostToolUse", "PostToolUseFailure", "Stop"]
        var hooks: [String: Any] = [:]
        for event in events {
            hooks[event] = [[
                "type": "command",
                "exec": executablePath,
                "args": ["--adapter", adapterID, "--event", event],
                "timeoutSec": 5,
            ]]
        }
        return ["version": 1, "hooks": hooks]
    }

    private static func windsurfConfiguration(executablePath: String, adapterID: String) -> [String: Any] {
        let events = ["post_read_code", "post_write_code", "post_run_command", "post_mcp_tool_use"]
        var hooks: [String: Any] = [:]
        for event in events {
            hooks[event] = [[
                "command": shellCommand(executablePath: executablePath, adapterID: adapterID, event: event),
                "show_output": false,
            ]]
        }
        return ["hooks": hooks]
    }

    private static func shellCommand(executablePath: String, adapterID: String, event: String) -> String {
        "\(shellQuote(executablePath)) --adapter \(shellQuote(adapterID)) --event \(shellQuote(event))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
