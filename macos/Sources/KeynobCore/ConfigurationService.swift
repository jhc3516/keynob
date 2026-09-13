import Foundation

public struct ConfigurationApplyResult: Sendable {
    public let mutation: DeviceMutationResult
    public let backupURL: URL
    public let snapshot: FullDeviceSnapshot
    public let previousReport: Data?

    public init(
        mutation: DeviceMutationResult,
        backupURL: URL,
        snapshot: FullDeviceSnapshot,
        previousReport: Data? = nil
    ) {
        self.mutation = mutation
        self.backupURL = backupURL
        self.snapshot = snapshot
        self.previousReport = previousReport
    }
}

public struct RoutingConfigurationApplyResult: Sendable {
    public let configuration: ConfigurationApplyResult
    public let settings: RoutingSettings
    public let binding: RoutedBinding
}

public struct ConfigurationRestoreResult: Sendable {
    public let changedSlots: Int
    public let ledChanged: Bool
    public let recoveryBackupURL: URL
    public let snapshot: FullDeviceSnapshot
}

public enum ConfigurationServiceError: Error, LocalizedError {
    case missingLayer(Int)
    case missingSlot(Int)
    case differentDevice
    case identityConfirmationRequired
    case reservedSlotsChanged
    case batchFailed(rollbackVerified: Bool, cause: String)
    case finalVerification
    case staleConfiguration

    public var errorDescription: String? {
        switch self {
        case .missingLayer(let layer): "레이어 \(layer) 백업이 없습니다."
        case .missingSlot(let slot): "슬롯 \(slot) 백업이 없습니다."
        case .differentDevice: "백업을 만든 장치와 현재 연결된 장치가 다릅니다."
        case .identityConfirmationRequired: "이 장치군의 시리얼은 고유하지 않습니다. 현재 연결된 한 대에 백업을 복원할지 명시적으로 확인해야 합니다."
        case .reservedSlotsChanged: "백업 이후 예약 슬롯이 바뀌어 안전하게 복원할 수 없습니다."
        case .batchFailed(let rollbackVerified, let cause):
            rollbackVerified ? "적용 실패 후 원복했습니다: \(cause)" : "적용과 원복 확인에 실패했습니다: \(cause)"
        case .finalVerification: "적용 후 전체 장치 상태가 목표와 일치하지 않습니다."
        case .staleConfiguration: "화면을 읽은 뒤 장치 설정이 바뀌었습니다. 새로 고침 후 다시 적용하세요."
        }
    }
}

public struct KeynobConfigurationService: Sendable {
    public let hid: KeynobHID
    public let backupStore: DeviceBackupStore

    public init(hid: KeynobHID = KeynobHID(), backupStore: DeviceBackupStore = DeviceBackupStore()) {
        self.hid = hid
        self.backupStore = backupStore
    }

    @discardableResult
    public func backupCurrent() throws -> DeviceBackup {
        try backupStore.save(hid.readFullSnapshot())
    }

    public func applyShortcut(
        layer: Int,
        input: EditableInput,
        shortcut: DeviceShortcut
    ) throws -> ConfigurationApplyResult {
        let replacement = try DeviceConfigurationCodec.encodeShortcut(shortcut, layer: layer, slot: input.slot)
        return try applyReport(layer: layer, input: input, replacement: replacement)
    }

    public func applyReport(
        layer: Int,
        input: EditableInput,
        replacement: Data,
        expectedReport: Data? = nil
    ) throws -> ConfigurationApplyResult {
        let before = try hid.readFullSnapshot()
        let expected = try report(in: before, layer: layer, slot: input.slot)
        try Self.requireUnchanged(expectedReport, current: expected)
        _ = try backupStore.save(before)
        guard KeynobReportCodec.isValidReplacementReport(
            replacement, layer: layer, slot: input.slot) else {
            throw KeynobProtocolError.incompatibleSlot(layer: layer, slot: input.slot)
        }
        let mutation = try hid.programSlot(
            layer: layer, slot: input.slot, expected: expected, replacement: replacement)
        do {
            let after = try hid.readFullSnapshot()
            guard try report(in: after, layer: layer, slot: input.slot) == replacement else {
                throw ConfigurationServiceError.finalVerification
            }
            return ConfigurationApplyResult(
                mutation: mutation, backupURL: backupStore.url,
                snapshot: after, previousReport: expected)
        } catch {
            var rollbackVerified = !mutation.changed
            if mutation.changed {
                rollbackVerified = (try? hid.programSlot(
                    layer: layer, slot: input.slot,
                    expected: replacement, replacement: expected)) != nil
            }
            throw ConfigurationServiceError.batchFailed(
                rollbackVerified: rollbackVerified, cause: error.localizedDescription)
        }
    }

    public func applyRoutedBinding(
        layer: Int,
        input: EditableInput,
        binding: RoutedBinding,
        settings: RoutingSettings,
        settingsStore: RoutingSettingsStore,
        expectedReport: Data? = nil
    ) throws -> RoutingConfigurationApplyResult {
        let normalizedBinding = binding.normalizedForPersistence()
        let compiled = try BindingCompiler.compile(normalizedBinding, layer: layer, input: input)
        let replacement: Data
        switch compiled {
        case .deviceDirect(let report): replacement = report
        case .appRouted(let report, _, _): replacement = report
        }
        let applied = try applyReport(
            layer: layer, input: input, replacement: replacement, expectedReport: expectedReport)
        var updated = settings
        updated.bindings[RoutingSettings.key(layer: layer, input: input)] = normalizedBinding
        do {
            try settingsStore.save(updated)
        } catch {
            var rollbackVerified = !applied.mutation.changed
            if applied.mutation.changed, let previous = applied.previousReport {
                do {
                    _ = try hid.programSlot(
                        layer: layer, slot: input.slot,
                        expected: replacement, replacement: previous)
                    rollbackVerified = try hid.readFullSnapshot().report(
                        layer: layer, slot: input.slot) == previous
                } catch { rollbackVerified = false }
            }
            throw ConfigurationServiceError.batchFailed(
                rollbackVerified: rollbackVerified,
                cause: "앱 설정 저장 실패: \(error.localizedDescription)")
        }
        return RoutingConfigurationApplyResult(
            configuration: applied, settings: updated, binding: normalizedBinding)
    }

    public func applyLED(_ target: LEDSnapshot, expectedLED: LEDSnapshot? = nil) throws -> ConfigurationApplyResult {
        let before = try hid.readFullSnapshot()
        try Self.requireUnchanged(expectedLED, current: before.led)
        _ = try backupStore.save(before)
        let mutation = try hid.programLED(expected: before.led, target: target)
        do {
            let after = try hid.readFullSnapshot()
            guard after.led == target else { throw ConfigurationServiceError.finalVerification }
            return ConfigurationApplyResult(mutation: mutation, backupURL: backupStore.url, snapshot: after)
        } catch {
            var rollbackVerified = !mutation.changed
            if mutation.changed {
                rollbackVerified = (try? hid.programLED(expected: target, target: before.led)) != nil
            }
            throw ConfigurationServiceError.batchFailed(
                rollbackVerified: rollbackVerified, cause: error.localizedDescription)
        }
    }

    public func restoreLatestBackup(confirmFamilyDevice: Bool = false) throws -> ConfigurationRestoreResult {
        let targetBackup = try backupStore.load()
        let current = try hid.readFullSnapshot()
        guard sameDevice(current.device, targetBackup.snapshot.device) else {
            throw ConfigurationServiceError.differentDevice
        }
        guard confirmFamilyDevice else {
            throw ConfigurationServiceError.identityConfirmationRequired
        }
        guard reservedSlotsMatch(current, targetBackup.snapshot) else {
            throw ConfigurationServiceError.reservedSlotsChanged
        }
        let formatter = ISO8601DateFormatter()
        let safeTimestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let recoveryURL = backupStore.url.deletingLastPathComponent()
            .appendingPathComponent("pre-restore-\(safeTimestamp).json")
        _ = try DeviceBackupStore(url: recoveryURL).save(current)

        struct Applied { let layer: Int; let slot: Int; let original: Data; let target: Data }
        var applied: [Applied] = []
        do {
            for layer in KeynobIdentity.layerIDs {
                for input in EditableInput.all {
                    let original = try report(in: current, layer: layer, slot: input.slot)
                    let target = try report(in: targetBackup.snapshot, layer: layer, slot: input.slot)
                    if original == target { continue }
                    _ = try hid.programSlot(layer: layer, slot: input.slot, expected: original, replacement: target)
                    applied.append(Applied(layer: layer, slot: input.slot, original: original, target: target))
                }
            }
        } catch {
            var rollbackCallsSucceeded = true
            for item in applied.reversed() {
                do {
                    _ = try hid.programSlot(
                        layer: item.layer, slot: item.slot,
                        expected: item.target, replacement: item.original)
                } catch { rollbackCallsSucceeded = false }
            }
            let rollbackVerified = rollbackCallsSucceeded && fullStateMatches(
                try? hid.readFullSnapshot(), current)
            throw ConfigurationServiceError.batchFailed(
                rollbackVerified: rollbackVerified, cause: error.localizedDescription)
        }

        var ledChanged = false
        do {
            if current.led != targetBackup.snapshot.led {
                _ = try hid.programLED(expected: current.led, target: targetBackup.snapshot.led)
                ledChanged = true
            }
        } catch {
            var rollbackCallsSucceeded = true
            for item in applied.reversed() {
                do {
                    _ = try hid.programSlot(
                        layer: item.layer, slot: item.slot,
                        expected: item.target, replacement: item.original)
                } catch { rollbackCallsSucceeded = false }
            }
            let rollbackVerified = rollbackCallsSucceeded && fullStateMatches(
                try? hid.readFullSnapshot(), current)
            throw ConfigurationServiceError.batchFailed(
                rollbackVerified: rollbackVerified, cause: error.localizedDescription)
        }

        do {
            let after = try hid.readFullSnapshot()
            guard fullStateMatches(after, targetBackup.snapshot) else {
                throw ConfigurationServiceError.finalVerification
            }
            return ConfigurationRestoreResult(
                changedSlots: applied.count, ledChanged: ledChanged,
                recoveryBackupURL: recoveryURL, snapshot: after)
        } catch {
            var rollbackCallsSucceeded = true
            if ledChanged {
                do { _ = try hid.programLED(expected: targetBackup.snapshot.led, target: current.led) }
                catch { rollbackCallsSucceeded = false }
            }
            for item in applied.reversed() {
                do {
                    _ = try hid.programSlot(
                        layer: item.layer, slot: item.slot,
                        expected: item.target, replacement: item.original)
                } catch { rollbackCallsSucceeded = false }
            }
            let rollbackVerified = rollbackCallsSucceeded && fullStateMatches(
                try? hid.readFullSnapshot(), current)
            throw ConfigurationServiceError.batchFailed(
                rollbackVerified: rollbackVerified, cause: error.localizedDescription)
        }
    }

    public static func requireUnchanged<Value: Equatable>(_ expected: Value?, current: Value) throws {
        if let expected, expected != current { throw ConfigurationServiceError.staleConfiguration }
    }

    private func report(in snapshot: FullDeviceSnapshot, layer: Int, slot: Int) throws -> Data {
        guard let layerSnapshot = snapshot.layers.first(where: { $0.layer == layer }) else {
            throw ConfigurationServiceError.missingLayer(layer)
        }
        guard let hex = layerSnapshot.slots.first(where: { $0.slot == slot })?.hex,
              let data = Data(hex: hex) else { throw ConfigurationServiceError.missingSlot(slot) }
        return data
    }

    private func sameDevice(_ lhs: DeviceSnapshot, _ rhs: DeviceSnapshot) -> Bool {
        lhs.vendorID == rhs.vendorID && lhs.productID == rhs.productID &&
            lhs.usagePage == rhs.usagePage && lhs.interfaceNumber == rhs.interfaceNumber &&
            lhs.serial == rhs.serial
    }

    private func reservedSlotsMatch(_ lhs: FullDeviceSnapshot, _ rhs: FullDeviceSnapshot) -> Bool {
        let editable = Set(EditableInput.all.map(\.slot))
        for layer in KeynobIdentity.layerIDs {
            for slot in 1...KeynobIdentity.slotCount where !editable.contains(slot) {
                guard (try? report(in: lhs, layer: layer, slot: slot)) ==
                    (try? report(in: rhs, layer: layer, slot: slot)) else { return false }
            }
        }
        return true
    }

    private func fullStateMatches(_ lhs: FullDeviceSnapshot?, _ rhs: FullDeviceSnapshot) -> Bool {
        guard let lhs, lhs.led == rhs.led else { return false }
        for layer in KeynobIdentity.layerIDs {
            for slot in 1...KeynobIdentity.slotCount {
                guard (try? report(in: lhs, layer: layer, slot: slot)) ==
                    (try? report(in: rhs, layer: layer, slot: slot)) else { return false }
            }
        }
        return true
    }
}
