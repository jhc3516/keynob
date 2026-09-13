import CryptoKit
import Foundation

public struct EditableInput: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let slot: Int
    public let label: String

    public static let all: [EditableInput] = {
        var inputs = (1...12).map {
            EditableInput(id: String(format: "key%02d", $0), slot: $0, label: "KEY \($0)")
        }
        inputs += [
            EditableInput(id: "knob1_ccw", slot: 16, label: "Knob 1 · CCW (반시계 방향)"),
            EditableInput(id: "knob1_press", slot: 17, label: "Knob 1 · Press"),
            EditableInput(id: "knob1_cw", slot: 18, label: "Knob 1 · CW (시계 방향)"),
            EditableInput(id: "knob2_ccw", slot: 19, label: "Knob 2 · CCW (반시계 방향)"),
            EditableInput(id: "knob2_press", slot: 20, label: "Knob 2 · Press"),
            EditableInput(id: "knob2_cw", slot: 21, label: "Knob 2 · CW (시계 방향)")
        ]
        return inputs
    }()

    public static func forSlot(_ slot: Int) -> EditableInput? {
        all.first { $0.slot == slot }
    }
}

public struct DeviceKey: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let code: UInt8
    public let group: String
}

public enum DeviceKeyCatalog {
    public static let modifiers: [DeviceKey] = [
        DeviceKey(id: "Control", displayName: "Control", code: 0xF1, group: "modifier"),
        DeviceKey(id: "Shift", displayName: "Shift", code: 0xF2, group: "modifier"),
        DeviceKey(id: "Option", displayName: "Option", code: 0xF3, group: "modifier"),
        DeviceKey(id: "Command", displayName: "Command", code: 0xF4, group: "modifier")
    ]

    public static let regularKeys: [DeviceKey] = {
        var keys: [DeviceKey] = []
        for (offset, character) in Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").enumerated() {
            keys.append(DeviceKey(
                id: String(character), displayName: String(character),
                code: UInt8(0x04 + offset), group: "Letters"))
        }
        for digit in 0...9 {
            let code = digit == 0 ? UInt8(0x27) : UInt8(0x1D + digit)
            keys.append(DeviceKey(id: "\(digit)", displayName: "\(digit)", code: code, group: "Numbers"))
        }
        let punctuation: [(String, String, UInt8)] = [
            ("Grave", "`", 0x35), ("Minus", "-", 0x2D), ("Equals", "=", 0x2E),
            ("LeftBracket", "[", 0x2F), ("RightBracket", "]", 0x30),
            ("Backslash", "\\", 0x31), ("Semicolon", ";", 0x33),
            ("Apostrophe", "'", 0x34), ("Comma", ",", 0x36),
            ("Period", ".", 0x37), ("Slash", "/", 0x38)
        ]
        keys += punctuation.map { DeviceKey(id: $0.0, displayName: $0.1, code: $0.2, group: "Punctuation") }
        for number in 1...24 {
            let code = number <= 12 ? UInt8(0x39 + number) : UInt8(0x5B + number)
            keys.append(DeviceKey(id: "F\(number)", displayName: "F\(number)", code: code, group: "Function"))
        }
        let named: [(String, String, UInt8, String)] = [
            ("Enter", "Enter", 0x28, "Editing"), ("Escape", "Escape", 0x29, "Editing"),
            ("Space", "Space", 0x2C, "Editing"), ("Tab", "Tab", 0x2B, "Editing"),
            ("Backspace", "Backspace", 0x2A, "Editing"), ("Insert", "Insert", 0x49, "Navigation"),
            ("Delete", "Delete", 0x4C, "Navigation"), ("Home", "Home", 0x4A, "Navigation"),
            ("End", "End", 0x4D, "Navigation"), ("PageUp", "Page Up", 0x4B, "Navigation"),
            ("PageDown", "Page Down", 0x4E, "Navigation"), ("Left", "←", 0x50, "Navigation"),
            ("Up", "↑", 0x52, "Navigation"), ("Right", "→", 0x4F, "Navigation"),
            ("Down", "↓", 0x51, "Navigation"), ("CapsLock", "Caps Lock", 0x39, "System"),
            ("PrintScreen", "Print Screen", 0x46, "System"), ("ScrollLock", "Scroll Lock", 0x47, "System"),
            ("Pause", "Pause", 0x48, "System"), ("Menu", "Menu", 0x65, "System"),
            ("NumLock", "Num Lock", 0x53, "Numpad"), ("NumpadDivide", "Num /", 0x54, "Numpad"),
            ("NumpadMultiply", "Num *", 0x55, "Numpad"), ("NumpadSubtract", "Num -", 0x56, "Numpad"),
            ("NumpadAdd", "Num +", 0x57, "Numpad"), ("Numpad0", "Num 0", 0x62, "Numpad"),
            ("NumpadDecimal", "Num .", 0x63, "Numpad")
        ]
        keys += named.map { DeviceKey(id: $0.0, displayName: $0.1, code: $0.2, group: $0.3) }
        for digit in 1...9 {
            keys.append(DeviceKey(
                id: "Numpad\(digit)", displayName: "Num \(digit)",
                code: UInt8(0x58 + digit), group: "Numpad"))
        }
        return keys
    }()

    public static let all = modifiers + regularKeys
    private static let byCode = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })
    public static func key(code: UInt8) -> DeviceKey? { byCode[code] }
}

public struct DeviceShortcut: Codable, Equatable, Sendable {
    public var disabled: Bool
    public var modifierCodes: Set<UInt8>
    public var keyCode: UInt8?

    public init(disabled: Bool = false, modifierCodes: Set<UInt8> = [], keyCode: UInt8? = nil) {
        self.disabled = disabled
        self.modifierCodes = modifierCodes
        self.keyCode = keyCode
    }

    public var displayName: String {
        if disabled { return "Disabled" }
        let modifiers = DeviceKeyCatalog.modifiers
            .filter { modifierCodes.contains($0.code) }.map(\.displayName)
        let key = keyCode.flatMap { DeviceKeyCatalog.key(code: $0) }?.displayName
        return (modifiers + [key].compactMap { $0 }).joined(separator: " + ")
    }
}

public extension FullDeviceSnapshot {
    func report(layer: Int, slot: Int) -> Data? {
        guard let layerSnapshot = layers.first(where: { $0.layer == layer }),
              let hex = layerSnapshot.slots.first(where: { $0.slot == slot })?.hex else {
            return nil
        }
        return Data(hex: hex)
    }
}

public enum DeviceConfigurationCodec {
    public static func decodeShortcut(report: Data, layer: Int, slot: Int) throws -> DeviceShortcut {
        guard KeynobReportCodec.isValidCurrentReport(report, layer: layer, slot: slot) else {
            throw KeynobProtocolError.incompatibleSlot(layer: layer, slot: slot)
        }
        let bytes = [UInt8](report)
        let count = Int(bytes[6])
        if count == 1 && bytes[9] == 0 { return DeviceShortcut(disabled: true) }
        var modifiers = Set<UInt8>()
        var regular: UInt8?
        for index in 0..<count {
            let code = bytes[9 + index * 3]
            if (0xF1...0xF4).contains(code) { modifiers.insert(code) }
            else { regular = code }
        }
        return DeviceShortcut(modifierCodes: modifiers, keyCode: regular)
    }

    public static func encodeShortcut(_ shortcut: DeviceShortcut, layer: Int, slot: Int) throws -> Data {
        guard KeynobIdentity.layerIDs.contains(layer), EditableInput.forSlot(slot) != nil else {
            throw KeynobProtocolError.invalidSlot(slot)
        }
        var codes: [UInt8]
        if shortcut.disabled {
            codes = [0]
        } else {
            codes = DeviceKeyCatalog.modifiers.map(\.code).filter(shortcut.modifierCodes.contains)
            if let keyCode = shortcut.keyCode { codes.append(keyCode) }
            if codes.isEmpty { codes = [0] }
        }
        var bytes = [UInt8](repeating: 0, count: KeynobReportCodec.inputReportLength)
        bytes[0] = 0x03
        bytes[1] = 0xFA
        bytes[2] = UInt8(slot)
        bytes[3] = UInt8(layer)
        bytes[4] = 0x01
        bytes[6] = UInt8(codes.count)
        for (index, code) in codes.enumerated() { bytes[9 + index * 3] = code }
        if !shortcut.disabled {
            for separator in stride(from: 11, through: 59, by: 3) { bytes[separator] = 0x32 }
        }
        let report = Data(bytes)
        guard KeynobReportCodec.isValidReplacementReport(report, layer: layer, slot: slot) else {
            throw KeynobProtocolError.incompatibleSlot(layer: layer, slot: slot)
        }
        return report
    }
}

public enum LEDPalette {
    public static let colors: [(id: String, label: String, value: RGBColorValue)] = [
        ("blue", "Blue", RGBColorValue(red: 0x00, green: 0x00, blue: 0xFF)),
        ("yellow", "Yellow", RGBColorValue(red: 0xFF, green: 0xFF, blue: 0x3C)),
        ("green", "Green", RGBColorValue(red: 0x00, green: 0xFF, blue: 0x00)),
        ("red", "Red", RGBColorValue(red: 0xFF, green: 0x00, blue: 0x00)),
        ("orange", "Orange", RGBColorValue(red: 0xFF, green: 0x80, blue: 0x30)),
        ("cyan", "Cyan", RGBColorValue(red: 0x00, green: 0xFF, blue: 0xFF)),
        ("purple", "Purple", RGBColorValue(red: 0x80, green: 0x00, blue: 0x80)),
        ("pink", "Pink", RGBColorValue(red: 0xFF, green: 0x66, blue: 0x66))
    ]
}

public struct DeviceBackup: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let createdUTC: Date
    public let snapshot: FullDeviceSnapshot
    public var checksum: String
}

public enum DeviceBackupError: Error, LocalizedError, Equatable {
    case invalidMetadata
    case checksumMismatch
    case missing

    public var errorDescription: String? {
        switch self {
        case .invalidMetadata: "백업 구조 또는 장치 정보가 올바르지 않습니다."
        case .checksumMismatch: "백업 체크섬이 일치하지 않습니다."
        case .missing: "저장된 장치 백업이 없습니다."
        }
    }
}

public struct DeviceBackupStore: Sendable {
    public let url: URL

    public init(url: URL? = nil) {
        if let url { self.url = url; return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.url = base.appendingPathComponent("MacroPad Studio/backups/latest.json")
    }

    @discardableResult
    public func save(_ snapshot: FullDeviceSnapshot) throws -> DeviceBackup {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var backup = DeviceBackup(schemaVersion: 1, createdUTC: now, snapshot: snapshot, checksum: "")
        backup.checksum = try Self.checksum(for: backup)
        try Self.validate(backup)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(backup).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return backup
    }

    public func load() throws -> DeviceBackup {
        guard FileManager.default.fileExists(atPath: url.path) else { throw DeviceBackupError.missing }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(DeviceBackup.self, from: Data(contentsOf: url))
        try Self.validate(backup)
        return backup
    }

    public static func validate(_ backup: DeviceBackup) throws {
        let snapshot = backup.snapshot
        guard backup.schemaVersion == 1,
              snapshot.device.vendorID == "514C", snapshot.device.productID == "8850",
              snapshot.device.usagePage == "FF00", snapshot.device.interfaceNumber == 0,
              snapshot.device.connected, snapshot.layers.count == 3,
              Set(snapshot.layers.map(\.layer)) == Set(KeynobIdentity.layerIDs),
              snapshot.led.mode <= 5, snapshot.led.colors.count == 12 else {
            throw DeviceBackupError.invalidMetadata
        }
        for layer in snapshot.layers {
            guard layer.slots.count == KeynobIdentity.slotCount,
                  Set(layer.slots.map(\.slot)) == Set(1...KeynobIdentity.slotCount) else {
                throw DeviceBackupError.invalidMetadata
            }
            for slot in layer.slots {
                guard let data = Data(hex: slot.hex), data.count == KeynobReportCodec.inputReportLength,
                      [UInt8](data)[0] == 0x03, [UInt8](data)[1] == 0xFA,
                      [UInt8](data)[2] == UInt8(slot.slot), [UInt8](data)[3] == UInt8(layer.layer) else {
                    throw DeviceBackupError.invalidMetadata
                }
            }
        }
        guard backup.checksum == (try checksum(for: backup)) else { throw DeviceBackupError.checksumMismatch }
    }

    private static func checksum(for backup: DeviceBackup) throws -> String {
        var canonical = backup
        canonical.checksum = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return SHA256.hash(data: try encoder.encode(canonical)).map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    public init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
