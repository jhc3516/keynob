import Foundation

/// Accumulates one chord, completing when the first ordinary key or modifier is released.
public struct ShortcutCapture {
    private var heldModifiers = Set<UInt8>()
    private var finished = false
    private var capturedKeys = Set<UInt8>()
    private var capturedModifiers = Set<UInt8>()
    private var invalidKey = false
    private var started = false

    public init() {}

    public mutating func update(keyCode: UInt16? = nil, down: Bool = false,
                                modifiers: Set<UInt8>, modifierReleased: Bool = false) -> Result<DeviceShortcut, CaptureError>? {
        guard !finished else { return nil }
        let released = (keyCode != nil && !down) || modifierReleased || !heldModifiers.subtracting(modifiers).isEmpty
        heldModifiers = modifiers
        capturedModifiers.formUnion(modifiers)
        if !modifiers.isEmpty { started = true }
        if let keyCode {
            if down {
                started = true
                if let hid = MacKeyCodeCatalog.hidCode(virtualKeyCode: keyCode) {
                    capturedKeys.insert(hid)
                } else {
                    invalidKey = true
                }
            }
        }
        guard started, released else { return nil }
        finished = true
        if invalidKey { return .failure(.unsupportedKey) }
        if capturedKeys.count > 1 { return .failure(.multipleKeys) }
        return .success(DeviceShortcut(modifierCodes: capturedModifiers, keyCode: capturedKeys.first))
    }

    public enum CaptureError: Error, LocalizedError {
        case unsupportedKey, multipleKeys
        public var errorDescription: String? {
            switch self {
            case .unsupportedKey: "기록할 수 없는 키입니다. 지원 키 안내 또는 직접 선택을 확인하세요."
            case .multipleKeys: "일반 키는 1개만 기록할 수 있습니다. 보조키와 일반 키 하나를 함께 누르세요."
            }
        }
    }
}
