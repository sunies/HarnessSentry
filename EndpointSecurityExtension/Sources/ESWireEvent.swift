import Foundation

/// Privacy-minimized transport object. It deliberately has no fields for file
/// contents, prompts, command arguments, environment variables, or network body.
struct ESWireEvent: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case processExec = "process_exec"
        case processFork = "process_fork"
        case processExit = "process_exit"
        case fileOpen = "file_open"
        case fileClose = "file_close"
        case fileWrite = "file_write"
        case fileDelete = "file_delete"
        case fileTruncate = "file_truncate"
    }

    let schemaVersion: Int
    let unixNanoseconds: UInt64
    let kind: Kind
    let processID: Int32
    let processVersion: Int32
    let processPath: String
    let signingIdentifier: String?
    let teamIdentifier: String?
    let targetPath: String?
    let openFlags: Int32?
    let modified: Bool?
    let sequence: UInt64?
    let globalSequence: UInt64?
    let messageVersion: UInt32

    init(
        unixNanoseconds: UInt64,
        kind: Kind,
        processID: Int32,
        processVersion: Int32,
        processPath: String,
        signingIdentifier: String?,
        teamIdentifier: String?,
        targetPath: String? = nil,
        openFlags: Int32? = nil,
        modified: Bool? = nil,
        sequence: UInt64? = nil,
        globalSequence: UInt64? = nil,
        messageVersion: UInt32
    ) {
        self.schemaVersion = 1
        self.unixNanoseconds = unixNanoseconds
        self.kind = kind
        self.processID = processID
        self.processVersion = processVersion
        self.processPath = processPath
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.targetPath = targetPath
        self.openFlags = openFlags
        self.modified = modified
        self.sequence = sequence
        self.globalSequence = globalSequence
        self.messageVersion = messageVersion
    }
}

enum PathSanitizer {
    /// Removes the local account name while preserving enough path structure
    /// for the app's sensitive-path and archive rules.
    static func sanitize(_ rawPath: String) -> String {
        let path = String(rawPath.prefix(2_048))
        guard path.hasPrefix("/Users/") else { return path }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 4 else { return "~/" }
        return "~/" + components.dropFirst(3).joined(separator: "/")
    }
}
