import Darwin
import Foundation
import HarnessSentryCore

/// Community fallback for terminal harnesses. It scans only every 10 seconds,
/// on a utility queue, and emits lifecycle transitions rather than snapshots.
final class CLIProcessSensor: @unchecked Sendable {
    private struct Snapshot: Equatable, Sendable {
        let path: String
        let adapterID: String
        let sessionID: String
    }

    private let queue = DispatchQueue(label: "app.harnesssentry.cli-process", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var known: [Int32: Snapshot] = [:]
    private var sink: (@Sendable (BehaviorEvent) -> Void)?

    func start(sink: @escaping @Sendable (BehaviorEvent) -> Void) {
        stop()
        self.sink = sink
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(10), leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.scan() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        known.removeAll()
        sink = nil
    }

    func updateScanInterval(_ seconds: TimeInterval) {
        let safeInterval = max(10, seconds)
        let interval = DispatchTimeInterval.milliseconds(Int(safeInterval * 1_000))
        queue.async { [weak self] in
            self?.timer?.schedule(
                deadline: .now() + interval,
                repeating: interval,
                leeway: .seconds(2)
            )
        }
    }

    private func scan() {
        var pids = [Int32](repeating: 0, count: 4_096)
        let bytes = Int32(pids.count * MemoryLayout<Int32>.size)
        let count = Int(proc_listallpids(&pids, bytes))
        guard count > 0 else { return }

        var current: [Int32: Snapshot] = [:]
        for pid in pids.prefix(min(count, pids.count)) where pid > 0 {
            guard let path = processPath(pid), !path.contains(".app/Contents/") else { continue }
            let executable = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            guard let adapter = BuiltInAdapters.all.first(where: {
                $0.executableNames.contains { $0.lowercased() == executable }
            }) else { continue }
            if let previous = known[pid], previous.path == path, previous.adapterID == adapter.id {
                current[pid] = previous
            } else {
                current[pid] = Snapshot(
                    path: path,
                    adapterID: adapter.id,
                    sessionID: "process-\(adapter.id)-\(UUID().uuidString.lowercased())"
                )
            }
        }

        for (pid, snapshot) in current {
            if let previous = known[pid], previous != snapshot {
                emit(pid: pid, snapshot: previous, type: .processExit)
                emit(pid: pid, snapshot: snapshot, type: .processLaunch)
            } else if known[pid] == nil {
                emit(pid: pid, snapshot: snapshot, type: .processLaunch)
            }
        }
        for (pid, snapshot) in known where current[pid] == nil {
            emit(pid: pid, snapshot: snapshot, type: .processExit)
        }
        known = current
    }

    private func processPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func emit(pid: Int32, snapshot: Snapshot, type: BehaviorType) {
        sink?(BehaviorEvent(
            sessionID: snapshot.sessionID,
            toolID: snapshot.adapterID,
            processID: pid,
            processPath: snapshot.path,
            type: type,
            evidence: .operatingSystem,
            metadata: ["source": "cli-process-scan", "intervalSeconds": "10"]
        ))
    }
}
