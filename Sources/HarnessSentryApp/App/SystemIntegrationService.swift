import AppKit
import Foundation
import HarnessSentryCore
import ServiceManagement
@preconcurrency import UserNotifications

@MainActor
enum SystemIntegrationService {
    static var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }

    static func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func requestNotificationPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func openNotificationSettings() {
        let notificationsPane = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        if !NSWorkspace.shared.open(notificationsPane) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    static func notify(_ incident: Incident) async throws {
        let content = UNMutableNotificationContent()
        content.title = incident.title
        content.body = incident.summary
        content.sound = .default
        content.userInfo = ["incidentID": incident.id.uuidString]
        let request = UNNotificationRequest(identifier: incident.id.uuidString, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }

    static func sendTestNotification() async throws {
        let content = UNMutableNotificationContent()
        content.title = "HarnessSentry 通知测试"
        content.body = "通知已送达。点击可打开异常记录。"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}
