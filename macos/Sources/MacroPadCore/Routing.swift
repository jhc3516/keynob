import Darwin
import Foundation

public enum BindingScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case global
    case chatGPT = "chatgpt"
    case codexCLI = "codex_cli"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .global: "모든 프로그램"
        case .chatGPT: "ChatGPT에서만"
        case .codexCLI: "Codex CLI에서만 (전용 실행기)"
        }
    }

}

public enum BindingActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case disabled
    case shortcut
    case text
    case builtIn = "built_in"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .disabled: "사용 안 함"
        case .shortcut: "단축키"
        case .text: "텍스트 입력"
        case .builtIn: "내장 동작"
        }
    }

}

public struct BuiltInAction: Identifiable, Hashable, Sendable {
    public let id: String
    public let scope: BindingScope
    public let displayName: String

    public init(id: String, scope: BindingScope, displayName: String) {
        self.id = id
        self.scope = scope
        self.displayName = displayName
    }
}

public enum BuiltInActionCatalog {
    public static let all: [BuiltInAction] = [
        BuiltInAction(id: "previous_conversation", scope: .chatGPT, displayName: "이전 대화"),
        BuiltInAction(id: "next_conversation", scope: .chatGPT, displayName: "다음 대화"),
        BuiltInAction(id: "switch_chat", scope: .chatGPT, displayName: "대화 전환"),
        BuiltInAction(id: "enter", scope: .chatGPT, displayName: "Enter"),
        BuiltInAction(id: "reasoning_down", scope: .chatGPT, displayName: "추론 수준 낮추기"),
        BuiltInAction(id: "reasoning_up", scope: .chatGPT, displayName: "추론 수준 높이기"),
        BuiltInAction(id: "reasoning_medium", scope: .chatGPT, displayName: "추론 수준 Medium"),
        BuiltInAction(id: "model_menu_up", scope: .chatGPT, displayName: "모델 메뉴 위"),
        BuiltInAction(id: "model_menu_down", scope: .chatGPT, displayName: "모델 메뉴 아래"),
        BuiltInAction(id: "model_selector", scope: .chatGPT, displayName: "모델 선택기"),
        BuiltInAction(id: "skills", scope: .chatGPT, displayName: "Skills 열기"),
        BuiltInAction(id: "automations", scope: .chatGPT, displayName: "Automations 열기"),
        BuiltInAction(id: "settings", scope: .chatGPT, displayName: "Settings 열기"),
        BuiltInAction(id: "copy", scope: .chatGPT, displayName: "복사"),
        BuiltInAction(id: "resume", scope: .codexCLI, displayName: "세션 재개 (/resume)"),
        BuiltInAction(id: "reasoning_down", scope: .codexCLI, displayName: "추론 수준 낮추기"),
        BuiltInAction(id: "reasoning_up", scope: .codexCLI, displayName: "추론 수준 높이기"),
        BuiltInAction(id: "diagnose", scope: .codexCLI, displayName: "문제 진단 요청"),
        BuiltInAction(id: "explain_project", scope: .codexCLI, displayName: "프로젝트 설명 요청"),
        BuiltInAction(id: "inspect_docs", scope: .codexCLI, displayName: "문서 점검 요청"),
        BuiltInAction(id: "copy", scope: .codexCLI, displayName: "복사")
    ]

    public static func actions(for scope: BindingScope) -> [BuiltInAction] {
        all.filter { $0.scope == scope }
    }

    public static func contains(id: String, scope: BindingScope) -> Bool {
        all.contains { $0.id == id && $0.scope == scope }
    }
}

public struct RoutedBinding: Codable, Equatable, Sendable {
    public var scope: BindingScope
    public var actionKind: BindingActionKind
    public var shortcut: DeviceShortcut
    public var text: String
    public var builtInActionID: String?

    public init(
        scope: BindingScope = .global,
        actionKind: BindingActionKind = .disabled,
        shortcut: DeviceShortcut = DeviceShortcut(disabled: true),
        text: String = "",
        builtInActionID: String? = nil
    ) {
        self.scope = scope
        self.actionKind = actionKind
        self.shortcut = shortcut
        self.text = text
        self.builtInActionID = builtInActionID
    }

    public var displayName: String {
        switch actionKind {
        case .disabled: "Disabled"
        case .shortcut: shortcut.displayName
        case .text: text.isEmpty ? "텍스트 없음" : "텍스트 \(text.prefix(24))"
        case .builtIn:
            BuiltInActionCatalog.actions(for: scope)
                .first(where: { $0.id == builtInActionID })?.displayName ?? "내장 동작 없음"
        }
    }
}

public extension RoutedBinding {
    func normalizedForPersistence() -> RoutedBinding {
        var value = self
        switch actionKind {
        case .disabled:
            value.shortcut = DeviceShortcut(disabled: true)
            value.text = ""
            value.builtInActionID = nil
        case .shortcut:
            value.shortcut.disabled = false
            value.text = ""
            value.builtInActionID = nil
        case .text:
            value.shortcut = DeviceShortcut(disabled: true)
            value.builtInActionID = nil
        case .builtIn:
            value.shortcut = DeviceShortcut(disabled: true)
            value.text = ""
        }
        return value
    }
}

public struct RoutingSettings: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var bindings: [String: RoutedBinding]

    public init(schemaVersion: Int = 1, bindings: [String: RoutedBinding] = [:]) {
        self.schemaVersion = schemaVersion
        self.bindings = bindings
    }

    public static func key(layer: Int, input: EditableInput) -> String {
        "layer\(layer).\(input.id)"
    }

    public subscript(layer: Int, input: EditableInput) -> RoutedBinding? {
        get { bindings[Self.key(layer: layer, input: input)] }
        set { bindings[Self.key(layer: layer, input: input)] = newValue }
    }
}

public enum RoutingSettingsError: Error, LocalizedError {
    case unsupportedSchema(Int)
    case invalidBinding(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "지원하지 않는 앱 설정 버전입니다: \(version)"
        case .invalidBinding(let reason): "앱 설정이 올바르지 않습니다: \(reason)"
        }
    }
}

public struct RoutingSettingsStore: Sendable {
    public let url: URL

    public init(url: URL? = nil) {
        if let url { self.url = url; return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.url = base.appendingPathComponent("MacroPad Studio/settings.json")
    }

    public func load() throws -> RoutingSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return RoutingSettings() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let settings = try JSONDecoder().decode(RoutingSettings.self, from: Data(contentsOf: url))
        try Self.validate(settings)
        return settings
    }

    public func save(_ settings: RoutingSettings) throws {
        try Self.validate(settings)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writeUserOnlyAtomically(encoder.encode(settings), to: url)
    }

    public static func validate(_ settings: RoutingSettings) throws {
        guard settings.schemaVersion == 1 else {
            throw RoutingSettingsError.unsupportedSchema(settings.schemaVersion)
        }
        let validKeys = Set(MacroPadIdentity.layerIDs.flatMap { layer in
            EditableInput.all.map { RoutingSettings.key(layer: layer, input: $0) }
        })
        for (key, binding) in settings.bindings {
            guard validKeys.contains(key) else { throw RoutingSettingsError.invalidBinding(key) }
            // Keep older, unsupported app shortcuts editable after an upgrade.
            // Applying or dispatching them still requires a supported key.
            _ = try BindingCompiler.validate(binding, requireAppKeySupport: false)
        }
    }
}

public struct MacInputAlias: Hashable, Sendable {
    public let layer: Int
    public let input: EditableInput
    public let hidCode: UInt8
    public let cgKeyCode: UInt16
}

public enum MacInputAliasCatalog {
    public static let aliases: [MacInputAlias] = {
        let hid: [[UInt8]] = [
            Array(0x3A...0x45) + [0x50, 0x28, 0x4F, 0x52, 0x10, 0x51],
            Array(0x68...0x6F) + [0x04, 0x16, 0x07, 0x09, 0x4A, 0x4D, 0x4B, 0x4E, 0x4C, 0x49],
            [0x0A, 0x0B, 0x0D, 0x0E, 0x0F, 0x1D, 0x1B, 0x06, 0x19, 0x05, 0x11, 0x14, 0x1A, 0x08, 0x15, 0x17, 0x1C, 0x18]
        ]
        let cg: [[UInt16]] = [
            [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 123, 36, 124, 126, 46, 125],
            [105, 107, 113, 106, 64, 79, 80, 90, 0, 1, 2, 3, 115, 119, 116, 121, 117, 114],
            [5, 4, 38, 40, 37, 6, 7, 8, 9, 11, 45, 12, 13, 14, 15, 17, 16, 32]
        ]
        return MacroPadIdentity.layerIDs.flatMap { layer in
            EditableInput.all.enumerated().map { index, input in
                MacInputAlias(layer: layer, input: input, hidCode: hid[layer - 1][index], cgKeyCode: cg[layer - 1][index])
            }
        }
    }()

    public static func alias(layer: Int, input: EditableInput) -> MacInputAlias? {
        aliases.first { $0.layer == layer && $0.input == input }
    }

    public static func alias(cgKeyCode: UInt16) -> MacInputAlias? {
        aliases.first { $0.cgKeyCode == cgKeyCode }
    }
}

public enum CompiledBinding: Sendable {
    case deviceDirect(report: Data)
    case appRouted(report: Data, alias: MacInputAlias, binding: RoutedBinding)
}

public enum BindingCompilerError: Error, LocalizedError, Equatable {
    case unsupportedKindForGlobal
    case missingShortcut
    case invalidShortcut
    case unsupportedAppKey(UInt8)
    case invalidText
    case invalidBuiltIn
    case missingAlias

    public var errorDescription: String? {
        switch self {
        case .unsupportedKindForGlobal: "모든 프로그램 범위는 단축키 또는 사용 안 함만 지원합니다."
        case .missingShortcut: "단축키에 보조키 또는 일반 키를 하나 이상 지정하세요."
        case .invalidShortcut: "지원하지 않는 키 또는 보조키가 포함된 단축키입니다."
        case .unsupportedAppKey(let code):
            "\(DeviceKeyCatalog.key(code: code)?.displayName ?? String(code)) 키는 macOS 앱별 범위에서 전달할 수 없습니다. 지원 키를 선택하거나 모든 프로그램 범위를 사용하세요."
        case .invalidText: "텍스트는 1~2000자이며 줄바꿈과 탭 이외의 제어 문자를 포함할 수 없습니다."
        case .invalidBuiltIn: "선택한 범위에서 지원하지 않는 내장 동작입니다."
        case .missingAlias: "이 입력의 macOS 라우팅 별칭이 없습니다."
        }
    }
}

public enum BindingCompiler {
    @discardableResult
    public static func validate(_ binding: RoutedBinding, requireAppKeySupport: Bool = true) throws -> Bool {
        if binding.scope == .global && ![.disabled, .shortcut].contains(binding.actionKind) {
            throw BindingCompilerError.unsupportedKindForGlobal
        }
        switch binding.actionKind {
        case .disabled: break
        case .shortcut:
            guard !binding.shortcut.disabled,
                  !binding.shortcut.modifierCodes.isEmpty || binding.shortcut.keyCode != nil else {
                throw BindingCompilerError.missingShortcut
            }
            guard binding.shortcut.modifierCodes.isSubset(of: Set(DeviceKeyCatalog.modifiers.map(\.code))),
                  binding.shortcut.keyCode.map({ code in DeviceKeyCatalog.regularKeys.contains { $0.code == code } }) ?? true else {
                throw BindingCompilerError.invalidShortcut
            }
            if requireAppKeySupport, binding.scope != .global, let code = binding.shortcut.keyCode,
               MacKeyCodeCatalog.cgKeyCode(hidCode: code) == nil {
                throw BindingCompilerError.unsupportedAppKey(code)
            }
        case .text:
            guard binding.scope != .global, !binding.text.isEmpty, binding.text.count <= 2000,
                  binding.text.unicodeScalars.allSatisfy({ scalar in
                      scalar.value >= 0x20 || scalar == "\n" || scalar == "\r" || scalar == "\t"
                  }) else { throw BindingCompilerError.invalidText }
        case .builtIn:
            guard let id = binding.builtInActionID,
                  BuiltInActionCatalog.contains(id: id, scope: binding.scope) else {
                throw BindingCompilerError.invalidBuiltIn
            }
        }
        return true
    }

    public static func compile(
        _ binding: RoutedBinding,
        layer: Int,
        input: EditableInput
    ) throws -> CompiledBinding {
        try validate(binding)
        if binding.scope == .global {
            let shortcut = binding.actionKind == .disabled
                ? DeviceShortcut(disabled: true)
                : binding.shortcut
            return .deviceDirect(report: try DeviceConfigurationCodec.encodeShortcut(
                shortcut, layer: layer, slot: input.slot))
        }
        guard let alias = MacInputAliasCatalog.alias(layer: layer, input: input) else {
            throw BindingCompilerError.missingAlias
        }
        return .appRouted(
            report: try aliasReport(alias), alias: alias, binding: binding)
    }

    public static func aliasReport(_ alias: MacInputAlias) throws -> Data {
        var shortcut = DeviceShortcut(
            modifierCodes: Set(DeviceKeyCatalog.modifiers.prefix(3).map(\.code)),
            keyCode: alias.hidCode)
        shortcut.disabled = false
        return try DeviceConfigurationCodec.encodeShortcut(
            shortcut, layer: alias.layer, slot: alias.input.slot)
    }

    public static func binding(
        from report: Data,
        layer: Int,
        input: EditableInput,
        settings: RoutingSettings
    ) -> RoutedBinding {
        if let saved = settings.bindings[RoutingSettings.key(layer: layer, input: input)],
           let alias = MacInputAliasCatalog.alias(layer: layer, input: input),
           (try? aliasReport(alias)) == report {
            return saved
        }
        guard let shortcut = try? DeviceConfigurationCodec.decodeShortcut(
            report: report, layer: layer, slot: input.slot) else {
            return RoutedBinding()
        }
        return RoutedBinding(
            scope: .global,
            actionKind: shortcut.disabled ? .disabled : .shortcut,
            shortcut: shortcut)
    }

    public static func reconciledSettings(
        _ settings: RoutingSettings,
        snapshot: FullDeviceSnapshot
    ) -> RoutingSettings {
        var result = settings
        for layer in MacroPadIdentity.layerIDs {
            for input in EditableInput.all {
                let key = RoutingSettings.key(layer: layer, input: input)
                guard let saved = result.bindings[key], saved.scope != .global,
                      let report = snapshot.report(layer: layer, slot: input.slot),
                      let alias = MacInputAliasCatalog.alias(layer: layer, input: input) else { continue }
                if (try? aliasReport(alias)) != report { result.bindings.removeValue(forKey: key) }
            }
        }
        return result
    }
}

public enum AppAliasRoutingDecision: Equatable, Sendable {
    case passThrough, consume, dispatch

    public static func decide(binding: RoutedBinding?, hasAliasModifiers: Bool,
                              targetScope: BindingScope?, isRepeat: Bool) -> Self {
        guard hasAliasModifiers, let binding, binding.scope != .global else { return .passThrough }
        guard !isRepeat, binding.scope == targetScope else { return .consume }
        return .dispatch
    }
}

public enum AppTargetPolicy {
    public static let chatGPTBundleIdentifiers = Set(["com.openai.codex", "com.openai.chat"])
    public static let terminalBundleIdentifier = "com.apple.Terminal"
    public static let dedicatedCLITitlePrefix = "Codex CLI - MacroPad Studio"

    public static func scope(bundleIdentifier: String?, focusedWindowTitle: String?) -> BindingScope? {
        guard let bundleIdentifier else { return nil }
        if chatGPTBundleIdentifiers.contains(bundleIdentifier) { return .chatGPT }
        guard bundleIdentifier == terminalBundleIdentifier,
              focusedWindowTitle.flatMap(instanceID(fromDedicatedCLITitle:)) != nil else { return nil }
        return .codexCLI
    }

    public static func instanceID(fromDedicatedCLITitle title: String) -> String? {
        let prefix = dedicatedCLITitlePrefix + " ["
        guard title.hasPrefix(prefix), title.hasSuffix("]") else { return nil }
        let start = title.index(title.startIndex, offsetBy: prefix.count)
        let id = String(title[start..<title.index(before: title.endIndex)])
        guard id.hasPrefix("mac-"), id.utf8.count <= 128,
              id.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57) ||
                  (scalar.value >= 65 && scalar.value <= 90) ||
                  (scalar.value >= 97 && scalar.value <= 122) ||
                  scalar == "-" || scalar == "_" || scalar == "."
              }) else { return nil }
        return id
    }
}

public struct RuntimeLEDOverlayState: Codable, Equatable, Sendable {
    public var active: Bool
    public var base: LEDSnapshot
    public var overlay: LEDSnapshot?
    public var previousOverlay: LEDSnapshot?

    public init(active: Bool, base: LEDSnapshot, overlay: LEDSnapshot? = nil, previousOverlay: LEDSnapshot? = nil) {
        self.active = active
        self.base = base
        self.overlay = overlay
        self.previousOverlay = previousOverlay
    }

    public func restorationTarget(current: LEDSnapshot) -> LEDSnapshot? {
        active && (overlay == current || previousOverlay == current) ? base : nil
    }
}

public struct RuntimeLEDOverlayStore: Sendable {
    public let url: URL

    public init(url: URL? = nil) {
        if let url { self.url = url; return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.url = base.appendingPathComponent("MacroPad Studio/runtime-led.json")
    }

    public func load() throws -> RuntimeLEDOverlayState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try JSONDecoder().decode(RuntimeLEDOverlayState.self, from: Data(contentsOf: url))
    }

    public func save(_ state: RuntimeLEDOverlayState) throws {
        guard state.base.mode <= 5, state.base.colors.count == 12 else {
            throw MacroPadProtocolError.invalidLEDState
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try writeUserOnlyAtomically(JSONEncoder().encode(state), to: url)
    }
}

private func writeUserOnlyAtomically(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var isOpen = true
    do {
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        isOpen = false
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    } catch {
        if isOpen { close(descriptor) }
        _ = unlink(temporary.path)
        throw error
    }
}
