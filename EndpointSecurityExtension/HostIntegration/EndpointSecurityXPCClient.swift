import Foundation

/// Reference host-side reader. Add `HarnessSentryESXPCProtocol` to both target
/// memberships, or move that protocol to a tiny shared framework.
final class EndpointSecurityXPCClient {
    private let connection: NSXPCConnection

    init(machServiceName: String) {
        connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HarnessSentryESXPCProtocol.self)
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    func drain(
        limit: Int = 200,
        completion: @escaping (Result<([Data], UInt64), Error>) -> Void
    ) {
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            completion(.failure(error))
        }
        guard let service = proxy as? HarnessSentryESXPCProtocol else {
            completion(.failure(ClientError.invalidRemoteInterface))
            return
        }
        service.drainEvents(limit: limit) { records, dropped in
            completion(.success((records, dropped)))
        }
    }

    private enum ClientError: Error {
        case invalidRemoteInterface
    }
}
