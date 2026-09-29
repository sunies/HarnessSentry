import Foundation

public enum SensorState: Equatable, Sendable {
    case stopped
    case running
    case degraded(reason: String)
    case unavailable(reason: String)
}

public protocol EventSensor: Sendable {
    var id: String { get }
    func start(sink: @escaping @Sendable (BehaviorEvent) -> Void) async throws
    func stop() async
}

public actor ReplaySensor: EventSensor {
    public nonisolated let id = "replay"

    private let events: [BehaviorEvent]
    private let interval: Duration
    private var replayTask: Task<Void, Never>?

    public init(events: [BehaviorEvent], interval: Duration = .milliseconds(150)) {
        self.events = events
        self.interval = interval
    }

    public func start(sink: @escaping @Sendable (BehaviorEvent) -> Void) async throws {
        replayTask?.cancel()
        let events = self.events
        let interval = self.interval
        replayTask = Task {
            for event in events {
                guard !Task.isCancelled else { return }
                sink(event)
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() async {
        replayTask?.cancel()
        replayTask = nil
    }
}
