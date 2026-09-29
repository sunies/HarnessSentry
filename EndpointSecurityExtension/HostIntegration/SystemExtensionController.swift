import Foundation
import SystemExtensions

/// Reference host-side controller. Add this file to the containing app target,
/// not to the system-extension target.
final class SystemExtensionController: NSObject, OSSystemExtensionRequestDelegate {
    enum Operation {
        case activate
        case deactivate
    }

    struct Result {
        let operation: Operation
        let needsUserApproval: Bool
    }

    private let extensionIdentifier: String
    private var completion: ((Swift.Result<Result, Error>) -> Void)?
    private var operation: Operation = .activate
    private var needsUserApproval = false

    init(extensionIdentifier: String = "com.harnesssentry.sensor.endpoint-security") {
        self.extensionIdentifier = extensionIdentifier
    }

    func activate(completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        submit(operation: .activate, completion: completion)
    }

    func deactivate(completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        submit(operation: .deactivate, completion: completion)
    }

    private func submit(
        operation: Operation,
        completion: @escaping (Swift.Result<Result, Error>) -> Void
    ) {
        self.operation = operation
        self.completion = completion
        self.needsUserApproval = false

        let request: OSSystemExtensionRequest
        switch operation {
        case .activate:
            request = .activationRequest(
                forExtensionWithIdentifier: extensionIdentifier,
                queue: .main
            )
        case .deactivate:
            request = .deactivationRequest(
                forExtensionWithIdentifier: extensionIdentifier,
                queue: .main
            )
        }
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        needsUserApproval = true
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        ext.bundleVersion > existing.bundleVersion ? .replace : .cancel
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        completion?(.success(Result(
            operation: operation,
            needsUserApproval: needsUserApproval
        )))
        completion = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        completion?(.failure(error))
        completion = nil
    }
}
