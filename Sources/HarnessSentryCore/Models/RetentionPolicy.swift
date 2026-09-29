import Foundation

public struct RetentionPolicy: Codable, Equatable, Sendable {
    public var rawEventHours: Int
    public var behaviorDays: Int
    public var incidentDays: Int
    public var maximumDatabaseBytes: Int64

    public static let `default` = RetentionPolicy(
        rawEventHours: 24,
        behaviorDays: 2,
        incidentDays: 30,
        maximumDatabaseBytes: 200 * 1_024 * 1_024
    )

    public init(
        rawEventHours: Int,
        behaviorDays: Int,
        incidentDays: Int,
        maximumDatabaseBytes: Int64
    ) {
        self.rawEventHours = max(1, rawEventHours)
        self.behaviorDays = max(1, behaviorDays)
        self.incidentDays = max(1, incidentDays)
        self.maximumDatabaseBytes = max(10 * 1_024 * 1_024, maximumDatabaseBytes)
    }

    public var cleanupThresholdBytes: Int64 {
        Int64(Double(maximumDatabaseBytes) * 0.8)
    }
}
