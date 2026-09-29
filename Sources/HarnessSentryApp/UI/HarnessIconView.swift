import AppKit
import HarnessSentryCore
import SwiftUI

/// Uses offline brand art where its identity is known. Unknown products get a
/// neutral terminal glyph instead of an invented lookalike logo.
struct HarnessIconView: View {
    let adapter: HarnessAdapter
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24)
                .fill(Color.white)
            if let icon = HarnessArtwork.icon(for: adapter) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.04)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: size * 0.52, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.24)
                .strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityLabel("\(adapter.displayName) 图标")
    }
}

@MainActor
private enum HarnessArtwork {
    private static var icons: [String: NSImage] = [:]
    private static var unavailable = Set<String>()

    static func icon(for adapter: HarnessAdapter) -> NSImage? {
        if let cached = icons[adapter.id] { return cached }
        if unavailable.contains(adapter.id) { return nil }

        let found: NSImage?
        switch adapter.id {
        case "codex":
            found = codexIcon()
        case "qoder", "kiro":
            found = installedAppIcon(adapter)
        default:
            found = Bundle.main.url(
                forResource: adapter.id,
                withExtension: "png",
                subdirectory: "HarnessIcons"
            ).flatMap { NSImage(contentsOf: $0) } ?? installedAppIcon(adapter)
        }

        if let found {
            icons[adapter.id] = found
        } else {
            unavailable.insert(adapter.id)
        }
        return found
    }

    private static func codexIcon() -> NSImage? {
        // Some Codex installations register as ChatGPT.app. Its normal App icon
        // is not the Codex icon, so use only the explicit Codex artwork.
        if let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            let resource = application.appendingPathComponent("Contents/Resources/icon-codex-light.png")
            if let image = NSImage(contentsOf: resource) { return image }
        }
        return installedAppIcon(named: "Codex")
    }

    private static func installedAppIcon(_ adapter: HarnessAdapter) -> NSImage? {
        for bundleID in adapter.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        for name in appNames[adapter.id] ?? [] {
            if let image = installedAppIcon(named: name) { return image }
        }
        return nil
    }

    private static func installedAppIcon(named name: String) -> NSImage? {
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        for folder in [URL(fileURLWithPath: "/Applications"), userApplications] {
            let application = folder.appendingPathComponent("\(name).app", isDirectory: true)
            if FileManager.default.fileExists(atPath: application.path) {
                return NSWorkspace.shared.icon(forFile: application.path)
            }
        }
        return nil
    }

    private static let appNames: [String: [String]] = [
        "qoder": ["Qoder"],
        "workbuddy": ["WorkBuddy"],
        "kiro": ["Kiro"],
        "iflow-cli": ["iFlow"],
        "continue": ["Continue"],
        "cline": ["Cline"],
        "opencode": ["OpenCode"],
        "kimi-cli": ["Kimi Code", "Kimi"],
        "goose": ["Goose"],
        "trae": ["TRAE", "Trae"],
    ]
}
