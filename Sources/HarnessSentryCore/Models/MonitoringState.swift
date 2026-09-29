import Foundation

/// Cross-process monitoring control shared by the menu-bar app and hook
/// executables through the SQLite store.
public struct MonitoringState: Codable, Equatable, Sendable {
    public let isPaused: Bool
    public let updatedAt: Date
    public let source: String?

    public init(isPaused: Bool, updatedAt: Date = Date(), source: String? = nil) {
        self.isPaused = isPaused
        self.updatedAt = updatedAt
        self.source = source
    }
}
