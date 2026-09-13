using System.Text;
using System.Text.Json.Nodes;
using Keynob;
using Keynob.Models;
using Keynob.Services;
using Key = System.Windows.Input.Key;

var testRoot = Path.Combine(Path.GetTempPath(), $"Keynob.SettingsTests-{Guid.NewGuid():N}");
var settingsPath = Path.Combine(testRoot, "settings.json");
Directory.CreateDirectory(testRoot);

try
{
    var store = new SettingsStore(settingsPath);
    var missing = await store.LoadAsync();
    Assert(missing.Ok && missing.IsDefault, "missing_file_returns_defaults");
    Assert(missing.Settings.SchemaVersion == 3, "default_schema_v3");
    Assert(missing.Settings.Layers.Count == 3 &&
        StudioSettingsCatalog.LayerIds.All(layer =>
            missing.Settings.GetLayerInputs(layer).Count == 18 &&
            missing.Settings.GetLayerInputs(layer).Values.All(binding =>
                binding.ActionKind == ActionKinds.Disabled)),
        "three_default_layers_have_18_disabled_inputs");
    Assert(missing.Settings.KeyColors.Count == 12, "default_key_color_count");
    Assert(StudioSettingsCatalog.LedColors.Select(color => color.Id).SequenceEqual(
        ["blue", "yellow", "green", "red", "orange", "cyan", "purple", "pink"]),
        "eight_led_color_palette");
    Assert(missing.Settings.RestoreKeyColorsAfterCodexCompletion,
        "base_colors_restore_after_completion_by_default");
    Assert(!missing.Settings.StartWithWindows, "startup_disabled_by_default");
    var differentSerialSettings = new StudioSettings
    {
        Device = new DeviceIdentity { Serial = "DIFFERENT_SERIAL" },
        Layers = missing.Settings.Layers,
        StatusColors = missing.Settings.StatusColors,
        KeyColors = missing.Settings.KeyColors
    };
    StudioSettingsCatalog.Validate(differentSerialSettings);
    Assert(true, "different_device_serial_is_allowed");
    var backupPath = Path.Combine(testRoot, "backups", "latest.json");
    var backupStore = new DeviceBackupStore(settingsPath, backupPath);
    var backupSlots = Enumerable.Range(1, 25).ToDictionary(slot => slot, slot =>
    {
        var report = new byte[64];
        report[0] = 0x03;
        report[1] = 0xFA;
        report[2] = checked((byte)slot);
        report[3] = 0x02;
        return Convert.ToHexString(report).ToLowerInvariant();
    });
    var savedBackup = await backupStore.SaveAsync(
        2, backupSlots, new DeviceLedSnapshot(1, new string('0', 72)), "SHARED_SERIAL");
    var loadedBackup = await backupStore.LoadAsync();
    Assert(loadedBackup is { Ok: true, Backup.Layer: 2 } &&
        loadedBackup.Backup.Slots.Count == 25 && loadedBackup.Backup.Led.Mode == 1 &&
        loadedBackup.Backup.Checksum == savedBackup.Checksum && !File.Exists(backupPath + ".tmp"),
        "device_backup_round_trip_and_atomic_cleanup");
    var tamperedBackup = JsonNode.Parse(await File.ReadAllTextAsync(backupPath))!.AsObject();
    tamperedBackup["reportedSerial"] = "TAMPERED";
    await File.WriteAllTextAsync(backupPath, tamperedBackup.ToJsonString());
    Assert((await backupStore.LoadAsync()) is { Ok: false, Error: "backup_checksum_mismatch" },
        "device_backup_checksum_rejects_tampering");
    Assert(StartupRegistrationService.BuildCommand(@"C:\Portable App\Keynob.exe") ==
        "\"C:\\Portable App\\Keynob.exe\" --background", "startup_command_is_quoted");
    var previousDataDirectory = Environment.GetEnvironmentVariable("CODEX_KEYBOARD_STUDIO_DATA_DIR");
    var isolatedDataDirectory = Path.Combine(testRoot, "isolated-data");
    try
    {
        Environment.SetEnvironmentVariable("CODEX_KEYBOARD_STUDIO_DATA_DIR", isolatedDataDirectory);
        Assert(new SettingsStore().SettingsPath == Path.Combine(isolatedDataDirectory, "settings.json"),
            "settings_data_directory_override");
    }
    finally
    {
        Environment.SetEnvironmentVariable("CODEX_KEYBOARD_STUDIO_DATA_DIR", previousDataDirectory);
    }

    Assert(InputAliasCatalog.All.Count == 54, "three_layer_alias_count");
    Assert(InputAliasCatalog.All.Select(alias => alias.VirtualKey).Distinct().Count() == 54,
        "layer_alias_virtual_keys_are_globally_unique");
    Assert(StudioSettingsCatalog.LayerIds.All(layer =>
        InputAliasCatalog.All.Where(alias => alias.Layer == layer).Select(alias => alias.Slot).Order().SequenceEqual(
            Enumerable.Range(1, 12).Concat(Enumerable.Range(16, 6)))),
        "alias_slots_match_hardware_in_each_layer");
    Assert(InputAliasCatalog.TryGetByVirtualKey(InputAliasCatalog.Left, out var knob1Left) &&
        knob1Left.InputId == "knob1_ccw", "alias_lookup");
    Assert(InputAliasCatalog.TryGetByInputId("key04", out var key04Alias) &&
        key04Alias.VirtualKey == InputAliasCatalog.F1 + 3, "alias_input_id_lookup");
    Assert(InputAliasCatalog.TryGetByInputId(2, "key01", out var layer2Key01Alias) &&
        InputAliasCatalog.TryGetByInputId(3, "key01", out var layer3Key01Alias) &&
        layer2Key01Alias.VirtualKey != key04Alias.VirtualKey &&
        layer3Key01Alias.VirtualKey != layer2Key01Alias.VirtualKey,
        "layer_specific_alias_lookup");

    var deduplicator = new InputDeduplicator(TimeSpan.FromMilliseconds(150));
    var firstInput = DateTimeOffset.Parse("2026-07-27T00:00:00Z");
    Assert(deduplicator.ShouldAccept("key01", firstInput), "dedupe_accepts_first");
    Assert(!deduplicator.ShouldAccept("key01", firstInput.AddMilliseconds(100)), "dedupe_rejects_same_within_window");
    Assert(deduplicator.ShouldAccept("key02", firstInput.AddMilliseconds(100)), "dedupe_accepts_different_input");
    Assert(deduplicator.ShouldAccept("key01", firstInput.AddMilliseconds(150)), "dedupe_accepts_window_boundary");

    Assert(ForegroundAppDetector.Classify("ChatGPT", null, null) == "chatgpt", "classify_chatgpt");
    Assert(ForegroundAppDetector.Classify("Typeless", null, null) == "typeless", "classify_typeless");
    Assert(ForegroundAppDetector.Classify("codex", @"C:\Users\person\AppData\Roaming\npm\node_modules\@openai\codex\vendor\codex.exe", null) == "codex_cli", "classify_official_npm_codex_cli");
    Assert(ForegroundAppDetector.Classify("WindowsTerminal", null, "Codex CLI - Keynob") == "codex_cli", "classify_marked_terminal");
    Assert(ForegroundAppDetector.Classify("powershell", null, "Codex CLI - Keynob - project") == "codex_cli", "classify_marked_powershell");
    Assert(ForegroundAppDetector.Classify("codex", @"C:\Program Files\WindowsApps\OpenAI.Codex_1.0\app\resources\codex.exe", null) is null, "reject_codex_desktop_backend");
    Assert(ForegroundAppDetector.Classify("codex", @"C:\Tools\codex.exe", null) is null, "reject_unknown_codex_process");
    Assert(ForegroundAppDetector.Classify("WindowsTerminal", null, "Codex CLI") is null, "reject_generic_codex_title");
    Assert(ForegroundAppDetector.Classify("WindowsTerminal", null, "PowerShell") is null, "reject_unmarked_terminal");
    Assert(ForegroundAppDetector.Classify("notepad", null, "Codex CLI - Keynob") is null, "reject_unapproved_process");
    const string codexInstanceId = "0123456789abcdef0123456789abcdef";
    var markedCodexTitle = $"{ForegroundAppDetector.CodexCliWindowMarker} - {codexInstanceId}";
    Assert(ForegroundAppDetector.ParseCodexInstanceId(markedCodexTitle) == codexInstanceId,
        "parse_launcher_instance_id");
    Assert(ForegroundAppDetector.ClassifyForeground("WindowsTerminal", null, markedCodexTitle) is
    { TargetAppId: "codex_cli", CodexInstanceId: codexInstanceId, IsCodexTitleCandidate: true },
        "classify_launcher_instance");
    Assert(ForegroundAppDetector.ClassifyForeground("WindowsTerminal", null, "⠹ project") is
    { TargetAppId: null, IsTerminal: true, IsCodexTitleCandidate: true },
        "classify_codex_dynamic_title_candidate");
    Assert(ForegroundAppDetector.ClassifyForeground("WindowsTerminal", null, "project") is
    { TargetAppId: null, IsTerminal: true, IsCodexTitleCandidate: false },
        "reject_generic_terminal_title_candidate");
    Assert(ForegroundAppDetector.ParseCodexInstanceId(
        $"{ForegroundAppDetector.CodexCliWindowMarker} - not-a-guid") is null,
        "reject_invalid_launcher_instance_id");
    Assert(ForegroundAppDetector.IsTargetAvailable("typeless", null, typelessRunning: true), "typeless_available_globally_while_running");
    Assert(ForegroundAppDetector.IsTargetAvailable("typeless", "chatgpt", typelessRunning: true), "typeless_does_not_require_foreground");
    Assert(!ForegroundAppDetector.IsTargetAvailable("typeless", "typeless", typelessRunning: false), "typeless_blocked_when_not_running");
    Assert(ForegroundAppDetector.IsTargetAvailable("chatgpt", "chatgpt", typelessRunning: false), "chatgpt_requires_matching_foreground");
    Assert(!ForegroundAppDetector.IsTargetAvailable("chatgpt", "codex_cli", typelessRunning: true), "typeless_does_not_bypass_other_targets");
    Assert(StudioSettingsCatalog.GetActionKinds(BindingScopes.Typeless) is [{ Id: ActionKinds.Shortcut }] &&
        StudioSettingsCatalog.GetActionKinds(BindingScopes.ChatGpt)
            .Any(option => option.Id == ActionKinds.BuiltIn),
        "typeless_scope_only_offers_shortcut_action_kind");
    Assert(StudioSettingsCatalog.BuiltInActions.Count(action => action.Id == "copy") == 3, "safe_copy_available_for_allowed_apps_only");
    Assert(StudioSettingsCatalog.BuiltInActions.Any(action =>
        action is { Id: "reasoning_down", Scope: BindingScopes.CodexCli, Label: "추론 강도 낮추기" }) &&
        StudioSettingsCatalog.BuiltInActions.Any(action =>
            action is { Id: "reasoning_up", Scope: BindingScopes.CodexCli, Label: "추론 강도 높이기" }),
        "codex_reasoning_actions_available_in_builtin_catalog");
    var codexReasoningDown = new InputBinding
    {
        Scope = BindingScopes.CodexCli,
        ActionKind = ActionKinds.BuiltIn,
        BuiltInActionId = "reasoning_down"
    };
    Assert(BindingCompiler.Compile("knob1_ccw", codexReasoningDown).Delivery == BindingDelivery.AppRouted,
        "codex_reasoning_builtin_is_app_routed");
    var typelessBinding = new InputBinding
    {
        Scope = BindingScopes.Typeless,
        ActionKind = ActionKinds.Shortcut,
        Shortcut = new ShortcutDefinition { Modifiers = ["LeftCtrl", "LeftWin", "LeftAlt"] }
    };
    var typelessCompiled = BindingCompiler.Compile("key04", typelessBinding);
    Assert(typelessCompiled.Delivery == BindingDelivery.DeviceDirect, "typeless_shortcut_is_device_direct");
    Assert(DeviceReportEncoder.EncodeHex(typelessCompiled) ==
        "03fa04010100030000f10032f40032f3003200003200003200003200003200003200003200003200003200003200003200003200003200003200003200000000",
        "typeless_exact_report_has_no_f4");
    var scopedShortcut = new InputBinding
    {
        Scope = BindingScopes.ChatGpt,
        ActionKind = ActionKinds.Shortcut,
        Shortcut = new ShortcutDefinition { Modifiers = ["LeftCtrl"], Key = "G" }
    };
    var scopedCompiled = BindingCompiler.Compile("key01", scopedShortcut);
    Assert(scopedCompiled.Delivery == BindingDelivery.AppRouted &&
        scopedCompiled.DeviceKeys.SequenceEqual(["LeftCtrl", "LeftShift", "LeftAlt", "F1"]) &&
        DeviceReportEncoder.EncodeHex(scopedCompiled) ==
            "03fa01010100040000f10000f20000f300003a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "chatgpt_shortcut_uses_app_alias_on_device");
    var layer2ScopedCompiled = BindingCompiler.Compile(2, "key01", scopedShortcut);
    var layer3ScopedCompiled = BindingCompiler.Compile(3, "key01", scopedShortcut);
    Assert(layer2ScopedCompiled.DeviceKeys[^1] == "F13" &&
        layer3ScopedCompiled.DeviceKeys[^1] == "A" &&
        DeviceReportEncoder.Encode(layer2ScopedCompiled)[3] == 2 &&
        DeviceReportEncoder.Encode(layer3ScopedCompiled)[3] == 3,
        "app_alias_and_report_are_layer_specific");
    var commonKeyDefinitions = new Dictionary<string, (uint VirtualKey, byte DeviceCode)>(StringComparer.Ordinal)
    {
        ["Grave"] = (0xC0, 0x35),
        ["Minus"] = (0xBD, 0x2D),
        ["Equals"] = (0xBB, 0x2E),
        ["LeftBracket"] = (0xDB, 0x2F),
        ["RightBracket"] = (0xDD, 0x30),
        ["Backslash"] = (0xDC, 0x31),
        ["Semicolon"] = (0xBA, 0x33),
        ["Apostrophe"] = (0xDE, 0x34),
        ["Comma"] = (0xBC, 0x36),
        ["Period"] = (0xBE, 0x37),
        ["Slash"] = (0xBF, 0x38),
        ["CapsLock"] = (0x14, 0x39),
        ["PrintScreen"] = (0x2C, 0x46),
        ["ScrollLock"] = (0x91, 0x47),
        ["Pause"] = (0x13, 0x48),
        ["Menu"] = (0x5D, 0x65),
        ["NumLock"] = (0x90, 0x53),
        ["NumpadDivide"] = (0x6F, 0x54),
        ["NumpadMultiply"] = (0x6A, 0x55),
        ["NumpadSubtract"] = (0x6D, 0x56),
        ["NumpadAdd"] = (0x6B, 0x57),
        ["Numpad0"] = (0x60, 0x62),
        ["Numpad1"] = (0x61, 0x59),
        ["Numpad2"] = (0x62, 0x5A),
        ["Numpad3"] = (0x63, 0x5B),
        ["Numpad4"] = (0x64, 0x5C),
        ["Numpad5"] = (0x65, 0x5D),
        ["Numpad6"] = (0x66, 0x5E),
        ["Numpad7"] = (0x67, 0x5F),
        ["Numpad8"] = (0x68, 0x60),
        ["Numpad9"] = (0x69, 0x61),
        ["NumpadDecimal"] = (0x6E, 0x63)
    };
    foreach (var (name, codes) in commonKeyDefinitions)
    {
        Assert(ShortcutCatalog.SupportedKeyNames.Contains(name, StringComparer.Ordinal) &&
            ShortcutCatalog.TryGetVirtualKey(name, out var virtualKey) && virtualKey == codes.VirtualKey &&
            ShortcutCatalog.TryGetDeviceCode(name, out var deviceCode) && deviceCode == codes.DeviceCode,
            $"common_key_catalog_{name}");
        var binding = new InputBinding
        {
            Scope = BindingScopes.Global,
            ActionKind = ActionKinds.Shortcut,
            Shortcut = new ShortcutDefinition { Key = name }
        };
        var report = DeviceReportEncoder.Encode(BindingCompiler.Compile("key09", binding));
        Assert(report[9] == codes.DeviceCode &&
            DeviceReportEncoder.TryDecodeBinding("key09", Convert.ToHexString(report),
                missing.Settings.Inputs["key09"], out var decoded) &&
            decoded.Shortcut?.Key == name,
            $"common_key_device_round_trip_{name}");
    }
    Assert(BindingCompiler.Compile("key09", new InputBinding
    {
        Scope = BindingScopes.Global,
        ActionKind = ActionKinds.Shortcut,
        Shortcut = new ShortcutDefinition { Key = "Right" }
    }).DeviceKeys.SequenceEqual(["Right"]), "right_arrow_is_not_misclassified_as_right_modifier");
    var captureKeyMappings = new Dictionary<Key, string>
    {
        [Key.Oem3] = "Grave",
        [Key.OemMinus] = "Minus",
        [Key.OemPlus] = "Equals",
        [Key.Oem4] = "LeftBracket",
        [Key.Oem6] = "RightBracket",
        [Key.Oem5] = "Backslash",
        [Key.Oem1] = "Semicolon",
        [Key.Oem7] = "Apostrophe",
        [Key.OemComma] = "Comma",
        [Key.OemPeriod] = "Period",
        [Key.Oem2] = "Slash",
        [Key.CapsLock] = "CapsLock",
        [Key.PrintScreen] = "PrintScreen",
        [Key.Scroll] = "ScrollLock",
        [Key.Pause] = "Pause",
        [Key.Apps] = "Menu",
        [Key.NumLock] = "NumLock",
        [Key.Divide] = "NumpadDivide",
        [Key.Multiply] = "NumpadMultiply",
        [Key.Subtract] = "NumpadSubtract",
        [Key.Add] = "NumpadAdd",
        [Key.NumPad0] = "Numpad0",
        [Key.NumPad1] = "Numpad1",
        [Key.NumPad2] = "Numpad2",
        [Key.NumPad3] = "Numpad3",
        [Key.NumPad4] = "Numpad4",
        [Key.NumPad5] = "Numpad5",
        [Key.NumPad6] = "Numpad6",
        [Key.NumPad7] = "Numpad7",
        [Key.NumPad8] = "Numpad8",
        [Key.NumPad9] = "Numpad9",
        [Key.Decimal] = "NumpadDecimal"
    };
    Assert(captureKeyMappings.All(mapping => MainWindow.ToShortcutName(mapping.Key) == mapping.Value) &&
        MainWindow.ToShortcutName(Key.MediaPlayPause) is null,
        "common_key_recorder_mapping_and_media_exclusion");
    Assert(MainWindow.ResolveCaptureKey(Key.ImeProcessed, Key.None, Key.I) == Key.I,
        "shortcut_recorder_resolves_ime_processed_key");
    Assert(ShortcutCatalog.Format(new ShortcutDefinition { Modifiers = ["LeftShift"], Key = "Semicolon" }) ==
        "LeftShift + ;", "common_key_friendly_format");
    var supportGuideSections = ShortcutCatalog.GetSupportGuideSections();
    Assert(supportGuideSections.Count == 9 &&
        supportGuideSections.Select(section => section.Title).Distinct(StringComparer.Ordinal).Count() == 9 &&
        supportGuideSections.Single(section => section.Title == "문장부호").Keys.Contains("쉼표 ( , )", StringComparison.Ordinal) &&
        supportGuideSections.Single(section => section.Title == "문장부호").Keys.Contains("마침표 ( . )", StringComparison.Ordinal) &&
        supportGuideSections.Single(section => section.Title == "문장부호").Keys.Contains(" · ", StringComparison.Ordinal) &&
        supportGuideSections.Single(section => section.Title == "숫자 키패드").Keys.Contains("Num 9", StringComparison.Ordinal),
        "shortcut_support_guide_has_structured_categories");
    var globalSupportGuide = ShortcutCatalog.GetSupportGuide(BindingScopes.Global);
    var appSupportGuide = ShortcutCatalog.GetSupportGuide(BindingScopes.CodexCli);
    Assert(globalSupportGuide.Contains("문장부호:", StringComparison.Ordinal) &&
        globalSupportGuide.Contains("숫자 키패드:", StringComparison.Ordinal) &&
        globalSupportGuide.Contains("왼쪽 Ctrl·Shift·Win·Alt만", StringComparison.Ordinal) &&
        appSupportGuide.Contains("왼쪽과 오른쪽 보조키", StringComparison.Ordinal) &&
        appSupportGuide.Contains("볼륨·재생·브라우저 키", StringComparison.Ordinal),
        "shortcut_support_guide_matches_scope_limits");
    AssertShortcutGuideUi();
    var duplicateInputs = new Dictionary<string, InputBinding>(missing.Settings.Inputs, StringComparer.Ordinal)
    {
        ["key01"] = scopedShortcut,
        ["key02"] = new InputBinding
        {
            Scope = BindingScopes.ChatGpt,
            ActionKind = ActionKinds.Shortcut,
            Shortcut = new ShortcutDefinition { Modifiers = ["LeftCtrl"], Key = "G" }
        }
    };
    var duplicateSettings = new StudioSettings
    {
        Layers = StudioSettingsCatalog.ReplaceLayer(missing.Settings, 1, duplicateInputs).Layers,
        KeyColors = missing.Settings.KeyColors
    };
    await AssertThrowsAsync<InvalidDataException>(
        () => Task.Run(() => StudioSettingsCatalog.Validate(duplicateSettings)),
        "same_scope_duplicate_shortcut_rejected");
    duplicateInputs["key02"] = new InputBinding
    {
        Scope = BindingScopes.CodexCli,
        ActionKind = ActionKinds.Shortcut,
        Shortcut = new ShortcutDefinition { Modifiers = ["LeftCtrl"], Key = "G" }
    };
    var differentScopeSettings = StudioSettingsCatalog.ReplaceLayer(missing.Settings, 1, duplicateInputs);
    StudioSettingsCatalog.Validate(differentScopeSettings);
    Assert(true, "same_shortcut_in_different_scope_allowed");
    var layer2Inputs = new Dictionary<string, InputBinding>(missing.Settings.GetLayerInputs(2), StringComparer.Ordinal)
    {
        ["key01"] = scopedShortcut
    };
    var layer2Configured = StudioSettingsCatalog.ReplaceLayer(differentScopeSettings, 2, layer2Inputs);
    StudioSettingsCatalog.Validate(layer2Configured);
    var blankSettings = StudioSettingsCatalog.CreateBlankLayerFrom(layer2Configured, 1);
    Assert(blankSettings.Inputs.Values.All(binding => binding.ActionKind == ActionKinds.Disabled) &&
        blankSettings.GetLayerInputs(2)["key01"].ActionKind == ActionKinds.Shortcut &&
        blankSettings.GetLayerInputs(3).Values.All(binding => binding.ActionKind == ActionKinds.Disabled) &&
        blankSettings.KeyColors.SequenceEqual(layer2Configured.KeyColors) &&
        blankSettings.StatusColors == layer2Configured.StatusColors,
        "blank_configuration_changes_only_selected_layer");
    Assert(StudioSettingsCatalog.InputIds.Select(inputId =>
        DeviceReportEncoder.EncodeHex(BindingCompiler.Compile(inputId, missing.Settings.Inputs[inputId])))
        .All(hex => hex.Length == 128), "all_default_reports_encode");
    var disabledHex = DeviceReportEncoder.EncodeHex(BindingCompiler.Compile("key01", missing.Settings.Inputs["key01"]));
    Assert(disabledHex.StartsWith("03fa0101010001000000", StringComparison.Ordinal),
        "disabled_report_uses_active_slot_mode_and_null_key");
    Assert(DeviceReportEncoder.TryDecodeBinding("key01", disabledHex, missing.Settings.Inputs["key01"], out var disabledDecoded) &&
        disabledDecoded.ActionKind == ActionKinds.Disabled, "disabled_report_round_trip");
    var layer2DisabledSlots = StudioSettingsCatalog.InputIds.ToDictionary(
        inputId => InputAliasCatalog.All.First(alias => alias.Layer == 2 && alias.InputId == inputId).Slot,
        inputId => DeviceReportEncoder.EncodeHex(BindingCompiler.Compile(
            2,
            inputId,
            missing.Settings.GetLayerInputs(2)[inputId])));
    Assert(DeviceSettingsImporter.TryImport(
        missing.Settings, 2, layer2DisabledSlots, out var importedLayer2, out var importLayer2Error) &&
        importLayer2Error is null &&
        importedLayer2.Values.All(binding => binding.ActionKind == ActionKinds.Disabled),
        "layer2_device_import_stays_in_layer2");
    Assert(!DeviceReportEncoder.MatchesInputSlot(1, "key01", layer2DisabledSlots[1]) &&
        DeviceReportEncoder.MatchesInputSlot(2, "key01", layer2DisabledSlots[1]),
        "slot_report_rejects_wrong_layer");
    var unsupportedReport = disabledHex[..18] + "ff" + disabledHex[20..];
    Assert(!DeviceReportEncoder.IsSupportedReport("key01", unsupportedReport),
        "unsupported_original_report_rejected_before_batch_write");
    Assert(DeviceReportEncoder.TryDecodeBinding("key04", DeviceReportEncoder.EncodeHex(typelessCompiled),
        missing.Settings.Inputs["key04"], out var shortcutDecoded) &&
        shortcutDecoded.ActionKind == ActionKinds.Shortcut && shortcutDecoded.Shortcut?.Modifiers.Count == 3,
        "direct_shortcut_report_decodes");
    var knownV1 = StudioSettingsCatalog.CreateKnownV1From(missing.Settings);
    StudioSettingsCatalog.Validate(knownV1);
    var knownV1Slots = StudioSettingsCatalog.InputIds.ToDictionary(
        inputId => InputAliasCatalog.All.First(alias => alias.InputId == inputId).Slot,
        inputId => DeviceReportEncoder.EncodeHex(BindingCompiler.Compile(inputId, knownV1.Inputs[inputId])));
    Assert(DeviceSettingsImporter.TryImport(
        missing.Settings, knownV1Slots, out var importedV1, out var importV1Error) &&
        importV1Error is null && importedV1["key05"].BuiltInActionId == "diagnose" &&
        importedV1["key04"].Scope == BindingScopes.Typeless,
        "known_v1_device_layout_imports_semantics");
    Assert(DeviceReportEncoder.IsAppAliasReport("key01", knownV1Slots[1]) &&
        !DeviceReportEncoder.IsAppAliasReport("key04", knownV1Slots[4]),
        "app_alias_report_detection");
    var unresolvedAliasSlots = new Dictionary<int, string>(knownV1Slots)
    {
        [4] = DeviceReportEncoder.EncodeHex(BindingCompiler.Compile("key04", missing.Settings.Inputs["key04"]))
    };
    Assert(!DeviceSettingsImporter.TryImport(
        missing.Settings, unresolvedAliasSlots, out _, out var unresolvedAliasError) &&
        unresolvedAliasError == "unresolved_app_alias:key01",
        "isolated_app_alias_is_not_guessed");
    await AssertThrowsAsync<InvalidDataException>(() => Task.Run(() => BindingCompiler.Compile("key01", new InputBinding
    {
        Scope = BindingScopes.Global,
        ActionKind = ActionKinds.Shortcut,
        Shortcut = new ShortcutDefinition { Modifiers = ["RightCtrl"], Key = "C" }
    })), "direct_right_modifier_rejected_instead_of_changed");
    await AssertThrowsAsync<InvalidDataException>(() => Task.Run(() => BindingCompiler.Compile("key05", new InputBinding
    {
        Scope = BindingScopes.Global,
        ActionKind = ActionKinds.Shortcut,
        Shortcut = new ShortcutDefinition { Modifiers = ["LeftCtrl", "LeftShift", "LeftAlt"], Key = "F1" }
    })), "device_direct_reserved_alias_rejected");
    await AssertThrowsAsync<InvalidDataException>(() => Task.Run(() => BindingCompiler.Compile(3, "key05", new InputBinding
    {
        Scope = BindingScopes.Global,
        ActionKind = ActionKinds.Shortcut,
        Shortcut = new ShortcutDefinition { Modifiers = ["LeftCtrl", "LeftShift", "LeftAlt"], Key = "A" }
    })), "layer3_device_direct_reserved_alias_rejected");
    Assert(BluetoothDeviceDetector.ContainsTarget(
        [@"BTHLE\DEV_67C81CBF4C20\7&TEST", @"HID\VID_514C&PID_8850"]), "bluetooth_target_detected");
    Assert(!BluetoothDeviceDetector.ContainsTarget([@"BTHLE\DEV_ED82C2F137AE\7&OTHER"]), "other_bluetooth_rejected");
    Assert(InputActionDispatcher.NativeInputSize == (IntPtr.Size == 8 ? 40 : 28), "native_send_input_layout");
    Assert(InputActionDispatcher.GetKeyboardFlags(0xA3, keyUp: false) == 0x0001 &&
        InputActionDispatcher.GetKeyboardFlags(0x25, keyUp: true) == 0x0003 &&
        InputActionDispatcher.GetKeyboardFlags(0xA0, keyUp: true) == 0x0002 &&
        InputActionDispatcher.GetKeyboardFlags(0x2C, keyUp: false) == 0x0001 &&
        InputActionDispatcher.GetKeyboardFlags(0x5D, keyUp: true) == 0x0003 &&
        InputActionDispatcher.GetKeyboardFlags(0x6F, keyUp: false) == 0x0001 &&
        InputActionDispatcher.GetKeyboardFlags(0x90, keyUp: true) == 0x0003,
        "send_input_extended_key_flags");
    Assert(InputActionDispatcher.GetTypelessShortcut("dictation")?.SequenceEqual([0xA2u, 0x5Bu, 0xA4u]) == true,
        "typeless_dictation_uses_left_control_windows_alt");
    Assert(InputActionDispatcher.GetAliasReleaseKeys("key04").SequenceEqual([0x73u, 0x11u, 0x10u, 0x12u]),
        "typeless_dictation_releases_f4_alias_before_shortcut");
    Assert(InputActionDispatcher.GetAliasReleaseKeys(2, "key01").SequenceEqual([0x7Cu, 0x11u, 0x10u, 0x12u]) &&
        InputActionDispatcher.GetAliasReleaseKeys(3, "key01").SequenceEqual([0x41u, 0x11u, 0x10u, 0x12u]),
        "alias_release_keys_are_layer_specific");
    Assert(InputActionDispatcher.GetTypelessShortcut("translation")?.SequenceEqual([0x7Cu]) == true,
        "typeless_translation_keeps_f13");
    Assert(InputActionDispatcher.GetCodexCliShortcut("reasoning_down")?.SequenceEqual([0x12u, 0xBCu]) == true,
        "codex_reasoning_down_uses_alt_comma");
    Assert(InputActionDispatcher.GetCodexCliShortcut("reasoning_up")?.SequenceEqual([0x12u, 0xBEu]) == true,
        "codex_reasoning_up_uses_alt_period");
    Assert(InputActionDispatcher.GetCodexCliShortcut("unknown") is null,
        "codex_unknown_shortcut_action_rejected");
    var typelessTranslation = new InputBinding
    {
        Scope = BindingScopes.Typeless,
        ActionKind = ActionKinds.BuiltIn,
        BuiltInActionId = "translation"
    };
    Assert(BindingCompiler.Compile("key08", typelessTranslation).Delivery == BindingDelivery.AppRouted,
        "typeless_translation_builtin_preserves_v1_alias");
    Assert(InputActionDispatcher.GetTypelessShortcut("unknown") is null, "typeless_unknown_action_rejected");

    var batchCalls = new List<string>();
    var batchChanges = new[]
    {
        new DeviceSlotChange("key01", 1, "old1", "new1"),
        new DeviceSlotChange("key02", 2, "old2", "new2")
    };
    var batchFailure = await BatchProgramCoordinator.ApplyAsync(batchChanges, (change, rollback, _) =>
    {
        batchCalls.Add($"{change.InputId}:{(rollback ? "rollback" : "apply")}");
        var ok = rollback || change.InputId != "key02";
        return Task.FromResult(new InputProgramResult(ok, ok, ok, ok ? 2 : 0, ok ? change.ReplacementHex : null,
            ok ? null : "forced_failure"));
    });
    Assert(!batchFailure.Ok && batchFailure.RollbackVerified &&
        batchCalls.SequenceEqual(["key01:apply", "key02:apply", "key01:rollback"]),
        "batch_failure_rolls_back_prior_slots_in_reverse");
    var failedSlotRestoreCalls = new List<string>();
    var failedSlotRestoreFailure = await BatchProgramCoordinator.ApplyAsync(batchChanges, (change, rollback, _) =>
    {
        failedSlotRestoreCalls.Add($"{change.InputId}:{(rollback ? "rollback" : "apply")}");
        if (!rollback && change.InputId == "key02")
        {
            return Task.FromResult(new InputProgramResult(
                false, false, false, 0, null, "slot_commit_failed_restore_failed", true, false));
        }
        return Task.FromResult(new InputProgramResult(true, true, true, 2, change.ReplacementHex, null));
    });
    Assert(!failedSlotRestoreFailure.Ok && !failedSlotRestoreFailure.RollbackVerified &&
        failedSlotRestoreCalls.SequenceEqual(["key01:apply", "key02:apply", "key01:rollback"]),
        "batch_reports_failed_current_slot_restore");
    var noOpBatchCalls = 0;
    var noOpBatch = await BatchProgramCoordinator.ApplyAsync([], (_, _, _) =>
    {
        noOpBatchCalls++;
        return Task.FromResult(new InputProgramResult(true, false, true, 0, "", null));
    });
    Assert(noOpBatch.Ok && noOpBatch.ChangedSlots.Count == 0 && noOpBatchCalls == 0,
        "batch_noop_performs_no_writes");
    var settingsRestoreCalls = 0;
    var failedSettingsSave = await SettingsPersistenceCoordinator.SaveAsync(
        _ => throw new IOException("forced_settings_save_failure"),
        _ =>
        {
            settingsRestoreCalls++;
            return Task.FromResult(new BatchProgramResult(true, true, [1], null));
        });
    Assert(!failedSettingsSave.Saved && failedSettingsSave.RestoreAttempted &&
        failedSettingsSave.RestoreVerified && settingsRestoreCalls == 1,
        "settings_save_failure_restores_device_snapshot");
    var originalSnapshot = StudioSettingsCatalog.InputIds.ToDictionary(
        inputId => InputAliasCatalog.All.First(alias => alias.InputId == inputId).Slot,
        inputId => DeviceReportEncoder.EncodeHex(BindingCompiler.Compile(inputId, missing.Settings.Inputs[inputId])));
    var currentSnapshot = new Dictionary<int, string>(originalSnapshot)
    {
        [4] = DeviceReportEncoder.EncodeHex(typelessCompiled)
    };
    var restorePlan = DeviceBridgeClient.PlanSnapshotRestore(originalSnapshot, currentSnapshot);
    Assert(restorePlan is { Count: 1 } && restorePlan[0].InputId == "key04" &&
        restorePlan[0].OriginalHex == currentSnapshot[4] && restorePlan[0].ReplacementHex == originalSnapshot[4],
        "snapshot_restore_uses_exact_pre_apply_device_bytes");
    var factoryModeSnapshot = new Dictionary<int, string>(originalSnapshot)
    {
        [1] = originalSnapshot[1][..10] + "01" + originalSnapshot[1][12..]
    };
    var factoryModeRestorePlan = DeviceBridgeClient.PlanSnapshotRestore(factoryModeSnapshot, originalSnapshot);
    Assert(factoryModeRestorePlan is { Count: 1 } &&
        factoryModeRestorePlan[0].ReplacementHex == factoryModeSnapshot[1] &&
        DeviceReportEncoder.IsSupportedReport("key01", factoryModeSnapshot[1]),
        "snapshot_restore_preserves_factory_input_mode");
    var layer2CurrentSnapshot = new Dictionary<int, string>(layer2DisabledSlots)
    {
        [1] = DeviceReportEncoder.EncodeHex(layer2ScopedCompiled)
    };
    var layer2RestorePlan = DeviceBridgeClient.PlanSnapshotRestore(
        2,
        layer2DisabledSlots,
        layer2CurrentSnapshot);
    Assert(layer2RestorePlan is { Count: 1 } &&
        layer2RestorePlan[0].Layer == 2 && layer2RestorePlan[0].Slot == 1,
        "snapshot_restore_preserves_layer_identity");

    var capture = new ShortcutCaptureSession();
    capture.Begin();
    capture.KeyDown("LeftCtrl");
    capture.KeyDown("LeftCtrl");
    capture.KeyDown("C");
    var capturedChord = capture.KeyUp("C");
    Assert(capturedChord.State == ShortcutCaptureState.Completed &&
        ShortcutCatalog.Format(capturedChord.Shortcut) == "LeftCtrl + C", "recorder_deduplicates_repeat_keys");
    capture.Begin();
    capture.KeyDown("RightAlt");
    var modifierOnly = capture.KeyUp("RightAlt");
    Assert(modifierOnly.State == ShortcutCaptureState.Completed &&
        modifierOnly.Shortcut is { Key: null } modifierShortcut &&
        modifierShortcut.Modifiers.SequenceEqual(["RightAlt"]), "recorder_supports_right_modifier_only");
    capture.Begin();
    capture.KeyDown("Escape");
    var escapeOnly = capture.KeyUp("Escape");
    Assert(escapeOnly.State == ShortcutCaptureState.Completed &&
        ShortcutCatalog.Format(escapeOnly.Shortcut) == "Escape", "recorder_supports_escape");
    capture.Begin();
    capture.KeyDown("LeftCtrl");
    capture.KeyDown("Escape");
    var controlEscape = capture.KeyUp("Escape");
    Assert(controlEscape.State == ShortcutCaptureState.Completed &&
        ShortcutCatalog.Format(controlEscape.Shortcut) == "LeftCtrl + Escape", "recorder_supports_modified_escape");
    capture.Begin();
    capture.KeyDown("LeftCtrl");
    Assert(capture.Cancel().State == ShortcutCaptureState.Cancelled && !capture.IsRecording,
        "recorder_explicit_cancel_clears_pressed_keys");
    capture.Begin();
    capture.KeyDown("A");
    capture.KeyDown("B");
    Assert(capture.KeyUp("A").State == ShortcutCaptureState.Invalid, "recorder_rejects_multiple_regular_keys");

    var anyReleaseCompletes = new[] { "LeftCtrl", "LeftAlt", "I" }.All(releasedKey =>
    {
        capture.Begin();
        capture.KeyDown("LeftCtrl");
        capture.KeyDown("LeftAlt");
        capture.KeyDown("I");
        var update = capture.KeyUp(releasedKey);
        return update.State == ShortcutCaptureState.Completed &&
            ShortcutCatalog.Format(update.Shortcut) == "LeftCtrl + LeftAlt + I";
    });
    Assert(anyReleaseCompletes, "recorder_completes_chord_on_first_key_release");

    var aggregator = new CodexStatusAggregator();
    var statusTime = DateTimeOffset.Parse("2026-07-27T01:00:00Z");
    Assert(aggregator.Apply(new("SessionStart", "session-a", null, "instance-a"), statusTime).Status == "completed",
        "session_start_is_idle");
    Assert(aggregator.Apply(new("UserPromptSubmit", "session-a", "turn-a", "instance-a"), statusTime).Status == "running",
        "prompt_starts_running");
    Assert(aggregator.Apply(new("SessionEnd", "session-b", null, "instance-b"), statusTime).Status == "running",
        "running_beats_completed");
    Assert(aggregator.Apply(new("PermissionRequest", "session-b", "turn-b", "instance-b"), statusTime).Status == "approval",
        "approval_has_priority");
    Assert(aggregator.Apply(new("Stop", "session-a", "turn-a", "instance-a", IsError: true), statusTime).Status == "approval",
        "approval_beats_error");
    Assert(aggregator.Apply(new("PostToolUse", "session-b", "turn-b", "instance-b"), statusTime).Status == "error",
        "error_beats_running");
    Assert(aggregator.Apply(new("SessionEnd", "session-a", null, "instance-a"), statusTime).Status == "error",
        "sticky_error_survives_session_end");
    Assert(aggregator.Apply(new("Stop", "session-b", "turn-b", "instance-b"), statusTime).Status == "error",
        "existing_work_completion_does_not_clear_sticky_error");
    Assert(aggregator.Apply(new("UserPromptSubmit", "session-c", "turn-c", "instance-c"), statusTime.AddSeconds(1)).Status == "running",
        "new_prompt_clears_sticky_error");
    var sameTimestampError = new CodexStatusAggregator();
    sameTimestampError.Apply(new("UserPromptSubmit", "same-time-error", "turn-error", "instance-error"), statusTime);
    sameTimestampError.Apply(new("Stop", "same-time-error", "turn-error", "instance-error", IsError: true), statusTime);
    Assert(sameTimestampError.Apply(
            new("UserPromptSubmit", "same-time-new", "turn-new", "instance-new"), statusTime).Status == "running",
        "later_prompt_clears_sticky_error_even_when_clock_value_matches");
    var finalCompleted = aggregator.Apply(new("Stop", "session-c", "turn-c", "instance-c"), statusTime.AddSeconds(2));
    Assert(finalCompleted.Status == "completed" && finalCompleted.ActiveSessionCount == 0,
        "completed_has_zero_active_sessions");

    var multiCancellation = new CodexStatusAggregator();
    multiCancellation.Apply(new("UserPromptSubmit", "session-a", "turn-a", "instance-a",
        SourceKind: CodexStatusSourceKinds.DedicatedCli), statusTime);
    multiCancellation.Apply(new("UserPromptSubmit", "session-b", "turn-b", "instance-b",
        SourceKind: CodexStatusSourceKinds.DedicatedCli), statusTime);
    var candidateA = multiCancellation.BeginCancellation("instance-a", statusTime.AddMilliseconds(10));
    Assert(candidateA is { SessionId: "session-a", TurnId: "turn-a" }, "cancel_targets_foreground_instance");
    Assert(multiCancellation.BeginCancellation("instance-a", statusTime.AddMilliseconds(20)) is null,
        "repeated_cancel_is_deduplicated");
    var cancelledA = multiCancellation.CompleteCancellation(candidateA!, statusTime.AddMilliseconds(600));
    Assert(!cancelledA.Changed && cancelledA.ActivityChanged && cancelledA.Status == "running" &&
        cancelledA.ActiveSessionCount == 1,
        "other_running_session_keeps_blue_and_updates_active_count");
    Assert(multiCancellation.Apply(new("Stop", "session-b", "turn-b", "instance-b",
        SourceKind: CodexStatusSourceKinds.DedicatedCli), statusTime.AddSeconds(1)).Status == "completed",
        "all_sessions_complete_turns_green");

    var approvalCancellation = new CodexStatusAggregator();
    approvalCancellation.Apply(new("PermissionRequest", "approval-session", "approval-turn", "instance-a",
        SourceKind: CodexStatusSourceKinds.DedicatedCli), statusTime);
    approvalCancellation.Apply(new("UserPromptSubmit", "running-session", "running-turn", "instance-b",
        SourceKind: CodexStatusSourceKinds.DedicatedCli), statusTime);
    var approvalCandidate = approvalCancellation.BeginCancellation("instance-a", statusTime.AddMilliseconds(10));
    Assert(approvalCandidate is not null, "approval_turn_can_be_cancelled");
    Assert(approvalCancellation.CompleteCancellation(approvalCandidate!, statusTime.AddMilliseconds(600)).Status == "running",
        "cancelling_approval_reveals_other_running_session");

    var stopFirst = new CodexStatusAggregator();
    stopFirst.Apply(new("UserPromptSubmit", "stop-session", "stop-turn", "stop-instance",
        SourceKind: CodexStatusSourceKinds.DedicatedCli), statusTime);
    var stopCandidate = stopFirst.BeginCancellation("stop-instance", statusTime.AddMilliseconds(10));
    Assert(stopCandidate is not null, "stop_first_candidate_created");
    Assert(stopFirst.Apply(new("Stop", "stop-session", "stop-turn", "stop-instance",
        SourceKind: CodexStatusSourceKinds.DedicatedCli), statusTime.AddMilliseconds(100)).Status == "completed",
        "real_stop_completes_pending_cancel");
    Assert(!stopFirst.CompleteCancellation(stopCandidate!, statusTime.AddMilliseconds(600)).Changed,
        "fallback_is_noop_after_real_stop");
    Assert(stopFirst.Apply(new("PostToolUse", "stop-session", "stop-turn", "stop-instance",
        SourceKind: CodexStatusSourceKinds.DedicatedCli), statusTime.AddMilliseconds(700)).Status == "completed",
        "late_cancelled_turn_event_is_ignored");

    var newTurnRace = new CodexStatusAggregator();
    newTurnRace.Apply(new("UserPromptSubmit", "race-session", "old-turn", "race-instance",
        SourceKind: CodexStatusSourceKinds.DedicatedCli), statusTime);
    var oldCandidate = newTurnRace.BeginCancellation("race-instance", statusTime.AddMilliseconds(10));
    newTurnRace.Apply(new("UserPromptSubmit", "race-session", "new-turn", "race-instance",
        SourceKind: CodexStatusSourceKinds.DedicatedCli), statusTime.AddMilliseconds(100));
    Assert(!newTurnRace.CompleteCancellation(oldCandidate!, statusTime.AddMilliseconds(600)).Changed &&
        newTurnRace.CurrentStatus == "running", "old_timer_does_not_complete_new_turn");
    Assert(newTurnRace.Apply(new("Stop", "race-session", "old-turn", "race-instance",
        SourceKind: CodexStatusSourceKinds.DedicatedCli), statusTime.AddMilliseconds(700)).Status == "running",
        "late_old_stop_does_not_complete_new_turn");

    var instanceExit = new CodexStatusAggregator();
    instanceExit.Apply(new("UserPromptSubmit", "exit-a", "turn-a", "instance-a",
        SourceKind: CodexStatusSourceKinds.DedicatedCli), statusTime);
    instanceExit.Apply(new("UserPromptSubmit", "exit-b", "turn-b", "instance-b",
        SourceKind: CodexStatusSourceKinds.DedicatedCli), statusTime);
    Assert(instanceExit.BeginCancellation("instance-a", statusTime.AddMilliseconds(10)) is not null,
        "instance_exit_cancel_pending");
    Assert(instanceExit.Apply(new("InstanceEnd", null, null, "instance-a", IsError: true,
        SourceKind: CodexStatusSourceKinds.DedicatedCli), statusTime.AddMilliseconds(20)).Status == "running",
        "cancelled_instance_exit_does_not_turn_red");
    Assert(instanceExit.Apply(new("InstanceEnd", null, null, "instance-b", IsError: true,
        SourceKind: CodexStatusSourceKinds.DedicatedCli), statusTime.AddMilliseconds(30)).Status == "error",
        "uncancelled_abnormal_instance_exit_turns_red");

    var sameSessionDifferentWindows = new CodexStatusAggregator();
    sameSessionDifferentWindows.Apply(new("UserPromptSubmit", "shared-session", "turn-a", "instance-a",
        SourceKind: CodexStatusSourceKinds.DedicatedCli), statusTime);
    sameSessionDifferentWindows.Apply(new("UserPromptSubmit", "shared-session", "turn-b", "instance-b",
        SourceKind: CodexStatusSourceKinds.DedicatedCli), statusTime);
    var sharedCandidate = sameSessionDifferentWindows.BeginCancellation("instance-a", statusTime.AddMilliseconds(10));
    Assert(sharedCandidate is not null &&
        sameSessionDifferentWindows.CompleteCancellation(sharedCandidate, statusTime.AddMilliseconds(600)).Status == "running",
        "same_session_id_is_isolated_by_instance");

    var idleAggregator = new CodexStatusAggregator();
    var idleResult = idleAggregator.Apply(new("SessionStart", "idle-session", null, "idle-instance"), statusTime);
    Assert(idleResult.ActiveSessionCount == 0 && idleResult.ActiveSourceSummary == "none",
        "session_start_is_not_an_active_turn");
    Assert(idleAggregator.BeginCancellation("idle-instance", statusTime.AddMilliseconds(10)) is null &&
        idleAggregator.BeginCancellation("missing-instance", statusTime.AddMilliseconds(10)) is null,
        "idle_or_unknown_instance_does_not_cancel");

    var longRunning = new CodexStatusAggregator();
    longRunning.Apply(new("UserPromptSubmit", "long-session", "long-turn", "long-instance",
        SourceKind: CodexStatusSourceKinds.DedicatedCli), statusTime);
    var afterTwentyFiveHours = longRunning.EnsureCompleted(statusTime.AddHours(25));
    Assert(afterTwentyFiveHours.Status == "running" && afterTwentyFiveHours.ActiveSessionCount == 1,
        "active_turn_has_no_inactivity_ttl");

    var sourceLifetime = new FakeProducerLifetime();
    var sourcePolicy = new CodexStatusSourcePolicy(sourceLifetime);
    Assert(!sourcePolicy.Evaluate(new("UserPromptSubmit", "source-session", "source-turn")).Accepted,
        "unscoped_source_is_rejected");
    Assert(!sourcePolicy.Evaluate(new("UserPromptSubmit", "source-session", "source-turn", "manual-instance",
        SourceKind: CodexStatusSourceKinds.ManualTest, ProducerProcessId: 10)).Accepted,
        "manual_test_source_is_disabled_in_normal_runtime");
    var testSourcePolicy = new CodexStatusSourcePolicy(sourceLifetime, allowManualTestSource: true);
    Assert(testSourcePolicy.Evaluate(new("UserPromptSubmit", "source-session", "source-turn", "manual-instance",
        SourceKind: CodexStatusSourceKinds.ManualTest, ProducerProcessId: 10)).Accepted,
        "manual_test_source_is_allowed_only_in_explicit_test_runtime");
    Assert(!sourcePolicy.Evaluate(new("UserPromptSubmit", "source-session", "source-turn", "not-hex",
        LauncherProcessId: 10, SourceKind: CodexStatusSourceKinds.DedicatedCli)).Accepted,
        "dedicated_source_requires_launcher_instance_format");
    var sourceInstance = "0123456789abcdef0123456789abcdef";
    Assert(sourcePolicy.Evaluate(new("UserPromptSubmit", "source-session", "source-turn", sourceInstance,
        LauncherProcessId: 10, SourceKind: CodexStatusSourceKinds.DedicatedCli)).Accepted,
        "verified_dedicated_source_is_accepted");
    Assert(sourcePolicy.Evaluate(new("InstanceEnd", null, null, sourceInstance,
        SourceKind: CodexStatusSourceKinds.DedicatedCli)).Accepted,
        "registered_instance_end_is_accepted");
    Assert(!sourcePolicy.Evaluate(new("InstanceEnd", null, null, "fedcba9876543210fedcba9876543210",
        SourceKind: CodexStatusSourceKinds.DedicatedCli)).Accepted,
        "unregistered_instance_end_is_rejected");
    Assert(sourcePolicy.Evaluate(new("UserPromptSubmit", "json-session", "json-turn", "json-instance",
        SourceKind: CodexStatusSourceKinds.JsonExec, ProducerProcessId: 20)).Accepted,
        "verified_json_source_is_accepted");
    Assert(!sourcePolicy.Evaluate(new("UserPromptSubmit", "json-session", "json-turn", "json-instance",
        SourceKind: CodexStatusSourceKinds.JsonExec)).Accepted,
        "json_source_requires_producer_pid");

    Assert(CodexStatusPipeServer.IsValid(new("UserPromptSubmit", "pipe-session", "pipe-turn")),
        "pipe_accepts_well_shaped_unscoped_event_for_policy_filtering");
    Assert(!CodexStatusPipeServer.IsValid(new("UserPromptSubmit", "pipe-session", "pipe-turn", "unexpected")),
        "pipe_rejects_unscoped_event_with_identity_fields");
    Assert(CodexStatusPipeServer.IsValid(new("UserPromptSubmit", "pipe-session", "pipe-turn", sourceInstance,
        LauncherProcessId: 30, SourceKind: CodexStatusSourceKinds.DedicatedCli)),
        "pipe_accepts_complete_dedicated_shape");
    Assert(!CodexStatusPipeServer.IsValid(new("UserPromptSubmit", "pipe-session", "pipe-turn", sourceInstance,
        SourceKind: CodexStatusSourceKinds.DedicatedCli)),
        "pipe_rejects_dedicated_shape_without_launcher_pid");
    Assert(CodexStatusPipeServer.IsValid(new("UserPromptSubmit", "pipe-session", "pipe-turn", "json-instance",
        SourceKind: CodexStatusSourceKinds.JsonExec, ProducerProcessId: 40)),
        "pipe_accepts_complete_json_shape");
    Assert(!CodexStatusPipeServer.IsValid(new("UserPromptSubmit", "pipe-session", "pipe-turn", "json-instance",
        SourceKind: CodexStatusSourceKinds.JsonExec)),
        "pipe_rejects_json_shape_without_producer_pid");
    Assert(!CodexStatusPipeServer.IsValid(new("UserPromptSubmit", "pipe-session", "pipe-turn", "unknown-instance",
        SourceKind: "unknown", ProducerProcessId: 40)),
        "pipe_rejects_unknown_source_kind");
    Assert(CodexStatusPipeServer.IsValid(new("InstanceEnd", null, null, sourceInstance,
        SourceKind: CodexStatusSourceKinds.DedicatedCli)),
        "pipe_accepts_registered-shape_dedicated_terminal_for_policy_check");
    Assert(!CodexStatusPipeServer.IsValid(new("InstanceEnd", null, null, "json-instance",
        SourceKind: CodexStatusSourceKinds.JsonExec, ProducerProcessId: 40)),
        "pipe_rejects_json_terminal_event");

    var foregroundCodex = new ForegroundAppMatch("codex_cli", codexInstanceId);
    Assert(KeyboardHookService.CreateCodexCancellationRequest(0x1B, false, foregroundCodex) is
    { InstanceId: codexInstanceId, Gesture: "escape" }, "codex_escape_targets_instance");
    Assert(KeyboardHookService.CreateCodexCancellationRequest(0x43, true, foregroundCodex) is
    { InstanceId: codexInstanceId, Gesture: "ctrl_c" }, "codex_ctrl_c_targets_instance");
    Assert(KeyboardHookService.CreateCodexCancellationRequest(0x43, false, foregroundCodex) is null &&
        KeyboardHookService.CreateCodexCancellationRequest(0x1B, false, new("codex_cli", null)) is null &&
        KeyboardHookService.CreateCodexCancellationRequest(0x1B, false, new("chatgpt", codexInstanceId)) is null,
        "unidentified_or_unrelated_windows_do_not_cancel");

    var fakeLed = new FakeLedDevice();
    var ledCoordinator = new LedStateCoordinator(fakeLed);
    var repeatedWrites = await Task.WhenAll(Enumerable.Range(0, 100).Select(_ => ledCoordinator.ApplyColorAsync("blue")));
    Assert(repeatedWrites.All(result => result.Ok), "repeated_led_events_succeed");
    Assert(repeatedWrites.Count(result => result.Written) == 1 && fakeLed.WriteCount == 1, "repeated_led_events_write_once");
    Assert((await ledCoordinator.ApplyColorAsync("green")).Written && fakeLed.WriteCount == 2, "changed_led_writes_once");
    Assert((await ledCoordinator.ApplyColorAsync("orange")).Written && fakeLed.WriteCount == 3, "extended_led_color_writes_once");
    Assert(!(await ledCoordinator.ApplyColorAsync("black")).Ok && fakeLed.WriteCount == 3, "invalid_led_rejected_before_device");
    var mixedLayout = Enumerable.Repeat("blue", 12).ToArray();
    mixedLayout[11] = "red";
    Assert((await ledCoordinator.ApplyLayoutAsync(mixedLayout)).Written && fakeLed.WriteCount == 4, "mixed_led_layout_writes");
    Assert(!(await ledCoordinator.ApplyLayoutAsync(mixedLayout)).Written && fakeLed.WriteCount == 4, "same_layout_is_deduplicated");
    Assert(!(await ledCoordinator.ApplyLayoutAsync(["blue"])).Ok && fakeLed.WriteCount == 4, "wrong_layout_size_rejected");
    Assert(ledCoordinator.LastSuccessfulColors?.SequenceEqual(mixedLayout) == true,
        "last_successful_led_layout_is_available_for_rollback");
    ledCoordinator.Invalidate();
    Assert(ledCoordinator.LastSuccessfulColors is null &&
        (await ledCoordinator.ApplyLayoutAsync(mixedLayout)).Written && fakeLed.WriteCount == 5,
        "manual_restore_invalidates_led_deduplication_cache");

    Assert(LedDisplayPolicy.Decide(null, 0, true, true) ==
        new LedDisplayPlan(LedDisplayTarget.BaseLayout, false), "startup_without_status_uses_base_layout");
    Assert(LedDisplayPolicy.Decide("completed", 0, true, true) ==
        new LedDisplayPlan(LedDisplayTarget.BaseLayout, false), "usb_connection_uses_base_after_completion");
    Assert(LedDisplayPolicy.Decide("completed", 0, true, false) ==
        new LedDisplayPlan(LedDisplayTarget.StatusColor, true), "completion_previews_then_restores_base");
    Assert(LedDisplayPolicy.Decide("completed", 0, false, false) ==
        new LedDisplayPlan(LedDisplayTarget.StatusColor, false), "completion_can_remain_visible");
    Assert(LedDisplayPolicy.Decide("error", 0, true, false) ==
        new LedDisplayPlan(LedDisplayTarget.StatusColor, false), "sticky_error_overrides_base_layout");
    Assert(LedDisplayPolicy.Decide("running", 1, true, true) ==
        new LedDisplayPlan(LedDisplayTarget.StatusColor, false), "active_codex_overrides_usb_base_layout");
    Assert(UsbDeviceChangeMonitor.IsConnectionChangeMessage(0x0219, 0x8000) &&
        UsbDeviceChangeMonitor.IsConnectionChangeMessage(0x0219, 0x8004) &&
        !UsbDeviceChangeMonitor.IsConnectionChangeMessage(0x0219, 0x0007),
        "usb_arrival_and_removal_messages_are_detected");

    await store.SaveAsync(missing.Settings);
    Assert(File.Exists(settingsPath), "settings_file_created");
    Assert(!File.Exists(settingsPath + ".tmp"), "temporary_file_removed");

    var savedBytes = await File.ReadAllBytesAsync(settingsPath);
    var roundTrip = await store.LoadAsync();
    Assert(roundTrip.Ok && !roundTrip.IsDefault, "saved_file_loads");
    Assert(roundTrip.Settings.Inputs["knob2_cw"].ActionKind == ActionKinds.Disabled, "knob_rotation_round_trip");
    var savedV3Object = JsonNode.Parse(await File.ReadAllTextAsync(settingsPath))!.AsObject();
    var compatibleV2Json = new JsonObject
    {
        ["schemaVersion"] = 2,
        ["device"] = savedV3Object["device"]!.DeepClone(),
        ["inputs"] = savedV3Object["layers"]!["1"]!.DeepClone(),
        ["statusColors"] = savedV3Object["statusColors"]!.DeepClone(),
        ["keyColors"] = savedV3Object["keyColors"]!.DeepClone(),
        ["startWithWindows"] = savedV3Object["startWithWindows"]!.DeepClone()
    };
    compatibleV2Json["inputs"]!["key01"] = new JsonObject
    {
        ["scope"] = BindingScopes.Global,
        ["actionKind"] = ActionKinds.Shortcut,
        ["shortcut"] = new JsonObject
        {
            ["modifiers"] = new JsonArray("LeftCtrl", "LeftShift"),
            ["key"] = "K"
        }
    };
    compatibleV2Json["inputs"]!["key02"] = new JsonObject
    {
        ["scope"] = BindingScopes.CodexCli,
        ["actionKind"] = ActionKinds.Text,
        ["text"] = "v2 migration text"
    };
    compatibleV2Json["inputs"]!["key03"] = new JsonObject
    {
        ["scope"] = BindingScopes.ChatGpt,
        ["actionKind"] = ActionKinds.BuiltIn,
        ["builtInActionId"] = "previous_conversation"
    };
    await File.WriteAllTextAsync(settingsPath, compatibleV2Json.ToJsonString(), new UTF8Encoding(false));
    var compatibleV2 = await store.LoadAsync();
    Assert(compatibleV2.Ok && compatibleV2.WasMigrated &&
        compatibleV2.Settings.SchemaVersion == 3 &&
        compatibleV2.Settings.RestoreKeyColorsAfterCodexCompletion &&
        compatibleV2.Settings.GetLayerInputs(1)["key01"] is
            { Scope: BindingScopes.Global, ActionKind: ActionKinds.Shortcut, Shortcut.Key: "K" } &&
        compatibleV2.Settings.GetLayerInputs(1)["key01"].Shortcut!.Modifiers.SequenceEqual(["LeftCtrl", "LeftShift"]) &&
        compatibleV2.Settings.GetLayerInputs(1)["key02"] is
            { Scope: BindingScopes.CodexCli, ActionKind: ActionKinds.Text, Text: "v2 migration text" } &&
        compatibleV2.Settings.GetLayerInputs(1)["key03"] is
            { Scope: BindingScopes.ChatGpt, ActionKind: ActionKinds.BuiltIn,
                BuiltInActionId: "previous_conversation" } &&
        compatibleV2.Settings.GetLayerInputs(2).Values.All(binding => binding.ActionKind == ActionKinds.Disabled) &&
        compatibleV2.Settings.GetLayerInputs(3).Values.All(binding => binding.ActionKind == ActionKinds.Disabled),
        "existing_v2_settings_migrate_to_layer1_with_safe_defaults");
    var nullInputsV2Json = compatibleV2Json.DeepClone().AsObject();
    nullInputsV2Json["inputs"] = null;
    await File.WriteAllTextAsync(settingsPath, nullInputsV2Json.ToJsonString(), new UTF8Encoding(false));
    var nullInputsV2 = await store.LoadAsync();
    Assert(!nullInputsV2.Ok && nullInputsV2.Error == "invalid_v2_settings",
        "null_v2_inputs_are_rejected_without_crash");

    var customStatusColors = new StudioSettings
    {
        SchemaVersion = roundTrip.Settings.SchemaVersion,
        Device = roundTrip.Settings.Device,
        Layers = roundTrip.Settings.Layers,
        StatusColors = new StatusColorSettings
        {
            Running = "orange",
            Approval = "cyan",
            Completed = "purple",
            Error = "pink"
        },
        KeyColors = new Dictionary<string, string>(roundTrip.Settings.KeyColors, StringComparer.Ordinal)
        {
            ["key01"] = "pink"
        },
        RestoreKeyColorsAfterCodexCompletion = false,
        StartWithWindows = roundTrip.Settings.StartWithWindows
    };
    await store.SaveAsync(customStatusColors);
    var customStatusRoundTrip = await store.LoadAsync();
    Assert(customStatusRoundTrip.Ok && customStatusRoundTrip.Settings.StatusColors.Running == "orange" &&
        customStatusRoundTrip.Settings.StatusColors.Error == "pink" &&
        customStatusRoundTrip.Settings.KeyColors["key01"] == "pink" &&
        !customStatusRoundTrip.Settings.RestoreKeyColorsAfterCodexCompletion,
        "extended_led_colors_and_restore_policy_round_trip");

    var hookHome = Path.Combine(testRoot, "codex-home");
    var hookApp = Path.Combine(testRoot, "hook-app");
    Directory.CreateDirectory(hookHome);
    Directory.CreateDirectory(hookApp);
    var installedHookClient = Path.Combine(hookHome, "CodexStatusHookClient.exe");
    var packagedHookClient = Path.Combine(hookApp, "CodexStatusHookClient.exe");
    await File.WriteAllBytesAsync(packagedHookClient, [1, 2, 3, 4]);
    var hookConfigPath = Path.Combine(hookHome, "hooks.json");
    var hookFixture = new JsonObject
    {
        ["description"] = "preserve me",
        ["customTopLevel"] = "keep",
        ["hooks"] = new JsonObject
        {
            ["UserPromptSubmit"] = new JsonArray(new JsonObject
            {
                ["matcher"] = "keep matcher",
                ["hooks"] = new JsonArray(
                    new JsonObject { ["type"] = "command", ["command"] = "custom-user-hook.exe", ["timeout"] = 9 },
                    new JsonObject { ["type"] = "command", ["command"] = @"C:\other\CodexStatusHookClient.exe" },
                    new JsonObject { ["type"] = "command", ["command"] = "legacy-codex-status-hook.ps1" })
            }),
            ["PreCompact"] = new JsonArray(new JsonObject
            {
                ["hooks"] = new JsonArray(new JsonObject
                {
                    ["type"] = "command",
                    ["command"] = "custom-compact-hook.exe"
                })
            })
        }
    };
    await File.WriteAllTextAsync(hookConfigPath, hookFixture.ToJsonString(), new UTF8Encoding(false));
    var hookService = new CodexHookInstallationService(hookHome, hookApp);
    var firstHookInstall = await hookService.ApplyAsync(uninstall: false);
    var secondHookInstall = await hookService.ApplyAsync(uninstall: false);
    var installedHookJson = await File.ReadAllTextAsync(hookConfigPath);
    var installedHookBytes = await File.ReadAllBytesAsync(hookConfigPath);
    Assert(firstHookInstall.Ok && secondHookInstall.Ok && hookService.Inspect() is { Valid: true, HandlerCount: 7 },
        "native_hook_install_is_idempotent_without_powershell");
    Assert(installedHookJson.Contains("custom-user-hook.exe", StringComparison.Ordinal) &&
        installedHookJson.Contains(@"C:\\other\\CodexStatusHookClient.exe", StringComparison.Ordinal) &&
        installedHookJson.Contains("legacy-codex-status-hook.ps1", StringComparison.Ordinal) &&
        installedHookJson.Contains("custom-compact-hook.exe", StringComparison.Ordinal) &&
        installedHookJson.Contains("keep matcher", StringComparison.Ordinal) &&
        installedHookJson.Contains("\"customTopLevel\": \"keep\"", StringComparison.Ordinal),
        "native_hook_install_preserves_custom_hooks_and_metadata");
    Assert(!CodexHookInstallationService.HasUtf8Bom(installedHookBytes) &&
        !Directory.EnumerateFiles(hookHome, "*.tmp").Any(),
        "native_hook_install_writes_atomic_utf8_without_bom");
    var hookUninstall = await hookService.ApplyAsync(uninstall: true);
    var uninstalledHookJson = await File.ReadAllTextAsync(hookConfigPath);
    Assert(hookUninstall.Ok && !File.Exists(installedHookClient) &&
        uninstalledHookJson.Contains("custom-user-hook.exe", StringComparison.Ordinal) &&
        uninstalledHookJson.Contains(@"C:\\other\\CodexStatusHookClient.exe", StringComparison.Ordinal) &&
        uninstalledHookJson.Contains("legacy-codex-status-hook.ps1", StringComparison.Ordinal) &&
        uninstalledHookJson.Contains("custom-compact-hook.exe", StringComparison.Ordinal) &&
        !uninstalledHookJson.Contains(installedHookClient.Replace("\\", "\\\\", StringComparison.Ordinal), StringComparison.OrdinalIgnoreCase),
        "native_hook_uninstall_is_scoped_to_keynob_hooks");
    await File.WriteAllTextAsync(hookConfigPath, "{ invalid", new UTF8Encoding(false));
    var invalidHookBytes = await File.ReadAllBytesAsync(hookConfigPath);
    var invalidHookInstall = await hookService.ApplyAsync(uninstall: false);
    var preservedInvalidHookBytes = await File.ReadAllBytesAsync(hookConfigPath);
    Assert(!invalidHookInstall.Ok && invalidHookBytes.SequenceEqual(preservedInvalidHookBytes),
        "native_hook_install_preserves_invalid_existing_config");
    var invalidUtf8HookBytes = Encoding.ASCII.GetBytes("{\"hooks\":{},\"value\":\"")
        .Concat(new byte[] { 0xff }).Concat(Encoding.ASCII.GetBytes("\"}")).ToArray();
    await File.WriteAllBytesAsync(hookConfigPath, invalidUtf8HookBytes);
    var invalidUtf8HookInstall = await hookService.ApplyAsync(uninstall: false);
    var preservedInvalidUtf8HookBytes = await File.ReadAllBytesAsync(hookConfigPath);
    Assert(!invalidUtf8HookInstall.Ok && invalidUtf8HookBytes.SequenceEqual(preservedInvalidUtf8HookBytes),
        "native_hook_install_preserves_invalid_utf8_config");

    await File.WriteAllBytesAsync(installedHookClient, [1, 2, 3, 4]);
    var hooks = new JsonObject();
    foreach (var eventName in new[] { "SessionStart", "UserPromptSubmit", "PermissionRequest", "PreToolUse", "PostToolUse", "Stop", "SessionEnd" })
    {
        hooks[eventName] = new JsonArray(new JsonObject
        {
            ["hooks"] = new JsonArray(new JsonObject
            {
                ["type"] = "command",
                ["command"] = installedHookClient,
                ["timeout"] = 1
            })
        });
    }
    var hookJson = new JsonObject { ["hooks"] = hooks }.ToJsonString();
    await File.WriteAllTextAsync(hookConfigPath, hookJson, new UTF8Encoding(false));
    var hookInspection = new CodexHookInstallationService(hookHome, hookApp).Inspect();
    Assert(hookInspection.Valid && hookInspection.HandlerCount == 7, "hook_inspection_accepts_valid_install");
    var imbalancedHooks = JsonNode.Parse(hookJson)?.AsObject()
        ?? throw new InvalidOperationException("Hook fixture was not a JSON object.");
    imbalancedHooks["hooks"]!.AsObject().Remove("SessionEnd");
    imbalancedHooks["hooks"]!["Stop"]!.AsArray().Add(new JsonObject
    {
        ["hooks"] = new JsonArray(new JsonObject
        {
            ["type"] = "command",
            ["command"] = installedHookClient,
            ["timeout"] = 1
        })
    });
    await File.WriteAllTextAsync(hookConfigPath, imbalancedHooks.ToJsonString(), new UTF8Encoding(false));
    Assert(!new CodexHookInstallationService(hookHome, hookApp).Inspect().Valid, "hook_inspection_requires_one_handler_per_event");
    var bomHookJson = new UTF8Encoding(true).GetPreamble().Concat(Encoding.UTF8.GetBytes(hookJson)).ToArray();
    await File.WriteAllBytesAsync(hookConfigPath, bomHookJson);
    Assert(!new CodexHookInstallationService(hookHome, hookApp).Inspect().Valid, "hook_inspection_rejects_bom");
    Assert(CodexHookInstallationService.HasUtf8Bom(bomHookJson), "hook_bom_detected");
    File.Delete(installedHookClient);
    await File.WriteAllTextAsync(hookConfigPath, "{\"hooks\":{\"PreCompact\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"custom.exe\"}]}]}}", new UTF8Encoding(false));
    Assert(!new CodexHookInstallationService(hookHome, hookApp).Inspect().Installed, "unrelated_hooks_are_not_our_install");

    var invalidInputs = new Dictionary<string, InputBinding>(roundTrip.Settings.Inputs, StringComparer.Ordinal)
    {
        ["key01"] = new InputBinding { Scope = "shell", ActionKind = ActionKinds.Disabled }
    };
    var invalid = new StudioSettings
    {
        Layers = StudioSettingsCatalog.ReplaceLayer(roundTrip.Settings, 1, invalidInputs).Layers,
        Device = roundTrip.Settings.Device,
        StatusColors = roundTrip.Settings.StatusColors
    };
    var bytesBeforeInvalidSave = await File.ReadAllBytesAsync(settingsPath);
    await AssertThrowsAsync<InvalidDataException>(() => store.SaveAsync(invalid), "invalid_binding_rejected");
    var preservedBytes = await File.ReadAllBytesAsync(settingsPath);
    Assert(bytesBeforeInvalidSave.SequenceEqual(preservedBytes), "invalid_save_preserves_existing_file");

    var jsonWithUnknownField = Encoding.UTF8.GetString(savedBytes).Replace(
        "\"schemaVersion\": 3,",
        "\"schemaVersion\": 3,\n  \"unexpectedField\": true,",
        StringComparison.Ordinal);
    await File.WriteAllTextAsync(settingsPath, jsonWithUnknownField, new UTF8Encoding(false));
    var unknownField = await store.LoadAsync();
    Assert(!unknownField.Ok && !unknownField.IsDefault, "unknown_json_field_rejected");
    Assert(unknownField.Settings.Inputs.Count == 18, "invalid_file_falls_back_in_memory_only");

    var savedObject = JsonNode.Parse(savedBytes)?.AsObject()
        ?? throw new InvalidOperationException("Saved settings were not a JSON object.");
    var legacyInputs = new JsonObject();
    foreach (var inputId in StudioSettingsCatalog.InputIds)
    {
        legacyInputs[inputId] = new JsonObject
        {
            ["targetAppId"] = inputId == "key04" ? "typeless" : "chatgpt",
            ["actionId"] = inputId == "key04" ? "dictation" : "copy"
        };
    }
    var legacyJson = new JsonObject
    {
        ["schemaVersion"] = 1,
        ["device"] = savedObject["device"]!.DeepClone(),
        ["inputs"] = legacyInputs,
        ["statusColors"] = savedObject["statusColors"]!.DeepClone(),
        ["startWithWindows"] = false
    };
    await File.WriteAllTextAsync(settingsPath, legacyJson.ToJsonString(), new UTF8Encoding(false));
    var migrated = await store.LoadAsync();
    Assert(migrated.Ok && migrated.WasMigrated && migrated.Settings.SchemaVersion == 3 &&
        migrated.Settings.KeyColors.Count == 12 &&
        migrated.Settings.Inputs.Values.All(binding => binding.ActionKind == ActionKinds.BuiltIn) &&
        DeviceReportEncoder.EncodeHex(BindingCompiler.Compile("key04", migrated.Settings.Inputs["key04"])) ==
            DeviceReportEncoder.EncodeHex(typelessCompiled) &&
        migrated.Settings.GetLayerInputs(2).Values.All(binding => binding.ActionKind == ActionKinds.Disabled) &&
        migrated.Settings.GetLayerInputs(3).Values.All(binding => binding.ActionKind == ActionKinds.Disabled),
        "legacy_settings_migrate_to_v3_layer1");

    var nullInputsV1Json = legacyJson.DeepClone().AsObject();
    nullInputsV1Json["inputs"] = null;
    await File.WriteAllTextAsync(settingsPath, nullInputsV1Json.ToJsonString(), new UTF8Encoding(false));
    var nullInputsV1 = await store.LoadAsync();
    Assert(!nullInputsV1.Ok && nullInputsV1.Error == "invalid_legacy_settings",
        "null_v1_inputs_are_rejected_without_crash");

    var nullDeviceJson = JsonNode.Parse(savedBytes)?.AsObject()
        ?? throw new InvalidOperationException("Saved settings were not a JSON object.");
    nullDeviceJson["device"] = null;
    await File.WriteAllTextAsync(settingsPath, nullDeviceJson.ToJsonString(), new UTF8Encoding(false));
    var nullDevice = await store.LoadAsync();
    Assert(!nullDevice.Ok, "null_device_rejected_without_crash");

    var shortcutInputs = new Dictionary<string, InputBinding>(missing.Settings.Inputs, StringComparer.Ordinal)
    {
        ["key01"] = scopedShortcut
    };
    await store.SaveAsync(new StudioSettings
    {
        Layers = StudioSettingsCatalog.ReplaceLayer(missing.Settings, 1, shortcutInputs).Layers,
        KeyColors = missing.Settings.KeyColors
    });
    var nullModifiersJson = JsonNode.Parse(await File.ReadAllTextAsync(settingsPath))!.AsObject();
    nullModifiersJson["layers"]!["1"]!["key01"]!["shortcut"]!["modifiers"] = null;
    await File.WriteAllTextAsync(settingsPath, nullModifiersJson.ToJsonString(), new UTF8Encoding(false));
    var nullModifiers = await store.LoadAsync();
    Assert(!nullModifiers.Ok && nullModifiers.Error == "missing_shortcut_modifiers",
        "null_shortcut_modifiers_rejected_without_crash");

    Console.WriteLine("SETTINGS_TESTS_PASS schemaV3=True layers=3 defaultsDisabled=54 aliases=54 compiler=True duplicateShortcuts=True reservedAliases=True blankConfig=True directTypelessNoF4=True typelessTranslationCompat=True appRouting=True deviceImport=True extendedKeys=True commonKeyboardKeys=True supportGuide=True recorderSafety=True batchRollback=True snapshotRestore=True v1V2Migration=True atomicJson=True hookInspection=True ledRegression=True ledPalette=8 baseLedPolicy=True usbReconnect=True codexCancellation=True");
    return 0;
}
finally
{
    if (Directory.Exists(testRoot))
    {
        Directory.Delete(testRoot, true);
    }
}

static void Assert(bool condition, string name)
{
    if (!condition)
    {
        throw new InvalidOperationException($"Assertion failed: {name}");
    }
}

static async Task AssertThrowsAsync<TException>(Func<Task> action, string name)
    where TException : Exception
{
    try
    {
        await action();
    }
    catch (TException)
    {
        return;
    }
    throw new InvalidOperationException($"Expected {typeof(TException).Name}: {name}");
}

static void AssertShortcutGuideUi()
{
    Exception? failure = null;
    var thread = new Thread(() =>
    {
        try
        {
            var window = new MainWindow();
            var scope = (System.Windows.Controls.ComboBox)window.FindName("ScopeCombo");
            var actionKind = (System.Windows.Controls.ComboBox)window.FindName("ActionKindCombo");
            var shortcutPanel = (System.Windows.Controls.StackPanel)window.FindName("ShortcutEditorPanel");
            var guide = (System.Windows.Controls.TextBlock)window.FindName("ShortcutSupportGuideText");
            var guideGroups = (System.Windows.Controls.ItemsControl)window.FindName("ShortcutSupportGroupList");
            var guidePanel = (System.Windows.Controls.Border)window.FindName("ShortcutSupportGuidePanel");
            var layer1 = (System.Windows.Controls.Button)window.FindName("Layer1Button");
            var layer2 = (System.Windows.Controls.Button)window.FindName("Layer2Button");
            var layer3 = (System.Windows.Controls.Button)window.FindName("Layer3Button");
            var blankLayer = (System.Windows.Controls.Button)window.FindName("ApplyBlankConfigurationButton");
            var updateVisibility = typeof(MainWindow).GetMethod(
                "UpdateBindingEditorVisibility",
                System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)
                ?? throw new InvalidOperationException("shortcut_ui_update_method_missing");
            var setActionKindOptions = typeof(MainWindow).GetMethod(
                "SetActionKindOptions",
                System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)
                ?? throw new InvalidOperationException("action_kind_options_method_missing");

            scope.SelectedIndex = 0;
            actionKind.SelectedIndex = 1;
            updateVisibility.Invoke(window, null);
            var guideRow = (System.Windows.Controls.Border)guideGroups.ItemTemplate.LoadContent();
            var guideRowGrid = (System.Windows.Controls.Grid)guideRow.Child;
            var guideKeyText = guideRowGrid.Children.OfType<System.Windows.Controls.TextBlock>()
                .Single(text => System.Windows.Controls.Grid.GetColumn(text) == 1);
            Assert(shortcutPanel.Visibility == System.Windows.Visibility.Visible &&
                guide.Text.Contains("왼쪽 Ctrl·Shift·Win·Alt만", StringComparison.Ordinal) &&
                guideGroups.Items.Count == 9 && guideGroups.ItemTemplate is not null &&
                guidePanel.Padding.Top == 12 && guide.LineHeight == 18 &&
                guideKeyText.FontSize == 12 && guideKeyText.LineHeight == 20,
                "shortcut_support_guide_global_ui");

            scope.SelectedIndex = 1;
            updateVisibility.Invoke(window, null);
            Assert(guide.Text.Contains("왼쪽과 오른쪽 보조키", StringComparison.Ordinal),
                "shortcut_support_guide_app_ui");
            setActionKindOptions.Invoke(window, [BindingScopes.Typeless, ActionKinds.Shortcut]);
            Assert(actionKind.Items.Cast<ActionKindOption>().ToArray() is [{ Id: ActionKinds.Shortcut }],
                "typeless_ui_only_offers_shortcut_action_kind");
            var expander = shortcutPanel.Children.OfType<System.Windows.Controls.Expander>().Single();
            Assert((string)expander.Header == "지원 키 안내" && !expander.IsExpanded,
                "shortcut_support_guide_expander_contract");
            Assert((string)layer1.Tag == "1" && (string)layer2.Tag == "2" &&
                (string)layer3.Tag == "3" &&
                (string)blankLayer.Content == "현재 레이어 전체 비우기",
                "three_layer_selector_ui_contract");
            window.Close();
        }
        catch (Exception exception)
        {
            failure = exception;
        }
    });
    thread.SetApartmentState(ApartmentState.STA);
    thread.Start();
    if (!thread.Join(TimeSpan.FromSeconds(10)))
    {
        throw new TimeoutException("Shortcut support guide UI validation timed out.");
    }
    if (failure is not null)
    {
        throw new InvalidOperationException("Shortcut support guide UI validation failed.", failure);
    }
}

sealed class FakeProducerLifetime : ICodexProducerLifetime
{
    private readonly HashSet<(string SourceKind, string InstanceId)> _registrations = [];

    public bool TryObserve(string sourceKind, string instanceId, int processId)
    {
        if (processId <= 0)
        {
            return false;
        }
        _registrations.Add((sourceKind, instanceId));
        return true;
    }

    public bool IsRegistered(string sourceKind, string instanceId) =>
        _registrations.Contains((sourceKind, instanceId));
}

sealed class FakeLedDevice : ILedDevice
{
    public int WriteCount { get; private set; }

    public async Task<LedWriteResult> SetLedAsync(string color, CancellationToken cancellationToken = default)
    {
        await Task.Delay(2, cancellationToken);
        WriteCount++;
        return new(true, null);
    }

    public async Task<LedWriteResult> SetLedLayoutAsync(
        IReadOnlyList<string> colors,
        CancellationToken cancellationToken = default)
    {
        await Task.Delay(2, cancellationToken);
        WriteCount++;
        return new(true, null);
    }
}
