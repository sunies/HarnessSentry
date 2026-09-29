import Foundation

/// Converts WorkBuddy's append-only command-safety audit records without
/// retaining command previews or message parameters.
public enum WorkBuddyAuditEventNormalizer {
    public static func normalize(data: Data) throws -> BehaviorEvent {
        guard data.count <= HookEventNormalizer.maximumInputBytes,
              let record = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw HookNormalizationError.invalidJSON }

        let command = (record["commandPreview"] as? String)
            ?? ((record["messageParams"] as? [String: Any])?["command"] as? String)
        var input: [String: Any] = [:]
        if let command { input["command"] = command }
        var synthetic: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_input": input,
        ]
        for (sourceKey, targetKey) in [
            ("sessionId", "session_id"),
            ("toolCallId", "tool_use_id"),
            ("timestamp", "timestamp"),
        ] {
            if let value = record[sourceKey] { synthetic[targetKey] = value }
        }
        let payload = try JSONSerialization.data(withJSONObject: synthetic)
        return try HookEventNormalizer.normalize(
            data: payload,
            adapterID: "workbuddy",
            eventNameOverride: "PostToolUse",
            source: "workbuddy-audit"
        )
    }
}
