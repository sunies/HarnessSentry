import Foundation
import HarnessSentryCore

/// Developer-only synthetic replay. It is intentionally never wired into app
/// startup and `start` is a no-op unless the caller explicitly passes `true`.
@MainActor
final class DeveloperMockSensor {
    static let isEnabledByDefault = false

    private var replayTask: Task<Void, Never>?

    func start(
        enabled: Bool = false,
        replayInterval: Duration = .milliseconds(250),
        sink: @escaping @Sendable (BehaviorEvent) -> Void
    ) {
        stop()
        guard enabled else { return }

        let events = Self.makeTypicalEventChain()
        replayTask = Task {
            for event in events {
                guard !Task.isCancelled else { return }
                sink(event)
                try? await Task.sleep(for: replayInterval)
            }
        }
    }

    func stop() {
        replayTask?.cancel()
        replayTask = nil
    }

    /// Produces an entirely synthetic sequence without touching the filesystem or
    /// network. Targets use reserved example paths/domains and must never be
    /// interpreted as observations of real user data.
    static func makeTypicalEventChain(
        startingAt start: Date = Date(),
        toolID: String = "qoder",
        sessionID suppliedSessionID: String? = nil
    ) -> [BehaviorEvent] {
        let sessionID = suppliedSessionID ?? "mock-\(UUID().uuidString.lowercased())"
        let commonMetadata = [
            "mock": "true",
            "source": "developer-mock",
            "scenario": "sensitive-archive-non-model-upload-gap",
            "modelInteraction": "false",
        ]

        return [
            BehaviorEvent(
                timestamp: start,
                sessionID: sessionID,
                toolID: toolID,
                processID: 42_424,
                processPath: "/Applications/ExampleHarness.app/Contents/MacOS/example-harness",
                type: .fileOpen,
                target: "/Users/example/.ssh/id_ed25519",
                byteCount: 2_640,
                evidence: .correlated,
                metadata: commonMetadata.merging(["stage": "sensitive-path-read"]) { _, new in new }
            ),
            BehaviorEvent(
                timestamp: start.addingTimeInterval(1.2),
                sessionID: sessionID,
                toolID: toolID,
                processID: 42_424,
                processPath: "/Applications/ExampleHarness.app/Contents/MacOS/example-harness",
                type: .archiveCreate,
                target: "/private/tmp/harness-sentry-mock/workspace-source.zip",
                byteCount: 286 * 1_024 * 1_024,
                evidence: .correlated,
                metadata: commonMetadata.merging(["stage": "archive-create"]) { _, new in new }
            ),
            BehaviorEvent(
                timestamp: start.addingTimeInterval(3.8),
                sessionID: sessionID,
                toolID: toolID,
                processID: 42_424,
                processPath: "/Applications/ExampleHarness.app/Contents/MacOS/example-harness",
                type: .networkUpload,
                target: "https://collector.example.invalid/v1/upload",
                byteCount: 281 * 1_024 * 1_024,
                evidence: .operatingSystemAndNetwork,
                metadata: commonMetadata.merging([
                    "stage": "non-model-upload",
                    "destinationClass": "non-model",
                ]) { _, new in new }
            ),
            BehaviorEvent(
                timestamp: start.addingTimeInterval(5),
                sessionID: sessionID,
                toolID: toolID,
                processID: 42_424,
                processPath: "/Applications/ExampleHarness.app/Contents/MacOS/example-harness",
                type: .monitorGap,
                target: "developer-mock replay gap",
                evidence: .inferred,
                metadata: commonMetadata.merging([
                    "stage": "monitor-gap",
                    "gapReason": "synthetic-resource-throttle",
                ]) { _, new in new }
            ),
        ]
    }

    deinit {
        replayTask?.cancel()
    }
}
