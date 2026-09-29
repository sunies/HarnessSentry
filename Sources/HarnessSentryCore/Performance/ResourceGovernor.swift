import Foundation

/// Minute-level resource values supplied by the app's sampler. The governor does
/// not sample on its own, keeping the decision deterministic and cheap to test.
public struct ResourceHealthSnapshot: Sendable, Equatable {
    public let cpuAveragePercent: Double
    public let residentMemoryBytes: Int64
    public let databaseBytes: Int64
    public let databaseLimitBytes: Int64

    public init(
        cpuAveragePercent: Double,
        residentMemoryBytes: Int64,
        databaseBytes: Int64,
        databaseLimitBytes: Int64
    ) {
        self.cpuAveragePercent = max(0, cpuAveragePercent)
        self.residentMemoryBytes = max(0, residentMemoryBytes)
        self.databaseBytes = max(0, databaseBytes)
        self.databaseLimitBytes = max(0, databaseLimitBytes)
    }

    public var databaseUtilization: Double {
        guard databaseLimitBytes > 0 else { return 0 }
        return Double(databaseBytes) / Double(databaseLimitBytes)
    }
}

public enum ResourceGovernorState: String, Sendable, Equatable {
    case normal
    case throttled
}

public enum ResourcePressureReason: String, Sendable, Equatable, CaseIterable {
    case cpu
    case memory
    case database
}

public struct ResourceGovernorDecision: Sendable, Equatable {
    public let state: ResourceGovernorState
    public let recommendedCLIScanInterval: TimeInterval
    public let reasons: [ResourcePressureReason]

    public init(
        state: ResourceGovernorState,
        recommendedCLIScanInterval: TimeInterval,
        reasons: [ResourcePressureReason]
    ) {
        self.state = state
        self.recommendedCLIScanInterval = recommendedCLIScanInterval
        self.reasons = reasons
    }
}

public struct ResourceGovernorPolicy: Sendable, Equatable {
    public var cpuThrottlePercent: Double
    public var cpuCriticalPercent: Double
    public var memoryThrottleBytes: Int64
    public var memoryCriticalBytes: Int64
    public var databaseThrottleRatio: Double
    public var databaseCriticalRatio: Double
    public var normalScanInterval: TimeInterval
    public var throttledScanInterval: TimeInterval
    public var criticalScanInterval: TimeInterval

    public init(
        cpuThrottlePercent: Double = 1.5,
        cpuCriticalPercent: Double = 5,
        memoryThrottleBytes: Int64 = 100 * 1_024 * 1_024,
        memoryCriticalBytes: Int64 = 150 * 1_024 * 1_024,
        databaseThrottleRatio: Double = 0.8,
        databaseCriticalRatio: Double = 0.95,
        normalScanInterval: TimeInterval = 10,
        throttledScanInterval: TimeInterval = 30,
        criticalScanInterval: TimeInterval = 60
    ) {
        self.cpuThrottlePercent = cpuThrottlePercent
        self.cpuCriticalPercent = cpuCriticalPercent
        self.memoryThrottleBytes = memoryThrottleBytes
        self.memoryCriticalBytes = memoryCriticalBytes
        self.databaseThrottleRatio = databaseThrottleRatio
        self.databaseCriticalRatio = databaseCriticalRatio
        self.normalScanInterval = normalScanInterval
        self.throttledScanInterval = throttledScanInterval
        self.criticalScanInterval = criticalScanInterval
    }

    public static let `default` = ResourceGovernorPolicy()
}

public enum ResourceGovernor {
    /// Evaluates already-aggregated values. No I/O, timers, process inspection or
    /// shared state is involved, so this can safely run on any executor.
    public static func evaluate(
        _ snapshot: ResourceHealthSnapshot,
        policy: ResourceGovernorPolicy = .default
    ) -> ResourceGovernorDecision {
        var reasons: [ResourcePressureReason] = []
        if snapshot.cpuAveragePercent >= policy.cpuThrottlePercent { reasons.append(.cpu) }
        if snapshot.residentMemoryBytes >= policy.memoryThrottleBytes { reasons.append(.memory) }
        if snapshot.databaseUtilization >= policy.databaseThrottleRatio { reasons.append(.database) }

        guard !reasons.isEmpty else {
            return ResourceGovernorDecision(
                state: .normal,
                recommendedCLIScanInterval: policy.normalScanInterval,
                reasons: []
            )
        }

        let hasCriticalPressure =
            snapshot.cpuAveragePercent >= policy.cpuCriticalPercent ||
            snapshot.residentMemoryBytes >= policy.memoryCriticalBytes ||
            snapshot.databaseUtilization >= policy.databaseCriticalRatio
        return ResourceGovernorDecision(
            state: .throttled,
            recommendedCLIScanInterval: hasCriticalPressure
                ? policy.criticalScanInterval
                : policy.throttledScanInterval,
            reasons: reasons
        )
    }
}
