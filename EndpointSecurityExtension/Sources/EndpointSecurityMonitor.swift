import Dispatch
import EndpointSecurity
import Foundation

/// A notify-only ES monitor. It never authorizes, denies, delays, or rewrites a
/// monitored operation.
///
/// Two clients keep the hot path small:
/// - discovery receives only exec/fork/exit and identifies harness trees;
/// - activity uses inverted process muting, so file events are delivered only
///   for processes explicitly selected by discovery.
final class EndpointSecurityMonitor: @unchecked Sendable {
    typealias Sink = @Sendable (ESWireEvent) -> Void

    enum StartError: Error {
        case cannotCreateActivityClient(es_new_client_result_t)
        case cannotInvertActivityFilter(es_return_t)
        case cannotSubscribeActivity(es_return_t)
        case cannotCreateDiscoveryClient(es_new_client_result_t)
        case cannotSubscribeDiscovery(es_return_t)
    }

    private struct ProcessKey: Hashable {
        let pid: Int32
        let version: Int32
    }

    private let sink: Sink
    private let stateLock = NSLock()
    private var trackedProcesses = Set<ProcessKey>()
    private var activityClient: OpaquePointer?
    private var discoveryClient: OpaquePointer?

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    func start() throws {
        var newActivityClient: OpaquePointer?
        let activityResult = es_new_client(&newActivityClient) { [weak self] _, message in
            self?.handleActivity(message)
        }
        guard activityResult == ES_NEW_CLIENT_RESULT_SUCCESS,
              let newActivityClient else {
            throw StartError.cannotCreateActivityClient(activityResult)
        }

        // With inversion enabled, only audit tokens added through
        // es_mute_process vote "deliver". All other processes are suppressed.
        let invertResult = es_invert_muting(newActivityClient, ES_MUTE_INVERSION_TYPE_PROCESS)
        guard invertResult == ES_RETURN_SUCCESS else {
            es_delete_client(newActivityClient)
            throw StartError.cannotInvertActivityFilter(invertResult)
        }

        let activityEvents: [es_event_type_t] = [
            ES_EVENT_TYPE_NOTIFY_OPEN,
            ES_EVENT_TYPE_NOTIFY_CLOSE,
            ES_EVENT_TYPE_NOTIFY_WRITE,
            ES_EVENT_TYPE_NOTIFY_UNLINK,
            ES_EVENT_TYPE_NOTIFY_TRUNCATE,
        ]
        let activitySubscribeResult = subscribe(newActivityClient, to: activityEvents)
        guard activitySubscribeResult == ES_RETURN_SUCCESS else {
            es_delete_client(newActivityClient)
            throw StartError.cannotSubscribeActivity(activitySubscribeResult)
        }

        stateLock.withLock {
            activityClient = newActivityClient
        }

        var newDiscoveryClient: OpaquePointer?
        let discoveryResult = es_new_client(&newDiscoveryClient) { [weak self] _, message in
            self?.handleDiscovery(message)
        }
        guard discoveryResult == ES_NEW_CLIENT_RESULT_SUCCESS,
              let newDiscoveryClient else {
            es_delete_client(newActivityClient)
            stateLock.withLock { activityClient = nil }
            throw StartError.cannotCreateDiscoveryClient(discoveryResult)
        }

        let discoveryEvents: [es_event_type_t] = [
            ES_EVENT_TYPE_NOTIFY_EXEC,
            ES_EVENT_TYPE_NOTIFY_FORK,
            ES_EVENT_TYPE_NOTIFY_EXIT,
        ]
        let discoverySubscribeResult = subscribe(newDiscoveryClient, to: discoveryEvents)
        guard discoverySubscribeResult == ES_RETURN_SUCCESS else {
            es_delete_client(newDiscoveryClient)
            es_delete_client(newActivityClient)
            stateLock.withLock { activityClient = nil }
            throw StartError.cannotSubscribeDiscovery(discoverySubscribeResult)
        }

        stateLock.withLock {
            discoveryClient = newDiscoveryClient
        }
    }

    func stop() {
        let clients = stateLock.withLock { () -> (OpaquePointer?, OpaquePointer?) in
            let value = (discoveryClient, activityClient)
            discoveryClient = nil
            activityClient = nil
            trackedProcesses.removeAll(keepingCapacity: false)
            return value
        }

        if let discovery = clients.0 {
            es_unsubscribe_all(discovery)
            es_delete_client(discovery)
        }
        if let activity = clients.1 {
            es_unsubscribe_all(activity)
            es_delete_client(activity)
        }
    }

    private func subscribe(_ client: OpaquePointer, to events: [es_event_type_t]) -> es_return_t {
        events.withUnsafeBufferPointer { buffer in
            es_subscribe(client, buffer.baseAddress!, UInt32(buffer.count))
        }
    }

    private func handleDiscovery(_ message: UnsafePointer<es_message_t>) {
        let value = message.pointee
        let actor = value.process.pointee

        // Ignore other ES clients to prevent observer feedback loops.
        guard !actor.is_es_client else { return }

        switch value.event_type {
        case ES_EVENT_TYPE_NOTIFY_EXEC:
            let target = value.event.exec.target.pointee
            let actorWasTracked = isTracked(actor.audit_token)
            let path = string(target.executable.pointee.path)
            let signingID = optionalString(target.signing_id)

            guard actorWasTracked || HarnessClassifier.isHarness(
                executablePath: path,
                signingIdentifier: signingID
            ) else { return }

            // exec increments pidversion; discard the pre-exec identity before
            // selecting the new image so the in-memory set stays bounded.
            if actorWasTracked {
                _ = untrack(actor.audit_token)
            }
            track(target.audit_token)
            sink(makeEvent(message, kind: .processExec, process: target))

        case ES_EVENT_TYPE_NOTIFY_FORK:
            guard isTracked(actor.audit_token) else { return }
            let child = value.event.fork.child.pointee
            track(child.audit_token)
            sink(makeEvent(message, kind: .processFork, process: child))

        case ES_EVENT_TYPE_NOTIFY_EXIT:
            guard untrack(actor.audit_token) else { return }
            sink(makeEvent(message, kind: .processExit, process: actor))

        default:
            return
        }
    }

    private func handleActivity(_ message: UnsafePointer<es_message_t>) {
        let value = message.pointee
        let process = value.process.pointee
        guard !process.is_es_client, isTracked(process.audit_token) else { return }

        let kind: ESWireEvent.Kind
        let target: String
        var openFlags: Int32?
        var modified: Bool?

        switch value.event_type {
        case ES_EVENT_TYPE_NOTIFY_OPEN:
            kind = .fileOpen
            target = string(value.event.open.file.pointee.path)
            openFlags = value.event.open.fflag
        case ES_EVENT_TYPE_NOTIFY_CLOSE:
            kind = .fileClose
            target = string(value.event.close.target.pointee.path)
            modified = value.event.close.modified
        case ES_EVENT_TYPE_NOTIFY_WRITE:
            kind = .fileWrite
            target = string(value.event.write.target.pointee.path)
        case ES_EVENT_TYPE_NOTIFY_UNLINK:
            kind = .fileDelete
            target = string(value.event.unlink.target.pointee.path)
        case ES_EVENT_TYPE_NOTIFY_TRUNCATE:
            kind = .fileTruncate
            target = string(value.event.truncate.target.pointee.path)
        default:
            return
        }

        sink(makeEvent(
            message,
            kind: kind,
            process: process,
            targetPath: target,
            openFlags: openFlags,
            modified: modified
        ))
    }

    private func track(_ token: audit_token_t) {
        let key = processKey(token)
        let client = stateLock.withLock { () -> OpaquePointer? in
            trackedProcesses.insert(key)
            return activityClient
        }

        // In inverted mode this API selects (rather than suppresses) the
        // process. The kernel removes the rule automatically when it exits.
        if let client {
            var mutableToken = token
            _ = es_mute_process(client, &mutableToken)
        }
    }

    private func isTracked(_ token: audit_token_t) -> Bool {
        let key = processKey(token)
        return stateLock.withLock { trackedProcesses.contains(key) }
    }

    @discardableResult
    private func untrack(_ token: audit_token_t) -> Bool {
        let key = processKey(token)
        return stateLock.withLock { trackedProcesses.remove(key) != nil }
    }

    private func processKey(_ token: audit_token_t) -> ProcessKey {
        ProcessKey(
            pid: audit_token_to_pid(token),
            version: Int32(audit_token_to_pidversion(token))
        )
    }

    private func makeEvent(
        _ message: UnsafePointer<es_message_t>,
        kind: ESWireEvent.Kind,
        process: es_process_t,
        targetPath: String? = nil,
        openFlags: Int32? = nil,
        modified: Bool? = nil
    ) -> ESWireEvent {
        let value = message.pointee
        let key = processKey(process.audit_token)
        let seconds = UInt64(max(0, value.time.tv_sec))
        let nanoseconds = UInt64(max(0, value.time.tv_nsec))

        return ESWireEvent(
            unixNanoseconds: seconds &* 1_000_000_000 &+ nanoseconds,
            kind: kind,
            processID: key.pid,
            processVersion: key.version,
            processPath: PathSanitizer.sanitize(string(process.executable.pointee.path)),
            signingIdentifier: optionalString(process.signing_id),
            teamIdentifier: optionalString(process.team_id),
            targetPath: targetPath.map(PathSanitizer.sanitize),
            openFlags: openFlags,
            modified: modified,
            sequence: value.version >= 2 ? value.seq_num : nil,
            globalSequence: value.version >= 4 ? value.global_seq_num : nil,
            messageVersion: value.version
        )
    }

    private func string(_ token: es_string_token_t) -> String {
        let rawBytes = UnsafeRawBufferPointer(start: token.data, count: Int(token.length))
        return String(decoding: rawBytes.bindMemory(to: UInt8.self), as: UTF8.self)
    }

    private func optionalString(_ token: es_string_token_t) -> String? {
        guard token.length > 0 else { return nil }
        return string(token)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
