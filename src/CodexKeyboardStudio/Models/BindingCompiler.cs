using System.IO;

namespace CodexKeyboardStudio.Models;

public enum BindingDelivery
{
    Disabled,
    DeviceDirect,
    AppRouted
}

public sealed record CompiledBinding(
    int Layer,
    string InputId,
    BindingDelivery Delivery,
    IReadOnlyList<string> DeviceKeys,
    InputBinding Source);

public static class BindingCompiler
{
    private static readonly HashSet<string> AllowedScopes =
    [
        BindingScopes.Global, BindingScopes.ChatGpt, BindingScopes.CodexCli, BindingScopes.Typeless
    ];

    public static CompiledBinding Compile(string inputId, InputBinding binding) =>
        Compile(1, inputId, binding);

    public static CompiledBinding Compile(int layer, string inputId, InputBinding binding)
    {
        if (!StudioSettingsCatalog.LayerIds.Contains(layer))
        {
            throw new InvalidDataException("invalid_layer");
        }
        if (!StudioSettingsCatalog.InputIds.Contains(inputId, StringComparer.Ordinal))
        {
            throw new InvalidDataException("unknown_input");
        }
        if (!AllowedScopes.Contains(binding.Scope))
        {
            throw new InvalidDataException("unknown_scope");
        }

        return binding.ActionKind switch
        {
            ActionKinds.Disabled => CompileDisabled(layer, inputId, binding),
            ActionKinds.Shortcut => CompileShortcut(layer, inputId, binding),
            ActionKinds.Text => CompileText(layer, inputId, binding),
            ActionKinds.BuiltIn => CompileBuiltIn(layer, inputId, binding),
            _ => throw new InvalidDataException("unknown_action_kind")
        };
    }

    public static IReadOnlyDictionary<string, CompiledBinding> CompileAll(StudioSettings settings) =>
        CompileLayer(settings, 1);

    public static IReadOnlyDictionary<string, CompiledBinding> CompileLayer(StudioSettings settings, int layer) =>
        settings.GetLayerInputs(layer).ToDictionary(
            pair => pair.Key,
            pair => Compile(layer, pair.Key, pair.Value),
            StringComparer.Ordinal);

    private static CompiledBinding CompileDisabled(int layer, string inputId, InputBinding binding)
    {
        if (binding.Shortcut is not null || binding.Text is not null || binding.BuiltInActionId is not null)
        {
            throw new InvalidDataException("disabled_binding_has_payload");
        }
        return new(layer, inputId, BindingDelivery.Disabled, [], binding);
    }

    private static CompiledBinding CompileShortcut(int layer, string inputId, InputBinding binding)
    {
        if (binding.Shortcut is null || binding.Text is not null || binding.BuiltInActionId is not null)
        {
            throw new InvalidDataException("invalid_shortcut_payload");
        }
        var keys = ShortcutCatalog.Normalize(binding.Shortcut);
        var delivery = binding.Scope is BindingScopes.Global or BindingScopes.Typeless
            ? BindingDelivery.DeviceDirect
            : BindingDelivery.AppRouted;
        if (delivery == BindingDelivery.DeviceDirect && keys.Any(ShortcutCatalog.IsRightModifier))
        {
            throw new InvalidDataException("right_modifier_not_supported_by_device");
        }
        if (delivery == BindingDelivery.DeviceDirect && IsReservedAliasShortcut(keys))
        {
            throw new InvalidDataException("reserved_alias_shortcut");
        }
        return new(
            layer,
            inputId,
            delivery,
            delivery == BindingDelivery.AppRouted ? BuildAliasKeys(layer, inputId) : keys,
            binding);
    }

    private static bool IsReservedAliasShortcut(IReadOnlyList<string> keys)
    {
        if (keys.Count != 4 || !keys.Take(3).SequenceEqual(["LeftCtrl", "LeftShift", "LeftAlt"]))
        {
            return false;
        }
        return InputAliasCatalog.All.Any(alias =>
            string.Equals(ShortcutCatalog.FromVirtualKey(alias.VirtualKey), keys[3], StringComparison.Ordinal));
    }

    private static CompiledBinding CompileText(int layer, string inputId, InputBinding binding)
    {
        if (binding.Scope is not (BindingScopes.ChatGpt or BindingScopes.CodexCli) ||
            string.IsNullOrEmpty(binding.Text) || binding.Text.Length > 2000 ||
            binding.Text.Any(character => char.IsControl(character) && character is not ('\r' or '\n' or '\t')) ||
            binding.Shortcut is not null || binding.BuiltInActionId is not null)
        {
            throw new InvalidDataException("invalid_text_binding");
        }
        return new(layer, inputId, BindingDelivery.AppRouted, BuildAliasKeys(layer, inputId), binding);
    }

    private static CompiledBinding CompileBuiltIn(int layer, string inputId, InputBinding binding)
    {
        if (binding.Shortcut is not null || binding.Text is not null || string.IsNullOrWhiteSpace(binding.BuiltInActionId) ||
            !StudioSettingsCatalog.BuiltInActions.Any(action =>
                action.Id == binding.BuiltInActionId && action.Scope == binding.Scope))
        {
            throw new InvalidDataException("invalid_builtin_binding");
        }

        if (binding.Scope == BindingScopes.Typeless)
        {
            if (binding.BuiltInActionId == "translation")
            {
                return new(layer, inputId, BindingDelivery.AppRouted, BuildAliasKeys(layer, inputId), binding);
            }
            var shortcut = binding.BuiltInActionId switch
            {
                "dictation" => new[] { "LeftCtrl", "LeftWin", "LeftAlt" },
                "copy" => new[] { "LeftCtrl", "C" },
                _ => throw new InvalidDataException("invalid_typeless_builtin")
            };
            return new(layer, inputId, BindingDelivery.DeviceDirect, shortcut, binding);
        }

        return new(layer, inputId, BindingDelivery.AppRouted, BuildAliasKeys(layer, inputId), binding);
    }

    private static IReadOnlyList<string> BuildAliasKeys(int layer, string inputId)
    {
        if (!InputAliasCatalog.TryGetByInputId(layer, inputId, out var alias))
        {
            throw new InvalidDataException("missing_input_alias");
        }
        return ["LeftCtrl", "LeftShift", "LeftAlt", ShortcutCatalog.FromVirtualKey(alias.VirtualKey)];
    }
}

internal sealed record ShortcutKeyDefinition(
    string Name,
    string DisplayName,
    string GuideDisplayName,
    uint VirtualKey,
    byte DeviceCode,
    string GuideGroup);

public sealed record ShortcutSupportGuideSection(string Title, string Keys);

public static class ShortcutCatalog
{
    private static readonly IReadOnlyList<ShortcutKeyDefinition> Definitions = BuildDefinitions();
    private static readonly IReadOnlyDictionary<string, ShortcutKeyDefinition> KeysByName =
        Definitions.ToDictionary(definition => definition.Name, StringComparer.Ordinal);
    private static readonly IReadOnlyDictionary<uint, ShortcutKeyDefinition> KeysByVirtualKey =
        Definitions.GroupBy(definition => definition.VirtualKey)
            .ToDictionary(group => group.Key, group => group.First());
    private static readonly IReadOnlyDictionary<byte, ShortcutKeyDefinition> KeysByDeviceCode =
        Definitions.GroupBy(definition => definition.DeviceCode)
            .ToDictionary(group => group.Key, group => group.First());
    private static readonly string[] ModifierOrder =
    [
        "LeftCtrl", "RightCtrl", "LeftShift", "RightShift", "LeftWin", "RightWin", "LeftAlt", "RightAlt"
    ];
    private static readonly (string Id, string Label)[] GuideGroups =
    [
        ("modifier", "보조키"),
        ("letter", "문자"),
        ("number", "상단 숫자"),
        ("punctuation", "문장부호"),
        ("function", "기능키"),
        ("editing", "편집키"),
        ("navigation", "이동키"),
        ("system", "잠금·시스템"),
        ("numpad", "숫자 키패드")
    ];
    private static readonly IReadOnlyList<ShortcutSupportGuideSection> SupportGuideSections = GuideGroups
        .Select(group => new ShortcutSupportGuideSection(
            group.Label,
            string.Join(" · ", Definitions
                .Where(definition => definition.GuideGroup == group.Id)
                .Select(definition => definition.GuideDisplayName))))
        .ToArray();

    public static IEnumerable<string> SupportedKeyNames => Definitions.Select(definition => definition.Name);

    public static IReadOnlyList<string> Normalize(ShortcutDefinition shortcut)
    {
        if (shortcut.Modifiers is null)
        {
            throw new InvalidDataException("missing_shortcut_modifiers");
        }
        var modifiers = shortcut.Modifiers.Distinct(StringComparer.Ordinal).ToArray();
        if (modifiers.Length > 4 || modifiers.Any(modifier => !ModifierOrder.Contains(modifier, StringComparer.Ordinal)))
        {
            throw new InvalidDataException("invalid_shortcut_modifiers");
        }
        if (shortcut.Key is not null && (!KeysByName.ContainsKey(shortcut.Key) || ModifierOrder.Contains(shortcut.Key, StringComparer.Ordinal)))
        {
            throw new InvalidDataException("invalid_shortcut_key");
        }
        if (modifiers.Length == 0 && shortcut.Key is null)
        {
            throw new InvalidDataException("empty_shortcut");
        }
        return ModifierOrder.Where(modifiers.Contains).Concat(shortcut.Key is null ? [] : new[] { shortcut.Key }).ToArray();
    }

    public static bool TryGetVirtualKey(string name, out uint virtualKey)
    {
        if (KeysByName.TryGetValue(name, out var definition))
        {
            virtualKey = definition.VirtualKey;
            return true;
        }
        virtualKey = 0;
        return false;
    }

    public static bool TryGetDeviceCode(string name, out byte deviceCode)
    {
        if (KeysByName.TryGetValue(name, out var definition))
        {
            deviceCode = definition.DeviceCode;
            return true;
        }
        deviceCode = 0;
        return false;
    }

    public static bool TryGetNameFromDeviceCode(byte deviceCode, out string name)
    {
        if (KeysByDeviceCode.TryGetValue(deviceCode, out var definition))
        {
            name = definition.Name;
            return true;
        }
        name = string.Empty;
        return false;
    }

    public static bool IsModifier(string name) => ModifierOrder.Contains(name, StringComparer.Ordinal);

    public static bool IsRightModifier(string name) => name is "RightCtrl" or "RightShift" or "RightWin" or "RightAlt";

    public static string FromVirtualKey(uint virtualKey) => KeysByVirtualKey.TryGetValue(virtualKey, out var definition)
        ? definition.Name
        : throw new InvalidDataException("unsupported_virtual_key");

    public static string Format(ShortcutDefinition? shortcut) => shortcut is null
        ? "단축키 없음"
        : string.Join(" + ", Normalize(shortcut).Select(GetDisplayName));

    public static IReadOnlyList<ShortcutSupportGuideSection> GetSupportGuideSections() => SupportGuideSections;

    public static string GetScopeSupportGuide(string? scope) => scope is BindingScopes.Global or BindingScopes.Typeless
        ? "장치 직접 전달 · 왼쪽 Ctrl·Shift·Win·Alt만 사용할 수 있으며 내부 예약 조합은 제외됩니다."
        : "앱 전달 · 왼쪽과 오른쪽 보조키를 모두 사용할 수 있습니다.";

    public static string GetSupportGuide(string? scope)
    {
        var lines = SupportGuideSections
            .Select(section => $"{section.Title}: {section.Keys}")
            .ToList();
        lines.Add("조합: 보조키 최대 4개 + 일반 키 1개, 또는 보조키만");
        lines.Add("숫자 키패드 Enter는 일반 Enter와 같은 키로 기록됩니다.");
        lines.Add($"현재 범위: {GetScopeSupportGuide(scope)}");
        lines.Add("볼륨·재생·브라우저 키와 한/영·한자 키는 현재 지원하지 않습니다.");
        return string.Join(Environment.NewLine, lines);
    }

    private static string GetDisplayName(string name) => KeysByName.TryGetValue(name, out var definition)
        ? definition.DisplayName
        : name;

    private static IReadOnlyList<ShortcutKeyDefinition> BuildDefinitions()
    {
        var keys = new List<ShortcutKeyDefinition>();

        void Add(
            string name,
            string displayName,
            uint virtualKey,
            byte deviceCode,
            string group,
            string? guideDisplayName = null) =>
            keys.Add(new(name, displayName, guideDisplayName ?? displayName, virtualKey, deviceCode, group));

        Add("LeftCtrl", "LeftCtrl", 0xA2, 0xF1, "modifier");
        Add("RightCtrl", "RightCtrl", 0xA3, 0xF1, "modifier");
        Add("LeftShift", "LeftShift", 0xA0, 0xF2, "modifier");
        Add("RightShift", "RightShift", 0xA1, 0xF2, "modifier");
        Add("LeftWin", "LeftWin", 0x5B, 0xF4, "modifier");
        Add("RightWin", "RightWin", 0x5C, 0xF4, "modifier");
        Add("LeftAlt", "LeftAlt", 0xA4, 0xF3, "modifier");
        Add("RightAlt", "RightAlt", 0xA5, 0xF3, "modifier");

        for (var letter = 'A'; letter <= 'Z'; letter++)
        {
            Add(letter.ToString(), letter.ToString(), letter, (byte)(0x04 + letter - 'A'), "letter");
        }
        for (var digit = 0; digit <= 9; digit++)
        {
            var deviceCode = digit == 0 ? 0x27 : 0x1D + digit;
            Add(digit.ToString(), digit.ToString(), (uint)(0x30 + digit), (byte)deviceCode, "number");
        }

        Add("Grave", "`", 0xC0, 0x35, "punctuation", "백틱 ( ` )");
        Add("Minus", "-", 0xBD, 0x2D, "punctuation", "빼기 ( - )");
        Add("Equals", "=", 0xBB, 0x2E, "punctuation", "등호 ( = )");
        Add("LeftBracket", "[", 0xDB, 0x2F, "punctuation", "왼쪽 대괄호 ( [ )");
        Add("RightBracket", "]", 0xDD, 0x30, "punctuation", "오른쪽 대괄호 ( ] )");
        Add("Backslash", "\\", 0xDC, 0x31, "punctuation", "역슬래시 ( \\ )");
        Add("Semicolon", ";", 0xBA, 0x33, "punctuation", "세미콜론 ( ; )");
        Add("Apostrophe", "'", 0xDE, 0x34, "punctuation", "작은따옴표 ( ' )");
        Add("Comma", ",", 0xBC, 0x36, "punctuation", "쉼표 ( , )");
        Add("Period", ".", 0xBE, 0x37, "punctuation", "마침표 ( . )");
        Add("Slash", "/", 0xBF, 0x38, "punctuation", "슬래시 ( / )");

        for (var function = 1; function <= 24; function++)
        {
            var deviceCode = function <= 12 ? 0x39 + function : 0x5B + function;
            Add($"F{function}", $"F{function}", (uint)(0x6F + function), (byte)deviceCode, "function");
        }

        Add("Enter", "Enter", 0x0D, 0x28, "editing");
        Add("Escape", "Escape", 0x1B, 0x29, "editing");
        Add("Space", "Space", 0x20, 0x2C, "editing");
        Add("Tab", "Tab", 0x09, 0x2B, "editing");
        Add("Backspace", "Backspace", 0x08, 0x2A, "editing");

        Add("Insert", "Insert", 0x2D, 0x49, "navigation");
        Add("Delete", "Delete", 0x2E, 0x4C, "navigation");
        Add("Home", "Home", 0x24, 0x4A, "navigation");
        Add("End", "End", 0x23, 0x4D, "navigation");
        Add("PageUp", "PageUp", 0x21, 0x4B, "navigation");
        Add("PageDown", "PageDown", 0x22, 0x4E, "navigation");
        Add("Left", "Left", 0x25, 0x50, "navigation");
        Add("Up", "Up", 0x26, 0x52, "navigation");
        Add("Right", "Right", 0x27, 0x4F, "navigation");
        Add("Down", "Down", 0x28, 0x51, "navigation");

        Add("CapsLock", "Caps Lock", 0x14, 0x39, "system");
        Add("PrintScreen", "Print Screen", 0x2C, 0x46, "system");
        Add("ScrollLock", "Scroll Lock", 0x91, 0x47, "system");
        Add("Pause", "Pause", 0x13, 0x48, "system");
        Add("Menu", "Menu", 0x5D, 0x65, "system");

        Add("NumLock", "Num Lock", 0x90, 0x53, "numpad");
        Add("NumpadDivide", "Num /", 0x6F, 0x54, "numpad");
        Add("NumpadMultiply", "Num *", 0x6A, 0x55, "numpad");
        Add("NumpadSubtract", "Num -", 0x6D, 0x56, "numpad");
        Add("NumpadAdd", "Num +", 0x6B, 0x57, "numpad");
        Add("Numpad0", "Num 0", 0x60, 0x62, "numpad");
        for (var digit = 1; digit <= 9; digit++)
        {
            Add($"Numpad{digit}", $"Num {digit}", (uint)(0x60 + digit), (byte)(0x58 + digit), "numpad");
        }
        Add("NumpadDecimal", "Num .", 0x6E, 0x63, "numpad");

        return keys;
    }
}
