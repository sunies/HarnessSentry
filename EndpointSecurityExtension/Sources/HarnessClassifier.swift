import Foundation

enum HarnessClassifier {
    /// Exact executable basenames and stable signing identifiers only. Avoid
    /// substring matching: a random process named `my-codex-backup` must not
    /// become privileged evidence just because it contains a harness name.
    private static let executableNames: Set<String> = [
        "amp", "aider", "claude", "cline", "codex", "continue",
        "cursor", "gemini", "goose", "kiro", "opencode", "qoder",
        "roo", "roo-code", "trae", "windsurf", "zcode"
    ]

    private static let signingIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.todesktop.230313mzl4w4u92",
        "com.todesktop.230313mzl4w4u92.helper",
        "com.qoder.Qoder"
    ]

    static func isHarness(executablePath: String, signingIdentifier: String?) -> Bool {
        if executableNames.contains(URL(fileURLWithPath: executablePath).lastPathComponent.lowercased()) {
            return true
        }
        if let signingIdentifier,
           signingIdentifiers.contains(signingIdentifier) {
            return true
        }
        return false
    }
}
