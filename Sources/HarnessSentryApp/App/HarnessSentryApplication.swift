import AppKit
import UserNotifications

@main
@MainActor
struct HarnessSentryApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    private var statusController: StatusItemController?
    private var articleScreenshotTask: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let outputDirectory = Self.articleScreenshotDirectory() {
            NSApp.setActivationPolicy(.prohibited)
            model.start()
            articleScreenshotTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await ArticleScreenshotExporter.captureAll(model: model, to: outputDirectory)
                } catch {
                    FileHandle.standardError.write(Data("文档截图失败：\(error.localizedDescription)\n".utf8))
                }
                model.stop()
                NSApp.terminate(nil)
            }
            return
        }
        if let runningInstance = Self.otherRunningInstance() {
            runningInstance.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        statusController = StatusItemController(model: model)
        model.start()
    }

    private static func articleScreenshotDirectory() -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--capture-article-screenshots"),
              arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    private static func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return nil }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != currentPID && !$0.isTerminated }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await model.refreshNotificationAuthorization() }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor [weak self] in
            self?.statusController?.openDashboard(showing: .incidents)
        }
        completionHandler()
    }
}
