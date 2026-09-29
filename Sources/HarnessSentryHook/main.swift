import Foundation
import HarnessSentryCore

@main
struct HarnessSentryHook {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let configIndex = arguments.firstIndex(of: "--print-config"), arguments.indices.contains(configIndex + 1) {
            printConfiguration(adapterID: arguments[configIndex + 1])
            return
        }

        let adapterID: String
        if let adapterIndex = arguments.firstIndex(of: "--adapter"), arguments.indices.contains(adapterIndex + 1) {
            adapterID = arguments[adapterIndex + 1]
        } else {
            adapterID = ProcessInfo.processInfo.environment["HARNESS_SENTRY_ADAPTER"] ?? "unknown"
        }
        let eventName: String? = if let eventIndex = arguments.firstIndex(of: "--event"),
                                    arguments.indices.contains(eventIndex + 1) {
            arguments[eventIndex + 1]
        } else {
            nil
        }

        // Hooks must never slow or break the monitored tool. All failures are
        // intentionally silent and return success.
        guard let data = try? FileHandle.standardInput.readToEnd(), !data.isEmpty else { return }
        guard let event = try? HookEventNormalizer.normalize(
            data: data,
            adapterID: adapterID,
            eventNameOverride: eventName
        ) else { return }
        let databaseURL = ProcessInfo.processInfo.environment["HARNESS_SENTRY_DATABASE"].map(URL.init(fileURLWithPath:))
            ?? (try? SQLiteEventStore.defaultDatabaseURL())
        guard let databaseURL,
              let store = try? SQLiteEventStore(url: databaseURL) else { return }
        guard (try? await store.isMonitoringPaused()) != true else { return }

        let recent = (try? await store.fetchEvents(
            limit: 200,
            since: event.timestamp.addingTimeInterval(-300),
            toolID: adapterID
        )) ?? []
        let allowed = (try? await store.isAllowed(event)) ?? false
        let evaluation = allowed ? nil : AnomalyRuleEngine.evaluate(event: event, recentEvents: recent)
        try? await store.record(event: event, evaluation: evaluation)
        if let statistics = try? await store.statistics(),
           statistics.databaseBytes >= RetentionPolicy.default.cleanupThresholdBytes {
            _ = try? await store.enforceRetention(.default)
        }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("app.harnesssentry.dataChanged"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private static func printConfiguration(adapterID: String) {
        guard HookConfigurationBuilder.supportedAdapterIDs.contains(adapterID)
                || ManagedHookArtifactBuilder.supportedAdapterIDs.contains(adapterID) else {
            FileHandle.standardError.write(Data("不支持的 Hook 适配器：\(adapterID)\n".utf8))
            return
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let data = HookConfigurationBuilder.supportedAdapterIDs.contains(adapterID)
            ? try? HookConfigurationBuilder.data(executablePath: executable, adapterID: adapterID)
            : try? ManagedHookArtifactBuilder.data(executablePath: executable, adapterID: adapterID)
        if let data,
           let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    }
}
