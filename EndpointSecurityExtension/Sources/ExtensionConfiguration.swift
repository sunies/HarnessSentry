import Foundation

enum ExtensionConfiguration {
    static var machServiceName: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "HarnessSentryMachServiceName") as? String,
              !value.isEmpty,
              !value.contains("$(") else {
            fatalError("HarnessSentryMachServiceName is missing from the extension Info.plist")
        }
        return value
    }

    static var allowedClientBundleIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "HarnessSentryAllowedClientBundleIdentifier") as? String
            ?? "com.harnesssentry.app"
    }

    static var allowedTeamIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "HarnessSentryAllowedTeamIdentifier") as? String ?? ""
    }
}
