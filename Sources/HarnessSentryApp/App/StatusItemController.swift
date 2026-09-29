import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let dashboardNavigation = DashboardNavigation()
    private var dashboardWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        popover.animates = true
        let hostingController = NSHostingController(
            rootView: MenuPopoverView(
                model: model,
                openDashboard: { [weak self] in self?.openDashboard() },
                openIncidents: { [weak self] in self?.openDashboard(showing: .incidents) },
                quitApplication: { NSApp.terminate(nil) }
            )
        )
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "HarnessSentry"
        }

        model.$status
            .sink { [weak self] status in self?.updateStatusIcon(status) }
            .store(in: &cancellables)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func openDashboard(showing section: DashboardView.Section = .overview) {
        popover.performClose(nil)
        dashboardNavigation.selection = section
        if dashboardWindow == nil {
            let hostingController = NSHostingController(rootView: DashboardView(model: model, navigation: dashboardNavigation))
            let window = NSWindow(contentViewController: hostingController)
            window.title = "HarnessSentry"
            window.setContentSize(NSSize(width: 920, height: 620))
            window.minSize = NSSize(width: 760, height: 500)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            dashboardWindow = window
        }
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateStatusIcon(_ status: ProtectionStatus) {
        guard let button = statusItem.button else { return }
        button.image = makeStatusImage(status)
        button.contentTintColor = nil
        button.setAccessibilityLabel("HarnessSentry，\(status.rawValue)")
    }

    private func makeStatusImage(_ status: ProtectionStatus) -> NSImage {
        let size = NSSize(width: 24, height: 20)
        let image = NSImage(size: size, flipped: false) { _ in
            let outlineConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
                .applying(.init(paletteColors: [.white]))
            let shield = NSImage(systemSymbolName: "shield", accessibilityDescription: status.rawValue)?
                .withSymbolConfiguration(outlineConfiguration)
            shield?.draw(in: NSRect(x: 0, y: 0, width: 20, height: 20))

            let codeMark = NSBezierPath()
            codeMark.move(to: NSPoint(x: 8.0, y: 7.1))
            codeMark.line(to: NSPoint(x: 5.9, y: 10.0))
            codeMark.line(to: NSPoint(x: 8.0, y: 12.9))
            codeMark.move(to: NSPoint(x: 12.0, y: 7.1))
            codeMark.line(to: NSPoint(x: 14.1, y: 10.0))
            codeMark.line(to: NSPoint(x: 12.0, y: 12.9))
            codeMark.lineWidth = 1.4
            codeMark.lineCapStyle = .round
            codeMark.lineJoinStyle = .round
            NSColor.white.setStroke()
            codeMark.stroke()

            let markerColor: NSColor = switch status {
            case .normal: .systemGreen
            case .incident: .systemRed
            case .degraded: .systemOrange
            case .paused: .systemOrange
            case .starting: .systemGray
            case .error: .systemRed
            }
            markerColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 17, y: 1, width: 7, height: 7)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
