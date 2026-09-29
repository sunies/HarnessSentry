import Foundation
import HarnessSentryCore

#if canImport(EndpointSecurity)
import EndpointSecurity
#endif

public enum EndpointSecurityAvailability: Equatable, Sendable {
    case available
    case notEntitled
    case notPermitted
    case notPrivileged
    case unsupported
    case failed(code: Int32)

    public var userFacingDescription: String {
        switch self {
        case .available: "ES Sensor 可用"
        case .notEntitled: "缺少 Endpoint Security entitlement"
        case .notPermitted: "尚未获得完整磁盘访问权限"
        case .notPrivileged: "ES Sensor 未以系统扩展运行"
        case .unsupported: "当前系统不支持 Endpoint Security"
        case .failed(let code): "ES Sensor 初始化失败（\(code)）"
        }
    }
}

public enum EndpointSecurityProbe {
    public static func check() -> EndpointSecurityAvailability {
        #if canImport(EndpointSecurity)
        var client: OpaquePointer?
        let result = es_new_client(&client) { _, _ in }
        if let client {
            es_delete_client(client)
        }

        switch result {
        case ES_NEW_CLIENT_RESULT_SUCCESS:
            return .available
        case ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED:
            return .notEntitled
        case ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED:
            return .notPermitted
        case ES_NEW_CLIENT_RESULT_ERR_NOT_PRIVILEGED:
            return .notPrivileged
        default:
            return .failed(code: Int32(result.rawValue))
        }
        #else
        return .unsupported
        #endif
    }
}

/// Boundary used by the app today and by the future System Extension target.
/// The unsigned Community build never starts an ES client; it only probes and
/// reports availability, then continues with adapter sensors.
public actor EndpointSecuritySensor: EventSensor {
    public nonisolated let id = "endpoint-security"
    public private(set) var availability: EndpointSecurityAvailability = .unsupported

    public init() {}

    public func start(sink: @escaping @Sendable (BehaviorEvent) -> Void) async throws {
        availability = EndpointSecurityProbe.check()
        guard availability == .available else { return }

        // Real subscriptions live in the signed System Extension target. Keeping
        // this boundary in the package lets the app and rule engine be completed
        // and tested before Apple grants the entitlement.
    }

    public func stop() async {}
}
