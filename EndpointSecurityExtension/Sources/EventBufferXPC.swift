import Foundation
import Security

/// Include this declaration in both the extension and host targets.
@objc protocol HarnessSentryESXPCProtocol {
    /// Returns privacy-minimized JSON records and a cumulative overflow count.
    func drainEvents(limit: Int, withReply reply: @escaping ([Data], UInt64) -> Void)
    func health(withReply reply: @escaping (String, Int, UInt64) -> Void)
}

/// A bounded, memory-only spool. If the UI app is unavailable, old events are
/// dropped rather than written to an unbounded privileged log.
final class EventBuffer: NSObject, HarnessSentryESXPCProtocol, @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private var storage = [Data]()
    private var head = 0
    private var dropped: UInt64 = 0

    init(capacity: Int = 2_048) {
        self.capacity = max(128, capacity)
        super.init()
    }

    func enqueue(_ event: ESWireEvent) {
        guard let encoded = try? encoder.encode(event) else { return }
        lock.lock()
        defer { lock.unlock() }

        if storage.count - head >= capacity {
            head += 1
            dropped &+= 1
        }
        storage.append(encoded)
        compactIfNeeded()
    }

    func drainEvents(limit: Int, withReply reply: @escaping ([Data], UInt64) -> Void) {
        let result = lock.withLock { () -> ([Data], UInt64) in
            let count = min(max(0, limit), min(500, storage.count - head))
            let values = count == 0 ? [] : Array(storage[head..<(head + count)])
            head += count
            compactIfNeeded()
            return (values, dropped)
        }
        reply(result.0, result.1)
    }

    func health(withReply reply: @escaping (String, Int, UInt64) -> Void) {
        let state = lock.withLock { (storage.count - head, dropped) }
        reply("ok", state.0, state.1)
    }

    private func compactIfNeeded() {
        guard head >= 1_024 || head * 2 >= storage.count else { return }
        storage.removeFirst(head)
        head = 0
    }
}

final class EventXPCServer: NSObject, NSXPCListenerDelegate {
    private let buffer: EventBuffer
    private let validator: ClientCodeValidator
    private let listener: NSXPCListener

    init(buffer: EventBuffer) {
        self.buffer = buffer
        self.validator = ClientCodeValidator(
            bundleIdentifier: ExtensionConfiguration.allowedClientBundleIdentifier,
            teamIdentifier: ExtensionConfiguration.allowedTeamIdentifier
        )
        self.listener = NSXPCListener(machServiceName: ExtensionConfiguration.machServiceName)
        super.init()
        listener.delegate = self
    }

    func resume() {
        listener.resume()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard validator.allows(processIdentifier: connection.processIdentifier) else {
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: HarnessSentryESXPCProtocol.self)
        connection.exportedObject = buffer
        connection.resume()
        return true
    }
}

/// Defense in depth for the read endpoint. The PID is sampled immediately when
/// accepting the connection; production hardening can replace this with a
/// low-level XPC listener and SecCodeCreateWithXPCMessage for audit-token-bound
/// validation of every request.
private struct ClientCodeValidator {
    let bundleIdentifier: String
    let teamIdentifier: String

    func allows(processIdentifier: pid_t) -> Bool {
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: processIdentifier)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
              let guest,
              SecCodeCheckValidity(guest, [], nil) == errSecSuccess else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }

        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo)
                == errSecSuccess,
              let info = signingInfo as? [String: Any],
              let actualIdentifier = info[kSecCodeInfoIdentifier as String] as? String,
              actualIdentifier == bundleIdentifier else {
            return false
        }

        guard !teamIdentifier.isEmpty else { return true }
        return info[kSecCodeInfoTeamIdentifier as String] as? String == teamIdentifier
    }
}
