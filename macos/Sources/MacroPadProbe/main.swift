import Foundation
import MacroPadCore

private struct ProbeEnvelope<T: Encodable>: Encodable { let ok: Bool; let result: T }
private struct ErrorEnvelope: Encodable { let ok = false; let error: String }
private struct SelfTestSummary: Encodable { let passed: Int }
private struct BackupSummary: Encodable { let path: String; let checksum: String; let layers: Int }
private struct MutationSummary: Encodable { let changed: Bool; let reportsWritten: Int; let restored: Bool; let backupPath: String }
private struct RestoreSummary: Encodable { let changedSlots: Int; let ledChanged: Bool; let recoveryBackupPath: String }
private struct SelfTestFailure: LocalizedError {
    let check: String
    var errorDescription: String? { "self_test_failed: \(check)" }
}

private func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) { print(text) }
}

private func require(_ condition: @autoclosure () -> Bool, _ check: String) throws {
    if !condition() { throw SelfTestFailure(check: check) }
}

private func makeValidSlot(layer: Int, slot: Int, codes: [UInt8]) -> Data {
    var report = [UInt8](repeating: 0, count: MacroPadReportCodec.inputReportLength)
    report[0] = 0x03; report[1] = 0xFA; report[2] = UInt8(slot)
    report[3] = UInt8(layer); report[4] = 0x01; report[6] = UInt8(codes.count)
    for (index, code) in codes.enumerated() { report[9 + index * 3] = code }
    for separator in stride(from: 11, through: 59, by: 3) { report[separator] = 0x32 }
    return Data(report)
}

private func makeSnapshot() throws -> FullDeviceSnapshot {
    let device = DeviceSnapshot(connected: true, matchingCount: 1, serial: "self-test", product: "test", transport: "USB")
    let layers = try MacroPadIdentity.layerIDs.map { layer -> LayerSnapshot in
        let reports = (1...MacroPadIdentity.slotCount).map { makeValidSlot(layer: layer, slot: $0, codes: [0x04]) }
        return try MacroPadReportCodec.parseLayer(layer: layer, reports: reports)
    }
    let blue = RGBColorValue(red: 0, green: 0, blue: 255)
    return FullDeviceSnapshot(device: device, layers: layers, led: LEDSnapshot(mode: 1, colors: Array(repeating: blue, count: 12)))
}

private func runSelfTest() throws -> SelfTestSummary {
    var passed = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) throws { try require(condition(), name); passed += 1 }
    let layerRequest = [UInt8](try MacroPadReportCodec.readLayerRequest(layer: 2))
    try check(layerRequest.count == 65 && Array(layerRequest.prefix(5)) == [0x03, 0xFA, 0x19, 0x00, 0x02], "layer_request")
    try check(Array([UInt8](MacroPadReportCodec.readLEDRequest()).prefix(3)) == [0x03, 0xFA, 0xB0], "led_request")
    let supported = HIDDeviceDescriptor(vendorID: 0x514C, productID: 0x8850, usagePage: 0xFF00, interfaceNumber: 0)
    let wrong = HIDDeviceDescriptor(vendorID: 0x514C, productID: 0x8850, usagePage: 0xFF00, interfaceNumber: 1)
    try check(DeviceSelection.select(from: [wrong]) == .none, "interface_filter")
    try check(DeviceSelection.select(from: [supported]) == .single(supported), "device_selection")
    let snapshot = try makeSnapshot()
    try check(snapshot.layers.allSatisfy { $0.slots.count == 25 }, "layer_parser")
    var invalid = [UInt8](makeValidSlot(layer: 3, slot: 21, codes: [0xF1, 0x04]))
    invalid[13] = 0x01
    try check(!MacroPadReportCodec.isValidCurrentReport(Data(invalid), layer: 3, slot: 21), "invalid_report")
    let shortcut = DeviceShortcut(modifierCodes: [0xF1, 0xF4], keyCode: 0x06)
    let encoded = try DeviceConfigurationCodec.encodeShortcut(shortcut, layer: 2, slot: 17)
    let decodedShortcut = try DeviceConfigurationCodec.decodeShortcut(report: encoded, layer: 2, slot: 17)
    try check(decodedShortcut == shortcut, "shortcut_roundtrip")
    let disabled = DeviceShortcut(disabled: true)
    let disabledReport = try DeviceConfigurationCodec.encodeShortcut(disabled, layer: 1, slot: 1)
    let decodedDisabled = try DeviceConfigurationCodec.decodeShortcut(report: disabledReport, layer: 1, slot: 1)
    try check(decodedDisabled == disabled, "disabled_roundtrip")
    try check(Set(DeviceKeyCatalog.regularKeys.map(\.code)).count == DeviceKeyCatalog.regularKeys.count &&
        DeviceKeyCatalog.regularKeys.contains(where: { $0.id == "F24" && $0.code == 0x73 }), "key_catalog")
    try check(MacKeyCodeCatalog.cgKeyCode(hidCode: 0x06) == 8 &&
        MacKeyCodeCatalog.cgKeyCode(hidCode: 0x73) == nil &&
        !MacKeyCodeCatalog.regularKeys.contains(where: { $0.code == 0x73 }), "mac_app_key_support")
    let appKeymap = Data("""
    [{"command":"composer.decreaseReasoningEffort","key":"Ctrl+Command+Alt+F13"},
     {"command":"composer.increaseReasoningEffort","key":"Ctrl+Command+Alt+F17"}]
    """.utf8)
    let reasoningDown = try CodexAppKeybindings.shortcut(for: "reasoning_down", data: appKeymap)
    let reasoningUp = try CodexAppKeybindings.shortcut(for: "reasoning_up", data: appKeymap)
    try check(reasoningDown == DeviceShortcut(modifierCodes: [0xF1, 0xF3, 0xF4], keyCode: 0x68) &&
        reasoningUp == DeviceShortcut(modifierCodes: [0xF1, 0xF3, 0xF4], keyCode: 0x6C), "reasoning_uses_app_keymap")
    try check(CodexAppKeybindings.parseAccelerator("Control+Option+CmdOrCtrl+Left") ==
        DeviceShortcut(modifierCodes: [0xF1, 0xF3, 0xF4], keyCode: 0x50), "app_keymap_mac_modifiers")
    try check(["Ctrl+F24", "Ctrl", "Ctrl+", "Ctrl+Ctrl+F13", "Ctrl+K Ctrl+C", "Hyper+F13"]
        .allSatisfy { CodexAppKeybindings.parseAccelerator($0) == nil }, "unsupported_accelerators_rejected")
    for json in ["[]", "[{\"command\":\"composer.decreaseReasoningEffort\",\"key\":null}]", """
    [{"command":"composer.decreaseReasoningEffort","key":"F13"},
     {"command":"composer.decreaseReasoningEffort","key":null}]
    """] {
        do {
            _ = try CodexAppKeybindings.shortcut(for: "reasoning_down", data: Data(json.utf8))
            throw SelfTestFailure(check: "unassigned_reasoning_fails_closed")
        } catch CodexAppKeybindingError.unassignedCommand { passed += 1 }
    }
    for json in ["{}", "{", "[{\"command\":\"other.command\"}]"] {
        do {
            _ = try CodexAppKeybindings.shortcut(for: "reasoning_up", data: Data(json.utf8))
            throw SelfTestFailure(check: "invalid_app_keymap_rejected")
        } catch CodexAppKeybindingError.invalidFile { passed += 1 }
    }
    let alternateKeys = Data("""
    [{"command":"other.command","key":"F15"},
     {"command":"composer.increaseReasoningEffort","key":"Ctrl+F24"},
     {"command":"composer.increaseReasoningEffort","key":"Option+F18"}]
    """.utf8)
    let alternateShortcut = try CodexAppKeybindings.shortcut(for: "reasoning_up", data: alternateKeys)
    try check(alternateShortcut == DeviceShortcut(modifierCodes: [0xF3], keyCode: 0x6D),
        "app_keymap_supported_alternative")
    try check(CodexAppKeybindings.commandID(for: "reasoning_medium") == nil,
        "reasoning_cycle_is_not_medium")
    let appF24 = RoutedBinding(scope: .chatGPT, actionKind: .shortcut, shortcut: DeviceShortcut(keyCode: 0x73))
    do {
        _ = try BindingCompiler.compile(appF24, layer: 1, input: EditableInput.all[0])
        throw SelfTestFailure(check: "unsupported_app_key_rejected")
    } catch BindingCompilerError.unsupportedAppKey(0x73) { passed += 1 }
    let globalF24 = RoutedBinding(actionKind: .shortcut, shortcut: DeviceShortcut(keyCode: 0x73))
    if case .deviceDirect(let report) = try BindingCompiler.compile(globalF24, layer: 1, input: EditableInput.all[0]) {
        try check([UInt8](report)[9] == 0x73, "global_f24_preserved")
    } else { throw SelfTestFailure(check: "global_f24_preserved") }
    do {
        _ = try BindingCompiler.validate(RoutedBinding(
            scope: .chatGPT, actionKind: .shortcut, shortcut: DeviceShortcut(modifierCodes: [0xFF], keyCode: 0x06)))
        throw SelfTestFailure(check: "invalid_app_modifiers_rejected")
    } catch BindingCompilerError.invalidShortcut { passed += 1 }
    try check(LEDPalette.colors.count == 8 && LEDPalette.colors[4].value.hex == "#FF8030", "led_palette")
    let backupURL = FileManager.default.temporaryDirectory.appendingPathComponent("macropad-self-test-\(UUID().uuidString).json")
    let store = DeviceBackupStore(url: backupURL)
    let backup = try store.save(snapshot)
    let loadedBackup = try store.load()
    try check(loadedBackup == backup, "backup_roundtrip")
    var tampered = backup; tampered.checksum = String(repeating: "0", count: 64)
    do { try DeviceBackupStore.validate(tampered); throw SelfTestFailure(check: "backup_tamper") }
    catch DeviceBackupError.checksumMismatch { passed += 1 }

    let aliases = MacInputAliasCatalog.aliases
    try check(aliases.count == 54 && Set(aliases.map(\.cgKeyCode)).count == 54 &&
        Set(aliases.map(\.hidCode)).count == 54, "routing_alias_uniqueness")
    try check(aliases.allSatisfy { MacKeyCodeCatalog.cgKeyCode(hidCode: $0.hidCode) == $0.cgKeyCode },
        "routing_alias_dispatch_mapping")
    let alias = aliases[18]
    let aliasReport = try BindingCompiler.aliasReport(alias)
    let aliasBytes = [UInt8](aliasReport)
    try check(aliasBytes[6] == 4 && [aliasBytes[9], aliasBytes[12], aliasBytes[15], aliasBytes[18]] ==
        [0xF1, 0xF2, 0xF3, alias.hidCode], "routing_alias_report")
    let routedText = RoutedBinding(scope: .chatGPT, actionKind: .text, text: "hello\nworld")
    try check(AppAliasRoutingDecision.decide(binding: routedText, hasAliasModifiers: true,
        targetScope: nil, isRepeat: false) == .consume &&
        AppAliasRoutingDecision.decide(binding: routedText, hasAliasModifiers: true,
        targetScope: .codexCLI, isRepeat: false) == .consume, "alias_suppressed_outside_target")
    try check(AppAliasRoutingDecision.decide(binding: routedText, hasAliasModifiers: true,
        targetScope: .chatGPT, isRepeat: false) == .dispatch, "alias_dispatches_inside_target")
    try check(AppAliasRoutingDecision.decide(binding: routedText, hasAliasModifiers: true,
        targetScope: .chatGPT, isRepeat: true) == .consume, "alias_repeat_suppressed")
    try check(AppAliasRoutingDecision.decide(binding: nil, hasAliasModifiers: true,
        targetScope: .chatGPT, isRepeat: false) == .passThrough &&
        AppAliasRoutingDecision.decide(binding: routedText, hasAliasModifiers: false,
        targetScope: .chatGPT, isRepeat: false) == .passThrough, "ordinary_keys_pass_through")
    let compiledText = try BindingCompiler.compile(routedText, layer: alias.layer, input: alias.input)
    if case .appRouted(let report, let compiledAlias, _) = compiledText {
        try check(report == aliasReport && compiledAlias == alias, "routing_text_compile")
    } else { throw SelfTestFailure(check: "routing_text_compile") }
    do {
        _ = try BindingCompiler.compile(
            RoutedBinding(scope: .global, actionKind: .text, text: "blocked"),
            layer: 1, input: EditableInput.all[0])
        throw SelfTestFailure(check: "global_text_rejected")
    } catch BindingCompilerError.unsupportedKindForGlobal { passed += 1 }
    do {
        _ = try BindingCompiler.compile(
            RoutedBinding(scope: .codexCLI, actionKind: .builtIn, builtInActionID: "skills"),
            layer: 1, input: EditableInput.all[0])
        throw SelfTestFailure(check: "cross_scope_builtin_rejected")
    } catch BindingCompilerError.invalidBuiltIn { passed += 1 }
    let settingsDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("macropad-settings-self-test-\(UUID().uuidString)")
    let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
    let settingsStore = RoutingSettingsStore(url: settingsURL)
    var settings = RoutingSettings()
    settings.bindings[RoutingSettings.key(layer: alias.layer, input: alias.input)] = routedText
    try settingsStore.save(settings)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settingsURL.path)
    let loadedSettings = try settingsStore.load()
    try check(loadedSettings == settings, "routing_settings_roundtrip")
    let keymapURL = settingsDirectory.appendingPathComponent("keybindings.json")
    let keymapReader = CodexAppKeybindings(url: keymapURL)
    do {
        _ = try keymapReader.shortcut(for: "reasoning_down")
        throw SelfTestFailure(check: "missing_keymap_rejected")
    } catch CodexAppKeybindingError.unreadableFile { passed += 1 }
    for key in ["F13", "F14"] {
        let keymapData = Data("[{\"command\":\"composer.decreaseReasoningEffort\",\"key\":\"\(key)\"}]".utf8)
        try keymapData.write(to: keymapURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: keymapURL.path)
        let currentShortcut = try keymapReader.shortcut(for: "reasoning_down")
        let dataAfterRead = try Data(contentsOf: keymapURL)
        let permissionsAfterRead = try FileManager.default.attributesOfItem(atPath: keymapURL.path)[.posixPermissions] as? NSNumber
        try check(currentShortcut == CodexAppKeybindings.parseAccelerator(key), "app_keymap_reloaded")
        try check(dataAfterRead == keymapData && permissionsAfterRead?.intValue == 0o400,
            "app_keymap_not_modified")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keymapURL.path)
    }
    var legacySettings = settings
    legacySettings[1, EditableInput.all[0]] = appF24
    try settingsStore.save(legacySettings)
    let loadedLegacySettings = try settingsStore.load()
    try check(loadedLegacySettings == legacySettings, "unsupported_legacy_app_key_remains_editable")
    try settingsStore.save(settings)
    let recovered = BindingCompiler.binding(
        from: aliasReport, layer: alias.layer, input: alias.input, settings: settings)
    try check(recovered == routedText, "routing_settings_reconcile")
    let staleSettings = BindingCompiler.reconciledSettings(settings, snapshot: snapshot)
    try check(staleSettings.bindings[RoutingSettings.key(layer: alias.layer, input: alias.input)] == nil,
              "stale_routing_setting_removed")
    let permissions = try FileManager.default.attributesOfItem(atPath: settingsURL.path)[.posixPermissions] as? NSNumber
    try check(permissions?.intValue == 0o600, "routing_settings_permissions")
    let normalizedDisabled = RoutedBinding(
        scope: .chatGPT, actionKind: .disabled,
        shortcut: DeviceShortcut(keyCode: 0x04), text: "secret", builtInActionID: "copy")
        .normalizedForPersistence()
    try check(normalizedDisabled.text.isEmpty && normalizedDisabled.builtInActionID == nil &&
        normalizedDisabled.shortcut.disabled, "inactive_payloads_cleared")
    let overlayURL = settingsDirectory.appendingPathComponent("runtime-led.json")
    let overlayStore = RuntimeLEDOverlayStore(url: overlayURL)
    let overlay = RuntimeLEDOverlayState(active: true, base: snapshot.led)
    try overlayStore.save(overlay)
    let loadedOverlay = try overlayStore.load()
    try check(loadedOverlay == overlay, "runtime_led_state_roundtrip")
    let statusLED = LEDSnapshot(mode: 1, colors: Array(repeating: RGBColorValue(red: 0, green: 220, blue: 80), count: 12))
    let ownedOverlay = RuntimeLEDOverlayState(active: true, base: snapshot.led, overlay: statusLED)
    try check(ownedOverlay.restorationTarget(current: statusLED) == snapshot.led, "owned_overlay_restored")
    try check(ownedOverlay.restorationTarget(current: snapshot.led) == nil, "externally_changed_led_preserved")
    try check(RuntimeLEDOverlayState(active: false, base: snapshot.led, overlay: statusLED)
        .restorationTarget(current: statusLED) == nil, "inactive_overlay_does_not_write")
    try check(overlay.restorationTarget(current: statusLED) == nil, "legacy_overlay_fails_closed")
    let nextStatusLED = LEDSnapshot(mode: 1, colors: Array(repeating: RGBColorValue(red: 255, green: 190, blue: 0), count: 12))
    let transition = RuntimeLEDOverlayState(
        active: true, base: snapshot.led, overlay: nextStatusLED, previousOverlay: statusLED)
    try overlayStore.save(transition)
    let loadedTransition = try overlayStore.load()
    try check(loadedTransition == transition, "overlay_transition_persisted")
    try check(loadedTransition?.restorationTarget(current: statusLED) == snapshot.led,
        "overlay_transition_rollback_keeps_base")
    try check(loadedTransition?.restorationTarget(current: nextStatusLED) == snapshot.led,
        "overlay_transition_success_keeps_base")
    do {
        try MacroPadConfigurationService.requireUnchanged(snapshot.led, current: statusLED)
        throw SelfTestFailure(check: "stale_led_rejected")
    } catch ConfigurationServiceError.staleConfiguration { passed += 1 }
    do {
        try MacroPadConfigurationService.requireUnchanged(encoded, current: disabledReport)
        throw SelfTestFailure(check: "stale_slot_rejected")
    } catch ConfigurationServiceError.staleConfiguration { passed += 1 }
    try MacroPadConfigurationService.requireUnchanged(snapshot.led, current: snapshot.led)
    passed += 1
    try MacroPadConfigurationService.requireUnchanged(nil, current: snapshot.led)
    passed += 1
    try? FileManager.default.removeItem(at: settingsDirectory)
    try check(BindingScope.allCases == [.global, .chatGPT, .codexCLI], "typeless_excluded")
    try check(AppTargetPolicy.scope(bundleIdentifier: "com.openai.codex", focusedWindowTitle: nil) == .chatGPT,
              "chatgpt_target")
    try check(AppTargetPolicy.scope(
        bundleIdentifier: "com.apple.Terminal",
        focusedWindowTitle: "Codex CLI - MacroPad Studio [mac-test]") == .codexCLI, "dedicated_cli_target")
    try check(AppTargetPolicy.scope(bundleIdentifier: "com.apple.Terminal", focusedWindowTitle: "zsh") == nil &&
              AppTargetPolicy.scope(bundleIdentifier: "com.apple.Terminal", focusedWindowTitle: nil) == nil &&
              AppTargetPolicy.scope(bundleIdentifier: "com.apple.Terminal", focusedWindowTitle: "Codex CLI - MacroPad Studio") == nil &&
              AppTargetPolicy.scope(bundleIdentifier: "com.apple.Terminal", focusedWindowTitle: "Codex CLI - MacroPad Studio [mac-test] extra") == nil &&
              AppTargetPolicy.scope(bundleIdentifier: "com.example.other", focusedWindowTitle: "Codex CLI - MacroPad Studio") == nil,
              "foreground_target_fail_closed")
    let hookCommand = "/Users/test/.codex/macropad-status-hook"
    let hookFixture = Data("""
    {"custom":{"keep":true},"hooks":{"SessionStart":[{"matcher":"keep","hooks":[{"type":"command","command":"other-helper","timeout":9}]}]}}
    """.utf8)
    let installedHooks = try CodexHookConfiguration.merged(
        data: hookFixture, command: hookCommand, install: true)
    let installedHookCount = try CodexHookConfiguration.ownedHandlerCount(
        data: installedHooks, command: hookCommand)
    try check(installedHookCount == 7, "hook_install_count")
    let installedObject = try JSONSerialization.jsonObject(with: installedHooks) as? [String: Any]
    let custom = installedObject?["custom"] as? [String: Bool]
    let sessionGroups = (installedObject?["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]
    try check(custom?["keep"] == true && sessionGroups?.count == 2, "hook_preserves_unrelated_config")
    let removedHooks = try CodexHookConfiguration.merged(
        data: installedHooks, command: hookCommand, install: false)
    let removedHookCount = try CodexHookConfiguration.ownedHandlerCount(
        data: removedHooks, command: hookCommand)
    try check(removedHookCount == 0, "hook_uninstall_owned_only")
    do {
        _ = try CodexHookConfiguration.merged(
            data: Data("{\"hooks\":{\"SessionStart\":{}}}".utf8),
            command: hookCommand, install: true)
        throw SelfTestFailure(check: "hook_malformed_rejected")
    } catch CodexHookConfigurationError.invalidEvent("SessionStart") { passed += 1 }
    var statusAggregator = CodexStatusAggregator()
    let statusInstance = "mac-status-test"
    let statusSession = "session-status"
    let turnA = CodexLifecycleEvent(
        eventName: "UserPromptSubmit", sessionID: statusSession,
        turnID: "turn-a", instanceID: statusInstance, isError: false)
    try check(statusAggregator.apply(turnA).status == .running, "status_running")
    let turnB = CodexLifecycleEvent(
        eventName: "UserPromptSubmit", sessionID: statusSession,
        turnID: "turn-b", instanceID: statusInstance, isError: false)
    _ = statusAggregator.apply(turnB)
    let staleStop = CodexLifecycleEvent(
        eventName: "Stop", sessionID: statusSession,
        turnID: "turn-a", instanceID: statusInstance, isError: false)
    let afterStaleStop = statusAggregator.apply(staleStop)
    try check(afterStaleStop.status == .running && afterStaleStop.activeSessionCount == 1,
              "status_rejects_stale_stop")
    let approval = CodexLifecycleEvent(
        eventName: "PermissionRequest", sessionID: statusSession,
        turnID: "turn-b", instanceID: statusInstance, isError: false)
    try check(statusAggregator.apply(approval).status == .approval, "status_approval")
    let stopB = CodexLifecycleEvent(
        eventName: "Stop", sessionID: statusSession,
        turnID: "turn-b", instanceID: statusInstance, isError: false)
    try check(statusAggregator.apply(stopB).status == .completed, "status_completed")
    _ = statusAggregator.apply(CodexLifecycleEvent(
        eventName: "UserPromptSubmit", sessionID: statusSession,
        turnID: "turn-c", instanceID: statusInstance, isError: false))
    let retired = statusAggregator.retire(instanceID: statusInstance)
    try check(retired.status == .completed && retired.activeSessionCount == 0, "status_instance_retirement")
    return SelfTestSummary(passed: passed)
}

private func backupStore(_ path: String?) -> DeviceBackupStore {
    path.map { DeviceBackupStore(url: URL(fileURLWithPath: $0)) } ?? DeviceBackupStore()
}

private func report(in snapshot: FullDeviceSnapshot, layer: Int, slot: Int) throws -> Data {
    guard let hex = snapshot.layers.first(where: { $0.layer == layer })?.slots.first(where: { $0.slot == slot })?.hex,
          let value = Data(hex: hex) else { throw SelfTestFailure(check: "snapshot_slot_missing") }
    return value
}

private func parseLED(mode: String, colorsHex: String) throws -> LEDSnapshot {
    guard let modeValue = UInt8(mode), modeValue <= 5,
          let bytes = Data(hex: colorsHex), bytes.count == 36 else { throw MacroPadProtocolError.invalidLEDState }
    let raw = [UInt8](bytes)
    return LEDSnapshot(mode: modeValue, colors: stride(from: 0, to: 36, by: 3).map {
        RGBColorValue(red: raw[$0], green: raw[$0 + 1], blue: raw[$0 + 2])
    })
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "discover"
let hid = MacroPadHID()

do {
    switch command {
    case "discover": printJSON(ProbeEnvelope(ok: true, result: try hid.discover()))
    case "read-layer":
        guard arguments.count == 2, let layer = Int(arguments[1]) else { throw MacroPadProtocolError.invalidLayer(-1) }
        printJSON(ProbeEnvelope(ok: true, result: try hid.readLayer(layer)))
    case "read-led": printJSON(ProbeEnvelope(ok: true, result: try hid.readLED()))
    case "backup":
        guard arguments.count <= 2 else { throw SelfTestFailure(check: "backup_arguments") }
        let store = backupStore(arguments.count == 2 ? arguments[1] : nil)
        let backup = try store.save(hid.readFullSnapshot())
        printJSON(ProbeEnvelope(ok: true, result: BackupSummary(path: store.url.path, checksum: backup.checksum, layers: 3)))
    case "program-slot":
        guard (5...6).contains(arguments.count), let layer = Int(arguments[1]), let slot = Int(arguments[2]),
              EditableInput.forSlot(slot) != nil, let expected = Data(hex: arguments[3]),
              let replacement = Data(hex: arguments[4]) else { throw SelfTestFailure(check: "program_slot_arguments") }
        let store = backupStore(arguments.count == 6 ? arguments[5] : nil)
        let before = try hid.readFullSnapshot(); _ = try store.save(before)
        guard try report(in: before, layer: layer, slot: slot) == expected else { throw MacroPadHIDError.bridge(code: 7, message: "stale_device_state") }
        let result = try hid.programSlot(layer: layer, slot: slot, expected: expected, replacement: replacement)
        printJSON(ProbeEnvelope(ok: true, result: MutationSummary(changed: result.changed, reportsWritten: result.reportsWritten, restored: false, backupPath: store.url.path)))
    case "program-led":
        guard (5...6).contains(arguments.count) else { throw SelfTestFailure(check: "program_led_arguments") }
        let expected = try parseLED(mode: arguments[1], colorsHex: arguments[2])
        let target = try parseLED(mode: arguments[3], colorsHex: arguments[4])
        let store = backupStore(arguments.count == 6 ? arguments[5] : nil)
        let before = try hid.readFullSnapshot(); _ = try store.save(before)
        guard before.led == expected else { throw MacroPadHIDError.bridge(code: 7, message: "stale_device_state") }
        let result = try hid.programLED(expected: expected, target: target)
        printJSON(ProbeEnvelope(ok: true, result: MutationSummary(changed: result.changed, reportsWritten: result.reportsWritten, restored: false, backupPath: store.url.path)))
    case "restore-backup":
        guard (arguments.count == 2 || arguments.count == 3),
              arguments.last == "--confirm-family-device" else {
            throw ConfigurationServiceError.identityConfirmationRequired
        }
        let path = arguments.count == 3 ? arguments[1] : nil
        let service = MacroPadConfigurationService(hid: hid, backupStore: backupStore(path))
        let result = try service.restoreLatestBackup(confirmFamilyDevice: true)
        printJSON(ProbeEnvelope(ok: true, result: RestoreSummary(changedSlots: result.changedSlots, ledChanged: result.ledChanged, recoveryBackupPath: result.recoveryBackupURL.path)))
    case "diagnostic-slot-rollback":
        guard (3...4).contains(arguments.count), let layer = Int(arguments[1]), let slot = Int(arguments[2]), EditableInput.forSlot(slot) != nil else { throw SelfTestFailure(check: "diagnostic_arguments") }
        let store = backupStore(arguments.count == 4 ? arguments[3] : nil)
        let baseline = try hid.readFullSnapshot(); _ = try store.save(baseline)
        let original = try report(in: baseline, layer: layer, slot: slot)
        let f24 = try DeviceConfigurationCodec.encodeShortcut(DeviceShortcut(keyCode: 0x73), layer: layer, slot: slot)
        let temporary = original == f24 ? try DeviceConfigurationCodec.encodeShortcut(DeviceShortcut(keyCode: 0x72), layer: layer, slot: slot) : f24
        _ = try hid.programSlot(layer: layer, slot: slot, expected: original, replacement: temporary)
        _ = try hid.programSlot(layer: layer, slot: slot, expected: temporary, replacement: original)
        guard try report(in: hid.readFullSnapshot(), layer: layer, slot: slot) == original else { throw ConfigurationServiceError.finalVerification }
        printJSON(ProbeEnvelope(ok: true, result: MutationSummary(changed: true, reportsWritten: 4, restored: true, backupPath: store.url.path)))
    case "diagnostic-led-rollback":
        guard arguments.count <= 2 else { throw SelfTestFailure(check: "diagnostic_led_arguments") }
        let store = backupStore(arguments.count == 2 ? arguments[1] : nil)
        let baseline = try hid.readFullSnapshot(); _ = try store.save(baseline)
        var colors = baseline.led.colors
        colors[0] = colors[0] == LEDPalette.colors[3].value ? LEDPalette.colors[0].value : LEDPalette.colors[3].value
        let temporary = LEDSnapshot(mode: baseline.led.mode, colors: colors)
        _ = try hid.programLED(expected: baseline.led, target: temporary)
        _ = try hid.programLED(expected: temporary, target: baseline.led)
        guard try hid.readLED() == baseline.led else { throw ConfigurationServiceError.finalVerification }
        printJSON(ProbeEnvelope(ok: true, result: MutationSummary(changed: true, reportsWritten: 6, restored: true, backupPath: store.url.path)))
    case "diagnostic-routing-alias-rollback":
        guard (3...4).contains(arguments.count), let layer = Int(arguments[1]), let slot = Int(arguments[2]),
              let input = EditableInput.forSlot(slot),
              let alias = MacInputAliasCatalog.alias(layer: layer, input: input) else {
            throw SelfTestFailure(check: "diagnostic_routing_alias_arguments")
        }
        let store = backupStore(arguments.count == 4 ? arguments[3] : nil)
        let baseline = try hid.readFullSnapshot(); _ = try store.save(baseline)
        let original = try report(in: baseline, layer: layer, slot: slot)
        let aliasReport = try BindingCompiler.aliasReport(alias)
        if original != aliasReport {
            _ = try hid.programSlot(layer: layer, slot: slot, expected: original, replacement: aliasReport)
            _ = try hid.programSlot(layer: layer, slot: slot, expected: aliasReport, replacement: original)
        }
        guard try hid.readFullSnapshot() == baseline else {
            throw ConfigurationServiceError.finalVerification
        }
        printJSON(ProbeEnvelope(ok: true, result: MutationSummary(
            changed: original != aliasReport, reportsWritten: original == aliasReport ? 0 : 4,
            restored: true, backupPath: store.url.path)))
    case "read-app-shortcuts":
        let keymap = CodexAppKeybindings()
        var shortcuts: [String: DeviceShortcut] = [:]
        for actionID in ["reasoning_down", "reasoning_up"] {
            shortcuts[actionID] = try keymap.shortcut(for: actionID)
        }
        printJSON(ProbeEnvelope(ok: true, result: shortcuts))
    case "self-test": printJSON(ProbeEnvelope(ok: true, result: try runSelfTest()))
    case "help", "--help", "-h":
        print("Usage: macropad-probe [discover | read-layer 1|2|3 | read-led | read-app-shortcuts | backup [path] | program-slot layer slot expectedHex replacementHex [backupPath] | program-led expectedMode expectedColorsHex targetMode targetColorsHex [backupPath] | restore-backup [path] --confirm-family-device | diagnostic-slot-rollback layer slot [backupPath] | diagnostic-routing-alias-rollback layer slot [backupPath] | diagnostic-led-rollback [backupPath] | self-test]")
    default: throw MacroPadHIDError.bridge(code: 64, message: "unsupported_command")
    }
} catch {
    printJSON(ErrorEnvelope(error: error.localizedDescription)); exit(1)
}
