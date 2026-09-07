import CHIDBridge
import Foundation

public enum MacroPadHIDError: Error, Equatable, LocalizedError, Sendable {
    case deviceNotFound
    case multipleDevices(Int)
    case bridge(code: Int32, message: String)
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            "지원 매크로패드가 USB로 연결되지 않았습니다."
        case .multipleDevices(let count):
            "일치하는 장치가 \(count)대 이상입니다. 설정할 장치 한 대만 연결하세요."
        case .bridge(_, let message):
            "HID 통신 실패: \(message)"
        case .rollbackFailed:
            "장치 쓰기 실패 후 원래 상태 확인에도 실패했습니다. 백업으로 복원해야 합니다."
        }
    }
}

public struct MacroPadHID: Sendable {
    private static let ok = Int32(MP_HID_OK.rawValue)
    private static let notFound = Int32(MP_HID_NOT_FOUND.rawValue)
    private static let multipleDevices = Int32(MP_HID_MULTIPLE_DEVICES.rawValue)
    private static let rollbackFailed = Int32(MP_HID_ROLLBACK_FAILED.rawValue)

    public init() {}

    public func discover() throws -> DeviceSnapshot {
        var count: Int32 = 0
        var serial = [CChar](repeating: 0, count: 256)
        var product = [CChar](repeating: 0, count: 256)
        var transport = [CChar](repeating: 0, count: 64)
        let result = serial.withUnsafeMutableBufferPointer { serialBuffer in
            product.withUnsafeMutableBufferPointer { productBuffer in
                transport.withUnsafeMutableBufferPointer { transportBuffer in
                    mp_hid_discover(
                        &count,
                        serialBuffer.baseAddress,
                        serialBuffer.count,
                        productBuffer.baseAddress,
                        productBuffer.count,
                        transportBuffer.baseAddress,
                        transportBuffer.count)
                }
            }
        }

        if result == Self.notFound {
            return DeviceSnapshot(connected: false, matchingCount: 0)
        }
        if result == Self.multipleDevices {
            throw MacroPadHIDError.multipleDevices(Int(count))
        }
        guard result == Self.ok else { throw bridgeError(result) }
        let snapshot = DeviceSnapshot(
            connected: true,
            matchingCount: Int(count),
            serial: string(from: serial),
            product: string(from: product),
            transport: string(from: transport))
        _ = try readLayer(1)
        return snapshot
    }

    public func readLayer(_ layer: Int) throws -> LayerSnapshot {
        guard MacroPadIdentity.layerIDs.contains(layer) else {
            throw MacroPadProtocolError.invalidLayer(layer)
        }
        var bytes = [UInt8](
            repeating: 0,
            count: MacroPadIdentity.slotCount * MacroPadReportCodec.inputReportLength)
        let request = try MacroPadReportCodec.readLayerRequest(layer: layer)
        let result = request.withUnsafeBytes { requestBuffer in
            bytes.withUnsafeMutableBufferPointer { buffer in
                mp_hid_read_layer(
                    Int32(layer),
                    requestBuffer.bindMemory(to: UInt8.self).baseAddress,
                    requestBuffer.count,
                    buffer.baseAddress,
                    buffer.count)
            }
        }
        if result == Self.notFound { throw MacroPadHIDError.deviceNotFound }
        if result == Self.multipleDevices {
            throw MacroPadHIDError.multipleDevices(matchingDeviceCount())
        }
        guard result == Self.ok else { throw bridgeError(result) }
        let reports = (0..<MacroPadIdentity.slotCount).map { index in
            let start = index * MacroPadReportCodec.inputReportLength
            return Data(bytes[start..<(start + MacroPadReportCodec.inputReportLength)])
        }
        return try MacroPadReportCodec.parseLayer(layer: layer, reports: reports)
    }

    public func readLED() throws -> LEDSnapshot {
        var bytes = [UInt8](repeating: 0, count: MacroPadReportCodec.inputReportLength)
        let request = MacroPadReportCodec.readLEDRequest()
        let result = request.withUnsafeBytes { requestBuffer in
            bytes.withUnsafeMutableBufferPointer { buffer in
                mp_hid_read_led(
                    requestBuffer.bindMemory(to: UInt8.self).baseAddress,
                    requestBuffer.count,
                    buffer.baseAddress,
                    buffer.count)
            }
        }
        if result == Self.notFound { throw MacroPadHIDError.deviceNotFound }
        if result == Self.multipleDevices {
            throw MacroPadHIDError.multipleDevices(matchingDeviceCount())
        }
        guard result == Self.ok else { throw bridgeError(result) }
        return try MacroPadReportCodec.parseLED(report: Data(bytes))
    }

    public func readFullSnapshot() throws -> FullDeviceSnapshot {
        let device = try discover()
        guard device.connected else { throw MacroPadHIDError.deviceNotFound }
        let layers = try MacroPadIdentity.layerIDs.map(readLayer)
        return FullDeviceSnapshot(device: device, layers: layers, led: try readLED())
    }

    public func programSlot(
        layer: Int,
        slot: Int,
        expected: Data,
        replacement: Data
    ) throws -> DeviceMutationResult {
        guard MacroPadReportCodec.isValidCurrentReport(expected, layer: layer, slot: slot),
              MacroPadReportCodec.isValidCurrentReport(replacement, layer: layer, slot: slot) else {
            throw MacroPadProtocolError.incompatibleSlot(layer: layer, slot: slot)
        }
        var changed: Int32 = 0
        var reportsWritten: Int32 = 0
        var restoreAttempted: Int32 = 0
        var restoreVerified: Int32 = 0
        let result = expected.withUnsafeBytes { expectedBuffer in
            replacement.withUnsafeBytes { replacementBuffer in
                mp_hid_program_slot(
                    Int32(layer), Int32(slot),
                    expectedBuffer.bindMemory(to: UInt8.self).baseAddress, expectedBuffer.count,
                    replacementBuffer.bindMemory(to: UInt8.self).baseAddress, replacementBuffer.count,
                    &changed, &reportsWritten, &restoreAttempted, &restoreVerified)
            }
        }
        if result == Self.rollbackFailed { throw MacroPadHIDError.rollbackFailed }
        guard result == Self.ok else { throw bridgeError(result) }
        return DeviceMutationResult(
            changed: changed != 0,
            reportsWritten: Int(reportsWritten),
            restoreAttempted: restoreAttempted != 0,
            restoreVerified: restoreVerified != 0)
    }

    public func programLED(expected: LEDSnapshot, target: LEDSnapshot) throws -> DeviceMutationResult {
        guard expected.mode <= 5, target.mode <= 5,
              expected.colors.count == 12, target.colors.count == 12 else {
            throw MacroPadProtocolError.invalidLEDState
        }
        let expectedColors = expected.colors.flatMap { [$0.red, $0.green, $0.blue] }
        let targetColors = target.colors.flatMap { [$0.red, $0.green, $0.blue] }
        var changed: Int32 = 0
        var reportsWritten: Int32 = 0
        var restoreAttempted: Int32 = 0
        var restoreVerified: Int32 = 0
        let result = expectedColors.withUnsafeBufferPointer { expectedBuffer in
            targetColors.withUnsafeBufferPointer { targetBuffer in
                mp_hid_program_led(
                    expected.mode, expectedBuffer.baseAddress, expectedBuffer.count,
                    target.mode, targetBuffer.baseAddress, targetBuffer.count,
                    &changed, &reportsWritten, &restoreAttempted, &restoreVerified)
            }
        }
        if result == Self.rollbackFailed { throw MacroPadHIDError.rollbackFailed }
        guard result == Self.ok else { throw bridgeError(result) }
        return DeviceMutationResult(
            changed: changed != 0,
            reportsWritten: Int(reportsWritten),
            restoreAttempted: restoreAttempted != 0,
            restoreVerified: restoreVerified != 0)
    }

    private func string(from buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func matchingDeviceCount() -> Int {
        var count: Int32 = 0
        _ = mp_hid_discover(&count, nil, 0, nil, 0, nil, 0)
        return max(Int(count), 2)
    }

    private func bridgeError(_ result: Int32) -> MacroPadHIDError {
        let pointer = mp_hid_result_message(result)
        let message = pointer.map(String.init(cString:)) ?? "unknown_hid_error"
        return .bridge(code: result, message: message)
    }
}
