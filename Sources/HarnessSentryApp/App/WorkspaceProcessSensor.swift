import AppKit
import HarnessSentryCore

/// Low-overhead Community sensor for GUI Harness lifecycle events.
/// It is notification-driven and never polls the process table.
@MainActor
final class WorkspaceProcessSensor {
    private var observers: [NSObjectProtocol] = []
    private var sink: ((BehaviorEvent) -> Void)?
    private var sessionIDsByProcessID: [Int32: String] = [:]

    func start(sink: @escaping (BehaviorEvent) -> Void) {
        stop()
        self.sink = sink

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let snapshot = Self.snapshot(from: notification) else { return }
            Task { @MainActor [weak self] in
                self?.emit(snapshot, type: .processLaunch, phase: "notification")
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let snapshot = Self.snapshot(from: notification) else { return }
            Task { @MainActor [weak self] in
                self?.emit(snapshot, type: .processExit, phase: "notification")
            }
        })

        for application in NSWorkspace.shared.runningApplications {
            emit(Self.snapshot(from: application), type: .processLaunch, phase: "already-running")
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        sessionIDsByProcessID.removeAll()
        sink = nil
    }

    nonisolated private static func snapshot(from notification: Notification) -> RunningApplicationSnapshot? {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return nil }
        return snapshot(from: application)
    }

    nonisolated private static func snapshot(from application: NSRunningApplication) -> RunningApplicationSnapshot {
        RunningApplicationSnapshot(
            processIdentifier: application.processIdentifier,
            executablePath: application.executableURL?.path,
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName
        )
    }

    private func emit(_ application: RunningApplicationSnapshot, type: BehaviorType, phase: String) {
        guard let adapter = match(application) else { return }
        let sessionID: String
        if type == .processExit {
            sessionID = sessionIDsByProcessID.removeValue(forKey: application.processIdentifier)
                ?? "process-\(adapter.id)-\(UUID().uuidString.lowercased())"
        } else if let existing = sessionIDsByProcessID[application.processIdentifier] {
            sessionID = existing
        } else {
            sessionID = "process-\(adapter.id)-\(UUID().uuidString.lowercased())"
            sessionIDsByProcessID[application.processIdentifier] = sessionID
        }
        sink?(BehaviorEvent(
            sessionID: sessionID,
            toolID: adapter.id,
            processID: application.processIdentifier,
            processPath: application.executablePath,
            type: type,
            target: application.bundleIdentifier,
            evidence: .operatingSystem,
            metadata: [
                "adapterLevel": adapter.level.rawValue,
                "phase": phase,
                "localizedName": application.localizedName ?? "",
            ]
        ))
    }

    private func match(_ application: RunningApplicationSnapshot) -> HarnessAdapter? {
        let bundleID = application.bundleIdentifier?.lowercased()
        let executable = application.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }
        let localizedName = application.localizedName?.lowercased()

        return BuiltInAdapters.all.first { adapter in
            adapter.bundleIdentifiers.map { $0.lowercased() }.contains(where: { $0 == bundleID }) ||
            adapter.executableNames.map { $0.lowercased() }.contains(where: { $0 == executable }) ||
            adapter.displayName.lowercased() == localizedName
        }
    }
}

private struct RunningApplicationSnapshot: Sendable {
    let processIdentifier: Int32
    let executablePath: String?
    let bundleIdentifier: String?
    let localizedName: String?
}
