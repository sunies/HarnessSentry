import Foundation

public enum AdapterLevel: String, Codable, Sendable {
    case basic = "A1"
    case enhanced = "A2"
    case deepSession = "A3"
}

public struct HarnessAdapter: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let level: AdapterLevel
    public let executableNames: [String]
    public let bundleIdentifiers: [String]
    public let supportsHooks: Bool

    public init(
        id: String,
        displayName: String,
        level: AdapterLevel,
        executableNames: [String],
        bundleIdentifiers: [String] = [],
        supportsHooks: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.level = level
        self.executableNames = executableNames
        self.bundleIdentifiers = bundleIdentifiers
        self.supportsHooks = supportsHooks
    }
}

public enum BuiltInAdapters {
    public static let all: [HarnessAdapter] = [
        .init(id: "codex", displayName: "OpenAI Codex", level: .deepSession, executableNames: ["codex"], bundleIdentifiers: ["com.openai.codex"], supportsHooks: true),
        .init(id: "claude-code", displayName: "Claude Code", level: .deepSession, executableNames: ["claude"], supportsHooks: true),
        .init(id: "workbuddy", displayName: "WorkBuddy", level: .deepSession, executableNames: ["codebuddy", "cbc"], bundleIdentifiers: ["com.tencent.workbuddy.mac", "com.workbuddy.workbuddy"], supportsHooks: true),
        .init(id: "qoder", displayName: "Qoder", level: .deepSession, executableNames: ["qoder", "qoder-helper"], bundleIdentifiers: ["com.qoder.app"], supportsHooks: true),
        .init(id: "zcode", displayName: "ZCode", level: .deepSession, executableNames: ["zcode", "zcode-helper"], bundleIdentifiers: ["dev.zcode.app"], supportsHooks: true),
        .init(id: "cursor", displayName: "Cursor", level: .deepSession, executableNames: ["Cursor", "cursor", "cursor-agent"], bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"], supportsHooks: true),
        .init(id: "windsurf", displayName: "Windsurf", level: .deepSession, executableNames: ["Windsurf", "windsurf"], supportsHooks: true),
        .init(id: "copilot", displayName: "GitHub Copilot", level: .deepSession, executableNames: ["copilot", "copilot-language-server"], supportsHooks: true),
        .init(id: "gemini-cli", displayName: "Gemini CLI", level: .deepSession, executableNames: ["gemini"], supportsHooks: true),
        .init(id: "cline", displayName: "Cline", level: .deepSession, executableNames: ["cline"], supportsHooks: true),
        .init(id: "roo-code", displayName: "Roo Code", level: .enhanced, executableNames: ["roo-code"]),
        .init(id: "continue", displayName: "Continue", level: .deepSession, executableNames: ["continue"], supportsHooks: true),
        .init(id: "kiro", displayName: "Kiro", level: .deepSession, executableNames: ["kiro"]),
        .init(id: "trae", displayName: "TRAE", level: .deepSession, executableNames: ["trae"], supportsHooks: true),
        .init(id: "aider", displayName: "Aider", level: .basic, executableNames: ["aider"]),
        .init(id: "opencode", displayName: "OpenCode", level: .deepSession, executableNames: ["opencode"]),
        .init(id: "qwen-code", displayName: "Qwen Code", level: .deepSession, executableNames: ["qwen"], supportsHooks: true),
        .init(id: "kimi-cli", displayName: "Kimi Code CLI", level: .deepSession, executableNames: ["kimi"], supportsHooks: true),
        .init(id: "iflow-cli", displayName: "iFlow CLI", level: .deepSession, executableNames: ["iflow"], supportsHooks: true),
        .init(id: "goose", displayName: "Goose", level: .deepSession, executableNames: ["goose"], supportsHooks: true),
        .init(id: "deepseek-harness", displayName: "DeepSeek Harness", level: .basic, executableNames: ["dsh"]),
    ]
}
