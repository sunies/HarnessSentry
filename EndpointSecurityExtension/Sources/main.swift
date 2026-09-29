import Dispatch
import Foundation
import os

private let logger = Logger(subsystem: "com.harnesssentry.sensor.endpoint-security", category: "lifecycle")
private let buffer = EventBuffer(capacity: 2_048)
private let deliveryQueue = DispatchQueue(label: "com.harnesssentry.es.delivery", qos: .utility)
private let server = EventXPCServer(buffer: buffer)
private let monitor = EndpointSecurityMonitor { event in
    // The ES callback only creates a small value object. JSON encoding and XPC
    // queueing happen away from the callback on a utility queue.
    deliveryQueue.async {
        buffer.enqueue(event)
    }
}

do {
    try monitor.start()
    server.resume()
    logger.notice("HarnessSentry Endpoint Security sensor started")
    dispatchMain()
} catch {
    logger.fault("Unable to start Endpoint Security sensor: \(String(describing: error), privacy: .public)")
    exit(EXIT_FAILURE)
}
