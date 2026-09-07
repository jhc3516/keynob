import Foundation

public enum MacroPadIdentity {
    public static let vendorID = 0x514C
    public static let productID = 0x8850
    public static let usagePage = 0xFF00
    public static let interfaceNumber = 0
    public static let slotCount = 25
    public static let layerIDs = 1...3
}

public struct HIDDeviceDescriptor: Equatable, Sendable {
    public let vendorID: Int
    public let productID: Int
    public let usagePage: Int
    public let interfaceNumber: Int?
    public let serial: String

    public init(
        vendorID: Int,
        productID: Int,
        usagePage: Int,
        interfaceNumber: Int?,
        serial: String = ""
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.usagePage = usagePage
        self.interfaceNumber = interfaceNumber
        self.serial = serial
    }

    public var isSupportedIdentity: Bool {
        vendorID == MacroPadIdentity.vendorID &&
            productID == MacroPadIdentity.productID &&
            usagePage == MacroPadIdentity.usagePage &&
            interfaceNumber == MacroPadIdentity.interfaceNumber
    }
}

public enum DeviceSelection: Equatable, Sendable {
    case none
    case single(HIDDeviceDescriptor)
    case multiple(Int)

    public static func select(from devices: [HIDDeviceDescriptor]) -> DeviceSelection {
        let matches = devices.filter(\.isSupportedIdentity)
        if matches.isEmpty { return .none }
        if matches.count > 1 { return .multiple(matches.count) }
        return .single(matches[0])
    }
}

public struct DeviceSnapshot: Codable, Equatable, Sendable {
    public let connected: Bool
    public let matchingCount: Int
    public let vendorID: String
    public let productID: String
    public let usagePage: String
    public let interfaceNumber: Int
    public let serial: String
    public let product: String
    public let transport: String

    public init(
        connected: Bool,
        matchingCount: Int,
        serial: String = "",
        product: String = "",
        transport: String = ""
    ) {
        self.connected = connected
        self.matchingCount = matchingCount
        self.vendorID = String(format: "%04X", MacroPadIdentity.vendorID)
        self.productID = String(format: "%04X", MacroPadIdentity.productID)
        self.usagePage = String(format: "%04X", MacroPadIdentity.usagePage)
        self.interfaceNumber = MacroPadIdentity.interfaceNumber
        self.serial = serial
        self.product = product
        self.transport = transport
    }
}

public struct LayerSlot: Codable, Equatable, Sendable {
    public let slot: Int
    public let hex: String

    public init(slot: Int, hex: String) {
        self.slot = slot
        self.hex = hex
    }
}

public struct LayerSnapshot: Codable, Equatable, Sendable {
    public let layer: Int
    public let slots: [LayerSlot]

    public init(layer: Int, slots: [LayerSlot]) {
        self.layer = layer
        self.slots = slots
    }
}

public struct RGBColorValue: Codable, Equatable, Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }
}

public struct LEDSnapshot: Codable, Equatable, Sendable {
    public let mode: UInt8
    public let colors: [RGBColorValue]

    public init(mode: UInt8, colors: [RGBColorValue]) {
        self.mode = mode
        self.colors = colors
    }
}

public struct FullDeviceSnapshot: Codable, Equatable, Sendable {
    public let device: DeviceSnapshot
    public let layers: [LayerSnapshot]
    public let led: LEDSnapshot

    public init(device: DeviceSnapshot, layers: [LayerSnapshot], led: LEDSnapshot) {
        self.device = device
        self.layers = layers
        self.led = led
    }
}

public struct DeviceMutationResult: Equatable, Sendable {
    public let changed: Bool
    public let reportsWritten: Int
    public let restoreAttempted: Bool
    public let restoreVerified: Bool

    public init(
        changed: Bool,
        reportsWritten: Int,
        restoreAttempted: Bool,
        restoreVerified: Bool
    ) {
        self.changed = changed
        self.reportsWritten = reportsWritten
        self.restoreAttempted = restoreAttempted
        self.restoreVerified = restoreVerified
    }
}
