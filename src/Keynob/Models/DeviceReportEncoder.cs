using System.IO;

namespace Keynob.Models;

public static class DeviceReportEncoder
{
    public static byte[] Encode(CompiledBinding binding)
    {
        if (!InputAliasCatalog.TryGetByInputId(binding.Layer, binding.InputId, out var alias))
        {
            throw new InvalidDataException("missing_input_alias");
        }

        var report = new byte[64];
        report[0] = 0x03;
        report[1] = 0xFA;
        report[2] = checked((byte)alias.Slot);
        report[3] = checked((byte)binding.Layer);
        report[4] = 0x01;

        if (binding.Delivery == BindingDelivery.Disabled)
        {
            report[6] = 0x01;
            return report;
        }

        var codes = binding.DeviceKeys.Select(key =>
            ShortcutCatalog.TryGetDeviceCode(key, out var code)
                ? code
                : throw new InvalidDataException("unsupported_device_key")).ToArray();
        if (codes.Length is < 1 or > 5)
        {
            throw new InvalidDataException("unsupported_device_chord_size");
        }
        report[6] = checked((byte)codes.Length);
        if (binding.Delivery == BindingDelivery.DeviceDirect)
        {
            for (var separator = 11; separator <= 59; separator += 3)
            {
                report[separator] = 0x32;
            }
        }
        for (var index = 0; index < codes.Length; index++)
        {
            report[9 + index * 3] = codes[index];
        }
        return report;
    }

    public static string EncodeHex(CompiledBinding binding) => Convert.ToHexString(Encode(binding)).ToLowerInvariant();

    public static bool MatchesInputSlot(string inputId, string hex)
        => MatchesInputSlot(1, inputId, hex);

    public static bool MatchesInputSlot(int layer, string inputId, string hex)
    {
        if (!InputAliasCatalog.TryGetByInputId(layer, inputId, out var alias) || hex.Length != 128)
        {
            return false;
        }
        try
        {
            var report = Convert.FromHexString(hex);
            return report[0] == 0x03 && report[1] == 0xFA && report[2] == alias.Slot &&
                report[3] == layer && report[4] == 0x01;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    public static bool MatchesBinding(string inputId, string hex, InputBinding binding)
        => MatchesBinding(1, inputId, hex, binding);

    public static bool MatchesBinding(int layer, string inputId, string hex, InputBinding binding)
    {
        try
        {
            return string.Equals(
                EncodeHex(BindingCompiler.Compile(layer, inputId, binding)),
                hex,
                StringComparison.OrdinalIgnoreCase);
        }
        catch (InvalidDataException)
        {
            return false;
        }
    }

    public static bool IsAppAliasReport(string inputId, string hex)
        => IsAppAliasReport(1, inputId, hex);

    public static bool IsAppAliasReport(int layer, string inputId, string hex)
    {
        var sample = new InputBinding
        {
            Scope = BindingScopes.ChatGpt,
            ActionKind = ActionKinds.Shortcut,
            Shortcut = new ShortcutDefinition { Modifiers = ["LeftCtrl"], Key = "C" }
        };
        return MatchesBinding(layer, inputId, hex, sample);
    }

    public static bool TryDecodeBinding(
        string inputId,
        string hex,
        InputBinding currentBinding,
        out InputBinding binding)
        => TryDecodeBinding(1, inputId, hex, currentBinding, out binding);

    public static bool TryDecodeBinding(
        int layer,
        string inputId,
        string hex,
        InputBinding currentBinding,
        out InputBinding binding)
    {
        binding = new InputBinding();
        if (!MatchesInputSlot(layer, inputId, hex)) return false;

        try
        {
            var current = BindingCompiler.Compile(layer, inputId, currentBinding);
            if (string.Equals(EncodeHex(current), hex, StringComparison.OrdinalIgnoreCase))
            {
                binding = currentBinding;
                return true;
            }
        }
        catch (InvalidDataException)
        {
            // Decode the device value independently when the saved value is invalid.
        }

        var report = Convert.FromHexString(hex);
        var count = report[6];
        if (count == 0 || (count == 1 && report[9] == 0))
        {
            binding = new InputBinding();
            return true;
        }
        if (count > 5) return false;

        var names = new List<string>(count);
        for (var index = 0; index < count; index++)
        {
            if (!ShortcutCatalog.TryGetNameFromDeviceCode(report[9 + index * 3], out var name)) return false;
            names.Add(name);
        }
        var modifiers = names.Where(ShortcutCatalog.IsModifier).ToList();
        var regularKeys = names.Where(name => !ShortcutCatalog.IsModifier(name)).ToArray();
        if (regularKeys.Length > 1) return false;
        var shortcut = new ShortcutDefinition { Modifiers = modifiers, Key = regularKeys.SingleOrDefault() };
        try
        {
            _ = ShortcutCatalog.Normalize(shortcut);
        }
        catch (InvalidDataException)
        {
            return false;
        }
        binding = new InputBinding
        {
            Scope = BindingScopes.Global,
            ActionKind = ActionKinds.Shortcut,
            Shortcut = shortcut
        };
        return true;
    }

    public static bool IsSupportedReport(string inputId, string hex) =>
        TryDecodeBinding(inputId, hex, new InputBinding(), out _);

    public static bool IsSupportedReport(int layer, string inputId, string hex) =>
        TryDecodeBinding(layer, inputId, hex, new InputBinding(), out _);

}

public static class DeviceSettingsImporter
{
    public static bool TryImport(
        StudioSettings currentSettings,
        IReadOnlyDictionary<int, string> slots,
        out IReadOnlyDictionary<string, InputBinding> inputs,
        out string? error)
        => TryImport(currentSettings, 1, slots, out inputs, out error);

    public static bool TryImport(
        StudioSettings currentSettings,
        int layer,
        IReadOnlyDictionary<int, string> slots,
        out IReadOnlyDictionary<string, InputBinding> inputs,
        out string? error)
    {
        inputs = new Dictionary<string, InputBinding>();
        error = null;
        var knownV1 = StudioSettingsCatalog.CreateKnownV1From(currentSettings);
        var knownV1Layout = layer == 1 && StudioSettingsCatalog.InputIds.All(inputId =>
            InputAliasCatalog.TryGetByInputId(layer, inputId, out var alias) &&
            slots.TryGetValue(alias.Slot, out var hex) &&
            DeviceReportEncoder.MatchesBinding(layer, inputId, hex, knownV1.Inputs[inputId]));

        var currentInputs = currentSettings.GetLayerInputs(layer);

        var imported = new Dictionary<string, InputBinding>(StringComparer.Ordinal);
        foreach (var inputId in StudioSettingsCatalog.InputIds)
        {
            if (!InputAliasCatalog.TryGetByInputId(layer, inputId, out var alias) ||
                !slots.TryGetValue(alias.Slot, out var hex))
            {
                error = $"missing_device_slot:{inputId}";
                return false;
            }
            if (knownV1Layout)
            {
                imported[inputId] = knownV1.Inputs[inputId];
                continue;
            }
            if (DeviceReportEncoder.MatchesBinding(layer, inputId, hex, currentInputs[inputId]))
            {
                imported[inputId] = currentInputs[inputId];
                continue;
            }
            if (DeviceReportEncoder.IsAppAliasReport(layer, inputId, hex))
            {
                error = $"unresolved_app_alias:{inputId}";
                return false;
            }
            if (!DeviceReportEncoder.TryDecodeBinding(
                layer, inputId, hex, currentInputs[inputId], out var binding))
            {
                error = $"unsupported_device_binding:{inputId}";
                return false;
            }
            imported[inputId] = binding;
        }

        inputs = imported;
        return true;
    }
}
