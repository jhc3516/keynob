import Foundation

public enum MacroPadProtocolError: Error, Equatable, LocalizedError {
    case invalidLayer(Int)
    case invalidReportLength(Int)
    case invalidReportHeader
    case invalidSlot(Int)
    case duplicateSlot(Int)
    case incompatibleSlot(layer: Int, slot: Int)
    case invalidLEDState

    public var errorDescription: String? {
        switch self {
        case .invalidLayer(let layer): "지원하지 않는 레이어입니다: \(layer)"
        case .invalidReportLength(let length): "HID 보고서 길이가 올바르지 않습니다: \(length)"
        case .invalidReportHeader: "HID 보고서 헤더가 올바르지 않습니다."
        case .invalidSlot(let slot): "슬롯 번호가 올바르지 않습니다: \(slot)"
        case .duplicateSlot(let slot): "중복 슬롯을 받았습니다: \(slot)"
        case .incompatibleSlot(let layer, let slot): "레이어 \(layer)의 슬롯 \(slot)이 지원 형식과 다릅니다."
        case .invalidLEDState: "LED 상태 보고서가 올바르지 않습니다."
        }
    }
}

public enum MacroPadReportCodec {
    public static let inputReportLength = 64
    public static let outputReportLength = 65

    public static func readLayerRequest(layer: Int) throws -> Data {
        guard MacroPadIdentity.layerIDs.contains(layer) else {
            throw MacroPadProtocolError.invalidLayer(layer)
        }
        var bytes = [UInt8](repeating: 0, count: outputReportLength)
        bytes[0] = 0x03
        bytes[1] = 0xFA
        bytes[2] = 0x19
        bytes[4] = UInt8(layer)
        return Data(bytes)
    }

    public static func readLEDRequest() -> Data {
        var bytes = [UInt8](repeating: 0, count: outputReportLength)
        bytes[0] = 0x03
        bytes[1] = 0xFA
        bytes[2] = 0xB0
        return Data(bytes)
    }

    public static func parseLayer(layer: Int, reports: [Data]) throws -> LayerSnapshot {
        guard MacroPadIdentity.layerIDs.contains(layer) else {
            throw MacroPadProtocolError.invalidLayer(layer)
        }
        guard reports.count == MacroPadIdentity.slotCount else {
            throw MacroPadProtocolError.invalidReportLength(reports.count)
        }

        var slotsByNumber: [Int: Data] = [:]
        for report in reports {
            guard report.count == inputReportLength else {
                throw MacroPadProtocolError.invalidReportLength(report.count)
            }
            let bytes = [UInt8](report)
            guard bytes[0] == 0x03, bytes[1] == 0xFA, bytes[3] == UInt8(layer) else {
                throw MacroPadProtocolError.invalidReportHeader
            }
            let slot = Int(bytes[2])
            guard (1...MacroPadIdentity.slotCount).contains(slot) else {
                throw MacroPadProtocolError.invalidSlot(slot)
            }
            guard slotsByNumber[slot] == nil else {
                throw MacroPadProtocolError.duplicateSlot(slot)
            }
            slotsByNumber[slot] = report
        }

        for slot in aliasSlots where !isValidCurrentReport(slotsByNumber[slot]!, layer: layer, slot: slot) {
            throw MacroPadProtocolError.incompatibleSlot(layer: layer, slot: slot)
        }

        let slots = (1...MacroPadIdentity.slotCount).map { slot in
            LayerSlot(slot: slot, hex: slotsByNumber[slot]!.hexString)
        }
        return LayerSnapshot(layer: layer, slots: slots)
    }

    public static func parseLED(report: Data) throws -> LEDSnapshot {
        guard report.count == inputReportLength else {
            throw MacroPadProtocolError.invalidReportLength(report.count)
        }
        let bytes = [UInt8](report)
        guard bytes[0] == 0x03, bytes[1] == 0xFA, bytes[2] <= 0x05 else {
            throw MacroPadProtocolError.invalidLEDState
        }
        let colors = stride(from: 3, to: 39, by: 3).map { offset in
            RGBColorValue(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2])
        }
        return LEDSnapshot(mode: bytes[2], colors: colors)
    }

    public static func isValidCurrentReport(_ report: Data, layer: Int, slot: Int) -> Bool {
        guard report.count == inputReportLength else { return false }
        var bytes = [UInt8](report)
        guard bytes[5] <= 0x01 else { return false }
        bytes[5] = 0x00
        return isValidReplacementReport(Data(bytes), layer: layer, slot: slot)
    }

    public static func isValidReplacementReport(_ report: Data, layer: Int, slot: Int) -> Bool {
        guard report.count == inputReportLength,
              MacroPadIdentity.layerIDs.contains(layer),
              (1...MacroPadIdentity.slotCount).contains(slot) else { return false }
        let bytes = [UInt8](report)
        guard bytes[0] == 0x03,
              bytes[1] == 0xFA,
              bytes[2] == UInt8(slot),
              bytes[3] == UInt8(layer),
              bytes[4] == 0x01,
              bytes[5] == 0x00,
              bytes[7] == 0x00,
              bytes[8] == 0x00,
              bytes[60] == 0x00,
              bytes[61] == 0x00,
              bytes[62] == 0x00,
              bytes[63] == 0x00 else { return false }

        let count = Int(bytes[6])
        guard (1...5).contains(count) else { return false }
        var regularKeyCount = 0
        var seen = Set<UInt8>()

        for index in 0..<17 {
            let offset = 9 + index * 3
            let code = bytes[offset]
            guard bytes[offset + 1] == 0x00,
                  bytes[offset + 2] == 0x00 || bytes[offset + 2] == 0x32 else { return false }
            if index >= count {
                guard code == 0x00 else { return false }
                continue
            }
            if code == 0x00 {
                guard count == 1, index == 0 else { return false }
                continue
            }
            guard seen.insert(code).inserted else { return false }
            if (0xF1...0xF4).contains(code) { continue }
            guard isAllowedRegularKey(code) else { return false }
            regularKeyCount += 1
            guard regularKeyCount <= 1 else { return false }
        }
        return true
    }

    private static let aliasSlots = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
        16, 17, 18, 19, 20, 21
    ]

    private static func isAllowedRegularKey(_ code: UInt8) -> Bool {
        (0x04...0x31).contains(code) ||
            (0x33...0x57).contains(code) ||
            (0x59...0x63).contains(code) ||
            code == 0x65 ||
            (0x68...0x73).contains(code)
    }
}

extension Data {
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
