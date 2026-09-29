import Foundation
import HarnessSentryCore

@main
struct HarnessSentryLabProbe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let toolID = value(after: "--tool", in: arguments),
              let workspace = value(after: "--workspace", in: arguments)
        else {
            fail("用法：HarnessSentryLabProbe --tool zcode --workspace <隔离仓库> [--database <sqlite>] [--all-events]")
        }

        let databaseURL = value(after: "--database", in: arguments).map(URL.init(fileURLWithPath:))
            ?? (try? SQLiteEventStore.defaultDatabaseURL())
        guard let databaseURL, let store = try? SQLiteEventStore(url: databaseURL) else {
            fail("无法打开 HarnessSentry 本地数据库")
        }
        let highSignalOnly = !arguments.contains("--all-events")
        var recentlyRecorded: [String: Date] = [:]
        var inputCount = 0
        var recordedCount = 0

        while let line = readLine(strippingNewline: true) {
            inputCount += 1
            guard let data = line.data(using: .utf8),
                  let events = try? EsloggerEventNormalizer.normalize(
                    data: data,
                    toolID: toolID,
                    workspacePath: workspace
                  )
            else { continue }

            for event in events {
                if highSignalOnly && !EsloggerEventNormalizer.isHighSignal(event, workspacePath: workspace) { continue }
                let key = "\(event.type.rawValue)|\(event.target ?? "")"
                if let last = recentlyRecorded[key], event.timestamp.timeIntervalSince(last) < 2 { continue }
                recentlyRecorded[key] = event.timestamp

                guard (try? await store.isMonitoringPaused()) != true else { continue }
                let recent = (try? await store.fetchEvents(
                    limit: 200,
                    since: event.timestamp.addingTimeInterval(-300),
                    toolID: toolID
                )) ?? []
                let allowed = (try? await store.isAllowed(event)) ?? false
                let evaluation = allowed ? nil : AnomalyRuleEngine.evaluate(event: event, recentEvents: recent)
                try? await store.record(event: event, evaluation: evaluation)
                recordedCount += 1
                if evaluation != nil {
                    DistributedNotificationCenter.default().postNotificationName(
                        Notification.Name("app.harnesssentry.dataChanged"),
                        object: nil,
                        userInfo: nil,
                        deliverImmediately: true
                    )
                }
            }
            if recentlyRecorded.count > 2_000 {
                let cutoff = Date().addingTimeInterval(-30)
                recentlyRecorded = recentlyRecorded.filter { $0.value >= cutoff }
            }
        }
        FileHandle.standardError.write(Data("HarnessSentry Lab：读取 \(inputCount) 条，记录 \(recordedCount) 条高信号行为。\n".utf8))
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        Foundation.exit(2)
    }
}
