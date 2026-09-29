import Foundation

public enum HookConfigurationEditingError: Error, LocalizedError, Sendable {
    case invalidJSON
    case invalidRoot
    case invalidHooksObject
    case invalidEventGroups(String)
    case unsupportedAdapter(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "Hook 配置不是有效的 JSON"
        case .invalidRoot:
            "Hook 配置的顶层必须是 JSON 对象"
        case .invalidHooksObject:
            "配置中的 hooks 必须是 JSON 对象"
        case .invalidEventGroups(let event):
            "配置中的 hooks.\(event) 必须是数组"
        case .unsupportedAdapter(let adapter):
            "不支持的 Hook 适配器：\(adapter)"
        }
    }
}

public struct HookConfigurationMutation: Sendable {
    public let data: Data
    public let changed: Bool

    public init(data: Data, changed: Bool) {
        self.data = data
        self.changed = changed
    }
}

/// Performs semantic JSON edits without replacing unrelated hook groups or
/// top-level settings. Detection/removal intentionally requires both the
/// HarnessSentryHook executable name and the target adapter argument.
public enum HookConfigurationEditor {
    public static let supportedAdapterIDs = HookConfigurationBuilder.supportedAdapterIDs

    public static func containsHarnessSentryHandler(in data: Data, adapterID: String) throws -> Bool {
        try validate(adapterID: adapterID)
        let root = try decodeRoot(data)
        guard let hooksContainer = root["hooks"] as? [String: Any] else {
            if root["hooks"] == nil { return false }
            throw HookConfigurationEditingError.invalidHooksObject
        }
        let style = HookConfigurationBuilder.style(for: adapterID)
        let hooks: [String: Any]
        if style == .zcodeNested {
            guard let events = hooksContainer["events"] else { return false }
            guard let eventHooks = events as? [String: Any] else {
                throw HookConfigurationEditingError.invalidHooksObject
            }
            hooks = eventHooks
        } else {
            hooks = hooksContainer
        }
        return hooks.values.contains { value in
            guard let entries = value as? [Any] else { return false }
            switch style {
            case .grouped, .zcodeNested:
                return entries.contains { groupValue in
                    guard let group = groupValue as? [String: Any],
                          let handlers = group["hooks"] as? [Any]
                    else { return false }
                    return handlers.contains { isHarnessSentryHandler($0, adapterID: adapterID) }
                }
            case .cursorFlat, .windsurfFlat, .copilotFlat:
                return entries.contains { isHarnessSentryHandler($0, adapterID: adapterID) }
            }
        }
    }

    public static func installing(
        in existingData: Data?,
        executablePath: String,
        adapterID: String
    ) throws -> HookConfigurationMutation {
        try validate(adapterID: adapterID)
        let original = try existingData.map(decodeRoot) ?? [:]
        if HookConfigurationBuilder.style(for: adapterID) == .zcodeNested {
            return try installingZCode(
                original: original,
                executablePath: executablePath,
                adapterID: adapterID
            )
        }
        var updated = original
        var hooks = try hooksObject(in: updated)

        _ = removeHandlers(adapterID: adapterID, from: &hooks)

        let generatedData = try HookConfigurationBuilder.data(
            executablePath: executablePath,
            adapterID: adapterID
        )
        let generatedRoot = try decodeRoot(generatedData)
        guard let generatedHooks = generatedRoot["hooks"] as? [String: Any] else {
            throw HookConfigurationEditingError.invalidHooksObject
        }
        if updated["version"] == nil, let version = generatedRoot["version"] {
            updated["version"] = version
        }

        for (event, generatedValue) in generatedHooks {
            guard let generatedGroups = generatedValue as? [Any] else {
                throw HookConfigurationEditingError.invalidEventGroups(event)
            }
            if let currentValue = hooks[event], !(currentValue is [Any]) {
                throw HookConfigurationEditingError.invalidEventGroups(event)
            }
            var currentGroups = hooks[event] as? [Any] ?? []
            currentGroups.append(contentsOf: generatedGroups)
            hooks[event] = currentGroups
        }
        updated["hooks"] = hooks

        return try mutation(original: original, updated: updated)
    }

    public static func removing(from existingData: Data, adapterID: String) throws -> HookConfigurationMutation {
        try validate(adapterID: adapterID)
        let original = try decodeRoot(existingData)
        if HookConfigurationBuilder.style(for: adapterID) == .zcodeNested {
            return try removingZCode(original: original, existingData: existingData, adapterID: adapterID)
        }
        var updated = original
        guard let hooksValue = updated["hooks"] else {
            return HookConfigurationMutation(data: existingData, changed: false)
        }
        guard var hooks = hooksValue as? [String: Any] else {
            throw HookConfigurationEditingError.invalidHooksObject
        }

        let changed = removeHandlers(adapterID: adapterID, from: &hooks)
        guard changed else {
            return HookConfigurationMutation(data: existingData, changed: false)
        }
        updated["hooks"] = hooks
        return try mutation(original: original, updated: updated)
    }

    private static func validate(adapterID: String) throws {
        guard supportedAdapterIDs.contains(adapterID) else {
            throw HookConfigurationEditingError.unsupportedAdapter(adapterID)
        }
    }

    private static func decodeRoot(_ data: Data) throws -> [String: Any] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HookConfigurationEditingError.invalidJSON
        }
        guard let root = object as? [String: Any] else {
            throw HookConfigurationEditingError.invalidRoot
        }
        return root
    }

    private static func hooksObject(in root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else {
            throw HookConfigurationEditingError.invalidHooksObject
        }
        return hooks
    }

    @discardableResult
    private static func removeHandlers(adapterID: String, from hooks: inout [String: Any]) -> Bool {
        switch HookConfigurationBuilder.style(for: adapterID) {
        case .grouped, .zcodeNested:
            return removeGroupedHandlers(adapterID: adapterID, from: &hooks)
        case .cursorFlat, .windsurfFlat, .copilotFlat:
            return removeFlatHandlers(adapterID: adapterID, from: &hooks)
        }
    }

    private static func removeGroupedHandlers(adapterID: String, from hooks: inout [String: Any]) -> Bool {
        var changed = false
        for event in Array(hooks.keys) {
            guard let originalGroups = hooks[event] as? [Any] else { continue }
            var filteredGroups: [Any] = []
            var eventChanged = false

            for groupValue in originalGroups {
                guard var group = groupValue as? [String: Any],
                      let handlers = group["hooks"] as? [Any]
                else {
                    filteredGroups.append(groupValue)
                    continue
                }

                let filteredHandlers = handlers.filter {
                    !isHarnessSentryHandler($0, adapterID: adapterID)
                }
                guard filteredHandlers.count != handlers.count else {
                    filteredGroups.append(groupValue)
                    continue
                }

                changed = true
                eventChanged = true
                if !filteredHandlers.isEmpty {
                    group["hooks"] = filteredHandlers
                    filteredGroups.append(group)
                }
            }

            if eventChanged && filteredGroups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = filteredGroups
            }
        }
        return changed
    }

    private static func installingZCode(
        original: [String: Any],
        executablePath: String,
        adapterID: String
    ) throws -> HookConfigurationMutation {
        var updated = original
        if let value = updated["hooks"], !(value is [String: Any]) {
            throw HookConfigurationEditingError.invalidHooksObject
        }
        var container = updated["hooks"] as? [String: Any] ?? [:]
        if let value = container["events"], !(value is [String: Any]) {
            throw HookConfigurationEditingError.invalidHooksObject
        }
        var events = container["events"] as? [String: Any] ?? [:]
        _ = removeGroupedHandlers(adapterID: adapterID, from: &events)

        let generatedData = try HookConfigurationBuilder.data(executablePath: executablePath, adapterID: adapterID)
        let generatedRoot = try decodeRoot(generatedData)
        guard let generatedContainer = generatedRoot["hooks"] as? [String: Any],
              let generatedEvents = generatedContainer["events"] as? [String: Any]
        else { throw HookConfigurationEditingError.invalidHooksObject }
        for (event, value) in generatedEvents {
            guard let generatedGroups = value as? [Any] else {
                throw HookConfigurationEditingError.invalidEventGroups(event)
            }
            if let current = events[event], !(current is [Any]) {
                throw HookConfigurationEditingError.invalidEventGroups(event)
            }
            var current = events[event] as? [Any] ?? []
            current.append(contentsOf: generatedGroups)
            events[event] = current
        }
        container["enabled"] = true
        if container["timeoutMs"] == nil { container["timeoutMs"] = 5_000 }
        if container["maxOutputBytes"] == nil { container["maxOutputBytes"] = 1_024 }
        container["events"] = events
        updated["hooks"] = container
        return try mutation(original: original, updated: updated)
    }

    private static func removingZCode(
        original: [String: Any],
        existingData: Data,
        adapterID: String
    ) throws -> HookConfigurationMutation {
        var updated = original
        guard var container = updated["hooks"] as? [String: Any],
              var events = container["events"] as? [String: Any]
        else { return HookConfigurationMutation(data: existingData, changed: false) }
        guard removeGroupedHandlers(adapterID: adapterID, from: &events) else {
            return HookConfigurationMutation(data: existingData, changed: false)
        }
        container["events"] = events
        updated["hooks"] = container
        return try mutation(original: original, updated: updated)
    }

    private static func removeFlatHandlers(adapterID: String, from hooks: inout [String: Any]) -> Bool {
        var changed = false
        for event in Array(hooks.keys) {
            guard let original = hooks[event] as? [Any] else { continue }
            let filtered = original.filter { !isHarnessSentryHandler($0, adapterID: adapterID) }
            guard filtered.count != original.count else { continue }
            changed = true
            if filtered.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = filtered
            }
        }
        return changed
    }

    private static func isHarnessSentryHandler(_ value: Any, adapterID: String) -> Bool {
        guard let handler = value as? [String: Any] else { return false }
        if let type = handler["type"] as? String, type.lowercased() != "command" { return false }
        let command = (handler["command"] as? String)
            ?? (handler["exec"] as? String)
            ?? (handler["bash"] as? String)
        guard let command, command.lowercased().contains("harnesssentryhook") else { return false }

        let expected = adapterID.lowercased()
        let loweredCommand = command.lowercased()
        if [
            "--adapter \(expected)",
            "--adapter '\(expected)'",
            "--adapter \"\(expected)\"",
            "--adapter=\(expected)",
            "--adapter='\(expected)'",
            "--adapter=\"\(expected)\"",
        ].contains(where: loweredCommand.contains) {
            return true
        }

        let arguments = (handler["args"] as? [Any])?.compactMap { ($0 as? String)?.lowercased() } ?? []
        for (index, argument) in arguments.enumerated() {
            if argument == "--adapter", arguments.indices.contains(index + 1), arguments[index + 1] == expected {
                return true
            }
            if argument == "--adapter=\(expected)" { return true }
        }
        return false
    }

    private static func mutation(
        original: [String: Any],
        updated: [String: Any]
    ) throws -> HookConfigurationMutation {
        let changed = !NSDictionary(dictionary: original).isEqual(to: updated)
        let data = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
        return HookConfigurationMutation(data: data, changed: changed)
    }
}
