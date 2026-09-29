import Foundation
import HarnessSentryCore

/// Low-overhead A3 bridge for WorkBuddy's append-only command audit log.
/// It starts at EOF and normalizes only new records in memory.
final class WorkBuddyAuditSensor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.harnesssentry.workbuddy-audit", qos: .utility)
    private let directory: URL
    private var timer: DispatchSourceTimer?
    private var sink: (@Sendable (BehaviorEvent) -> Void)?
    private var currentFile: URL?
    private var offset: UInt64 = 0
    private var carry = Data()

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        directory = homeDirectory.appendingPathComponent(".workbuddy/audit-log", isDirectory: true)
    }

    func start(sink: @escaping @Sendable (BehaviorEvent) -> Void) {
        stop()
        self.sink = sink
        let file = auditFile(for: Date())
        currentFile = file
        offset = fileSize(file) ?? 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(15), leeway: .seconds(3))
        timer.setEventHandler { [weak self] in self?.scan() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        sink = nil
        currentFile = nil
        offset = 0
        carry.removeAll(keepingCapacity: false)
    }

    private func scan() {
        let file = auditFile(for: Date())
        if currentFile != file {
            currentFile = file
            offset = 0
            carry.removeAll(keepingCapacity: true)
        }
        guard let size = fileSize(file), size > 0 else { return }
        if size < offset {
            offset = 0
            carry.removeAll(keepingCapacity: true)
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let requested = min(512 * 1_024, Int(size - offset))
            guard let data = try handle.read(upToCount: requested), !data.isEmpty else { return }
            offset += UInt64(data.count)
            carry.append(data)
            consumeCompleteLines()
            if carry.count > HookEventNormalizer.maximumInputBytes {
                carry.removeAll(keepingCapacity: false)
            }
        } catch {
            return
        }
    }

    private func consumeCompleteLines() {
        while let index = carry.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(carry[..<index])
            carry.removeSubrange(...index)
            guard !line.isEmpty,
                  let event = try? WorkBuddyAuditEventNormalizer.normalize(data: line)
            else { continue }
            sink?(event)
        }
    }

    private func auditFile(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return directory.appendingPathComponent(formatter.string(from: date) + ".jsonl")
    }

    private func fileSize(_ url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber
        else { return nil }
        return number.uint64Value
    }
}
