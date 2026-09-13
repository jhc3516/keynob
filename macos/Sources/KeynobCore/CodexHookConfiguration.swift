import Foundation

public enum CodexHookConfigurationError: Error, LocalizedError, Equatable {
    case invalidRoot
    case invalidHooks
    case invalidEvent(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRoot: "hooks.json의 최상위 값이 객체가 아닙니다."
        case .invalidHooks: "hooks.json의 hooks 값이 객체가 아닙니다."
        case .invalidEvent(let event): "hooks.json의 \(event) 훅 구조가 올바르지 않습니다."
        }
    }
}

public enum CodexHookConfiguration {
    public static let eventNames = [
        "SessionStart", "UserPromptSubmit", "PermissionRequest", "PreToolUse",
        "PostToolUse", "Stop", "SessionEnd"
    ]

    public static func ownedHandlerCount(data: Data?, command: String) throws -> Int {
        let root = try rootObject(data: data)
        guard let hooks = root["hooks"] as? [String: Any] else {
            if root["hooks"] == nil { return 0 }
            throw CodexHookConfigurationError.invalidHooks
        }
        return try eventNames.reduce(0) { total, event in
            let eventGroups = try groups(value: hooks[event], event: event)
            return total + eventGroups.reduce(0) { subtotal, group in
                subtotal + ((group["hooks"] as? [[String: Any]]) ?? []).filter {
                    ($0["type"] as? String) == "command" && ($0["command"] as? String) == command
                }.count
            }
        }
    }

    public static func merged(data: Data?, command: String, install: Bool) throws -> Data {
        var root = try rootObject(data: data)
        let hooksValue = root["hooks"]
        guard hooksValue == nil || hooksValue is [String: Any] else {
            throw CodexHookConfigurationError.invalidHooks
        }
        var hooks = hooksValue as? [String: Any] ?? [:]
        for event in eventNames {
            let existing = try groups(value: hooks[event], event: event)
            var preserved = existing.compactMap { group -> [String: Any]? in
                let handlers = group["hooks"] as! [[String: Any]]
                let remaining = handlers.filter { ($0["command"] as? String) != command }
                guard !remaining.isEmpty else { return nil }
                var copy = group
                copy["hooks"] = remaining
                return copy
            }
            if install {
                preserved.append(["hooks": [["type": "command", "command": command, "timeout": 1]]])
            }
            if preserved.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = preserved }
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func rootObject(data: Data?) throws -> [String: Any] {
        guard let data else { return ["description": "Codex user hooks", "hooks": [String: Any]()] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexHookConfigurationError.invalidRoot
        }
        return root
    }

    private static func groups(value: Any?, event: String) throws -> [[String: Any]] {
        guard let value else { return [] }
        guard let groups = value as? [[String: Any]], groups.allSatisfy({ $0["hooks"] is [[String: Any]] }) else {
            throw CodexHookConfigurationError.invalidEvent(event)
        }
        return groups
    }
}
