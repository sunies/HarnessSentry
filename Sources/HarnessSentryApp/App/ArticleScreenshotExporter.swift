import AppKit
import SwiftUI

@MainActor
enum ArticleScreenshotExporter {
    static func captureAll(model: AppModel, to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await model.refresh()
        await model.refreshHookStatuses()

        let navigation = DashboardNavigation()
        let controller = NSHostingController(rootView: DashboardView(model: model, navigation: navigation))
        let window = NSWindow(
            contentRect: NSRect(x: -12_000, y: -12_000, width: 1_110, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "HarnessSentry"
        window.titlebarAppearsTransparent = true
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1_110, height: 800))
        window.setFrameOrigin(NSPoint(x: -12_000, y: -12_000))
        window.orderBack(nil)

        let sections: [(DashboardView.Section, String)] = [
            (.overview, "gs-real-overview.png"),
            (.incidents, "gs-real-incidents.png"),
            (.adapters, "gs-real-adapters.png"),
            (.settings, "gs-real-settings.png"),
        ]
        for (section, name) in sections {
            navigation.selection = section
            try await settle()
            guard let contentView = window.contentView else { continue }
            try writePNG(of: contentView, to: directory.appendingPathComponent(name))
        }

        let menuController = NSHostingController(
            rootView: MenuPopoverView(model: model, openDashboard: {}, openIncidents: {}, quitApplication: {})
        )
        menuController.sizingOptions = [.preferredContentSize]
        let menuWindow = NSWindow(
            contentRect: NSRect(x: -12_000, y: -12_000, width: 320, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        menuWindow.contentViewController = menuController
        menuWindow.setContentSize(NSSize(width: 320, height: max(menuController.preferredContentSize.height, 420)))
        menuWindow.setFrameOrigin(NSPoint(x: -12_000, y: -12_000))
        menuWindow.orderBack(nil)
        try await settle()
        if let menuView = menuWindow.contentView {
            try writePNG(of: menuView, to: directory.appendingPathComponent("gs-real-menu.png"))
        }
        menuWindow.close()
        window.close()
    }

    private static func settle() async throws {
        try await Task.sleep(for: .milliseconds(180))
        await Task.yield()
    }

    private static func writePNG(of view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds.integral
        guard bounds.width > 0, bounds.height > 0,
              let representation = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if let context = NSGraphicsContext(bitmapImageRep: representation) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
        }
        view.cacheDisplay(in: bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: url, options: .atomic)
    }
}
