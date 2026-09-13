import Foundation

public enum CodexAppKeybindingError: Error, LocalizedError, Equatable {
    case unreadableFile
    case invalidFile
    case unassignedCommand(String)
    case unsupportedShortcut(String)
    case unsupportedAction

    public var errorDescription: String? {
        switch self {
        case .unreadableFile:
            "ChatGPT/Codex의 keybindings.json을 읽을 수 없습니다. 대상 앱의 설정 › 키보드 단축키에서 추론 수준 단축키를 등록하세요."
        case .invalidFile:
            "ChatGPT/Codex의 keybindings.json 형식을 읽을 수 없습니다. 대상 앱의 키보드 단축키 설정을 확인하세요."
        case .unassignedCommand(let command):
            "대상 앱에 \(command) 단축키가 없습니다. ChatGPT/Codex의 설정 › 키보드 단축키에서 등록하세요."
        case .unsupportedShortcut(let command):
            "\(command)에 등록된 단축키를 Mac에서 전달할 수 없습니다. 보조키와 일반 키 하나로 된 단축키를 등록하세요."
        case .unsupportedAction:
            "이 대상 앱에서는 등록된 추론 수준 단축키를 확인할 수 없습니다."
        }
    }
}

/// Reads the desktop app's user keymap without modifying it. Reasoning commands
/// have no default binding; Keynob routing aliases are not app commands.
public struct CodexAppKeybindings: Sendable {
    public let url: URL

    public init(url: URL? = nil) {
        let codexDirectory = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        self.url = url ?? codexDirectory.appendingPathComponent("keybindings.json")
    }

    public static func commandID(for actionID: String) -> String? {
        switch actionID {
        case "reasoning_down": "composer.decreaseReasoningEffort"
        case "reasoning_up": "composer.increaseReasoningEffort"
        default: nil
        }
    }

    public func shortcut(for actionID: String) throws -> DeviceShortcut {
        guard let data = try? Data(contentsOf: url) else { throw CodexAppKeybindingError.unreadableFile }
        return try Self.shortcut(for: actionID, data: data)
    }

    public static func shortcut(for actionID: String, data: Data) throws -> DeviceShortcut {
        guard let command = commandID(for: actionID) else { throw CodexAppKeybindingError.unsupportedAction }
        struct Entry: Decodable {
            let command: String
            let key: String?
            enum CodingKeys: String, CodingKey { case command, key }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                command = try container.decode(String.self, forKey: .command)
                // The desktop app requires the key field, including explicit null.
                key = try container.decodeNil(forKey: .key) ? nil : container.decode(String.self, forKey: .key)
            }
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            throw CodexAppKeybindingError.invalidFile
        }
        let matches = entries.filter { $0.command == command }
        // A null entry explicitly disables all bindings for this command.
        guard !matches.isEmpty, !matches.contains(where: { $0.key == nil }) else {
            throw CodexAppKeybindingError.unassignedCommand(command)
        }
        for entry in matches {
            if let key = entry.key, let shortcut = parseAccelerator(key) { return shortcut }
        }
        throw CodexAppKeybindingError.unsupportedShortcut(command)
    }

    public static func parseAccelerator(_ value: String) -> DeviceShortcut? {
        let parts = value.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }
        var modifiers = Set<UInt8>()
        for part in parts.dropLast() {
            let code: UInt8
            switch part {
            case "ctrl", "control": code = 0xF1
            case "shift": code = 0xF2
            case "alt", "option": code = 0xF3
            case "cmd", "command", "super", "cmdorctrl", "commandorcontrol": code = 0xF4
            default: return nil
            }
            guard modifiers.insert(code).inserted else { return nil }
        }
        let aliases = ["return": "enter", "esc": "escape", "arrowleft": "left",
                       "arrowright": "right", "arrowup": "up", "arrowdown": "down"]
        let normalizedKey = aliases[keyName] ?? keyName
        guard let key = MacKeyCodeCatalog.regularKeys.first(where: {
            $0.id.lowercased() == normalizedKey || $0.displayName.lowercased() == normalizedKey
        }) else { return nil }
        return DeviceShortcut(modifierCodes: modifiers, keyCode: key.code)
    }
}
