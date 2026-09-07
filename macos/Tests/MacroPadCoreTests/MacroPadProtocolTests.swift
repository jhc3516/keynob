import Foundation
import XCTest
@testable import MacroPadCore

final class MacroPadProtocolTests: XCTestCase {
    func testReadLayerRequestMatchesWindowsProtocol() throws {
        let bytes = [UInt8](try MacroPadReportCodec.readLayerRequest(layer: 2))
        XCTAssertEqual(bytes.count, 65)
        XCTAssertEqual(Array(bytes.prefix(5)), [0x03, 0xFA, 0x19, 0x00, 0x02])
        XCTAssertTrue(bytes.dropFirst(5).allSatisfy { $0 == 0 })
    }

    func testDeviceSelectionRequiresExactIdentity() {
        let supported = HIDDeviceDescriptor(
            vendorID: 0x514C,
            productID: 0x8850,
            usagePage: 0xFF00,
            interfaceNumber: 0,
            serial: "A")
        let wrongUsage = HIDDeviceDescriptor(
            vendorID: 0x514C,
            productID: 0x8850,
            usagePage: 0x0001,
            interfaceNumber: 0)
        let wrongInterface = HIDDeviceDescriptor(
            vendorID: 0x514C,
            productID: 0x8850,
            usagePage: 0xFF00,
            interfaceNumber: 1)
        let unknownInterface = HIDDeviceDescriptor(
            vendorID: 0x514C,
            productID: 0x8850,
            usagePage: 0xFF00,
            interfaceNumber: nil)

        XCTAssertEqual(DeviceSelection.select(from: [wrongUsage, wrongInterface, unknownInterface]), .none)
        XCTAssertEqual(DeviceSelection.select(from: [supported]), .single(supported))
        XCTAssertEqual(DeviceSelection.select(from: [supported, supported]), .multiple(2))
    }

    func testCurrentSlotValidationMatchesWindowsRules() {
        let report = makeValidSlot(layer: 3, slot: 21, codes: [0xF1, 0x04])
        XCTAssertTrue(MacroPadReportCodec.isValidCurrentReport(report, layer: 3, slot: 21))
        XCTAssertFalse(MacroPadReportCodec.isValidCurrentReport(report, layer: 2, slot: 21))

        var invalid = [UInt8](report)
        invalid[13] = 0x01
        XCTAssertFalse(MacroPadReportCodec.isValidCurrentReport(Data(invalid), layer: 3, slot: 21))
    }

    func testLayerParserRejectsDuplicateSlots() throws {
        var reports = (1...25).map { makeValidSlot(layer: 1, slot: $0, codes: [0x04]) }
        reports[24] = reports[0]
        XCTAssertThrowsError(try MacroPadReportCodec.parseLayer(layer: 1, reports: reports)) { error in
            XCTAssertEqual(error as? MacroPadProtocolError, .duplicateSlot(1))
        }
    }

    func testLayerParserAcceptsSupportedLayout() throws {
        let reports = (1...25).map { makeValidSlot(layer: 1, slot: $0, codes: [0x04]) }
        let snapshot = try MacroPadReportCodec.parseLayer(layer: 1, reports: reports)
        XCTAssertEqual(snapshot.layer, 1)
        XCTAssertEqual(snapshot.slots.count, 25)
        XCTAssertEqual(snapshot.slots.first?.slot, 1)
        XCTAssertEqual(snapshot.slots.last?.slot, 25)
    }

    func testLEDParserReadsTwelveColors() throws {
        var report = [UInt8](repeating: 0, count: 64)
        report[0] = 0x03
        report[1] = 0xFA
        report[2] = 0x01
        for index in 0..<12 {
            report[3 + index * 3] = UInt8(index)
            report[4 + index * 3] = UInt8(index + 1)
            report[5 + index * 3] = UInt8(index + 2)
        }
        let snapshot = try MacroPadReportCodec.parseLED(report: Data(report))
        XCTAssertEqual(snapshot.mode, 1)
        XCTAssertEqual(snapshot.colors.count, 12)
        XCTAssertEqual(snapshot.colors[0], RGBColorValue(red: 0, green: 1, blue: 2))
    }

    func testShortcutCodecMatchesWindowsDeviceDirectLayout() throws {
        let shortcut = DeviceShortcut(modifierCodes: [0xF1, 0xF4], keyCode: 0x06)
        let report = try DeviceConfigurationCodec.encodeShortcut(shortcut, layer: 2, slot: 17)
        let bytes = [UInt8](report)
        XCTAssertEqual(Array(bytes.prefix(7)), [0x03, 0xFA, 0x11, 0x02, 0x01, 0x00, 0x03])
        XCTAssertEqual([bytes[9], bytes[12], bytes[15]], [0xF1, 0xF4, 0x06])
        XCTAssertEqual(try DeviceConfigurationCodec.decodeShortcut(report: report, layer: 2, slot: 17), shortcut)
    }

    func testDisabledShortcutRoundTrips() throws {
        let disabled = DeviceShortcut(disabled: true)
        let report = try DeviceConfigurationCodec.encodeShortcut(disabled, layer: 3, slot: 21)
        XCTAssertEqual([UInt8](report)[6], 1)
        XCTAssertEqual([UInt8](report)[9], 0)
        XCTAssertEqual(try DeviceConfigurationCodec.decodeShortcut(report: report, layer: 3, slot: 21), disabled)
    }

    func testBackupRejectsChecksumTampering() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macropad-xctest-\(UUID().uuidString).json")
        let store = DeviceBackupStore(url: url)
        let device = DeviceSnapshot(connected: true, matchingCount: 1, serial: "test")
        let layers = try (1...3).map { layer in
            try MacroPadReportCodec.parseLayer(
                layer: layer,
                reports: (1...25).map { makeValidSlot(layer: layer, slot: $0, codes: [0x04]) })
        }
        let led = LEDSnapshot(
            mode: 1,
            colors: Array(repeating: RGBColorValue(red: 0, green: 0, blue: 255), count: 12))
        var backup = try store.save(FullDeviceSnapshot(device: device, layers: layers, led: led))
        XCTAssertEqual(try store.load(), backup)
        backup.checksum = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try DeviceBackupStore.validate(backup)) { error in
            XCTAssertEqual(error as? DeviceBackupError, .checksumMismatch)
        }
    }
}

private func makeValidSlot(layer: Int, slot: Int, codes: [UInt8]) -> Data {
    var report = [UInt8](repeating: 0, count: 64)
    report[0] = 0x03
    report[1] = 0xFA
    report[2] = UInt8(slot)
    report[3] = UInt8(layer)
    report[4] = 0x01
    report[6] = UInt8(codes.count)
    for (index, code) in codes.enumerated() {
        report[9 + index * 3] = code
    }
    for separator in stride(from: 11, through: 59, by: 3) {
        report[separator] = 0x32
    }
    return Data(report)
}
