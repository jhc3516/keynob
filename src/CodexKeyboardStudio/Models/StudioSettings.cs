using System.IO;
using System.Text.Json.Serialization;

namespace CodexKeyboardStudio.Models;

public sealed class StudioSettings
{
    [JsonRequired]
    public int SchemaVersion { get; init; } = 3;
    [JsonRequired]
    public DeviceIdentity Device { get; init; } = new();
    [JsonRequired]
    public Dictionary<int, Dictionary<string, InputBinding>> Layers { get; init; } = [];
    [JsonRequired]
    public StatusColorSettings StatusColors { get; init; } = new();
    public Dictionary<string, string> KeyColors { get; init; } = [];
    public bool RestoreKeyColorsAfterCodexCompletion { get; init; } = true;
    public bool StartWithWindows { get; init; }

    [JsonIgnore]
    public Dictionary<string, InputBinding> Inputs => GetLayerInputs(1);

    public Dictionary<string, InputBinding> GetLayerInputs(int layer) =>
        Layers.TryGetValue(layer, out var inputs) ? inputs : [];
}

public sealed class DeviceIdentity
{
    [JsonRequired]
    public string VendorId { get; init; } = "514C";
    [JsonRequired]
    public string ProductId { get; init; } = "8850";
    public string Serial { get; init; } = "";
    [JsonRequired]
    public string Layout { get; init; } = "12-key-2-knob";
}

public sealed class InputBinding
{
    [JsonRequired]
    public string Scope { get; init; } = BindingScopes.Global;
    [JsonRequired]
    public string ActionKind { get; init; } = ActionKinds.Disabled;
    public ShortcutDefinition? Shortcut { get; init; }
    public string? Text { get; init; }
    public string? BuiltInActionId { get; init; }
}

public sealed class ShortcutDefinition
{
    public List<string> Modifiers { get; init; } = [];
    public string? Key { get; init; }
}

public static class BindingScopes
{
    public const string Global = "global";
    public const string ChatGpt = "chatgpt";
    public const string CodexCli = "codex_cli";
    public const string Typeless = "typeless";
}

public static class ActionKinds
{
    public const string Disabled = "disabled";
    public const string Shortcut = "shortcut";
    public const string Text = "text";
    public const string BuiltIn = "builtin";
}

public sealed class StatusColorSettings
{
    [JsonRequired]
    public string Running { get; init; } = "blue";
    [JsonRequired]
    public string Approval { get; init; } = "yellow";
    [JsonRequired]
    public string Completed { get; init; } = "green";
    [JsonRequired]
    public string Error { get; init; } = "red";
}

public sealed record ScopeOption(string Id, string Label);
public sealed record ActionKindOption(string Id, string Label);
public sealed record BuiltInActionOption(string Id, string Scope, string Label);
public sealed record LedColorOption(string Id, string Label);

public static class StudioSettingsCatalog
{
    public static readonly IReadOnlyList<int> LayerIds = [1, 2, 3];

    public static readonly IReadOnlyList<ScopeOption> Scopes =
    [
        new(BindingScopes.Global, "모든 프로그램"),
        new(BindingScopes.ChatGpt, "ChatGPT에서만"),
        new(BindingScopes.CodexCli, "Codex CLI에서만 (전용 실행기)"),
        new(BindingScopes.Typeless, "Typeless (모든 창)")
    ];

    public static readonly IReadOnlyList<ActionKindOption> ActionKinds =
    [
        new(Models.ActionKinds.Disabled, "사용 안 함"),
        new(Models.ActionKinds.Shortcut, "단축키"),
        new(Models.ActionKinds.Text, "텍스트 입력"),
        new(Models.ActionKinds.BuiltIn, "기본 기능")
    ];

    private static readonly IReadOnlyList<ActionKindOption> TypelessActionKinds =
        ActionKinds.Where(option => option.Id == Models.ActionKinds.Shortcut).ToArray();

    public static IReadOnlyList<ActionKindOption> GetActionKinds(string scope) =>
        scope == BindingScopes.Typeless ? TypelessActionKinds : ActionKinds;

    public static readonly IReadOnlyList<LedColorOption> LedColors =
    [
        new("blue", "파란색"),
        new("yellow", "노란색"),
        new("green", "초록색"),
        new("red", "빨간색"),
        new("orange", "주황색"),
        new("cyan", "청록색"),
        new("purple", "보라색"),
        new("pink", "분홍색")
    ];

    public static bool IsLedColorSupported(string color) =>
        LedColors.Any(option => string.Equals(option.Id, color, StringComparison.Ordinal));

    public static readonly IReadOnlyList<BuiltInActionOption> BuiltInActions =
    [
        new("previous_conversation", BindingScopes.ChatGpt, "이전 대화"),
        new("next_conversation", BindingScopes.ChatGpt, "다음 대화"),
        new("switch_chat", BindingScopes.ChatGpt, "작업 검색/전환"),
        new("enter", BindingScopes.ChatGpt, "Enter 보내기"),
        new("reasoning_down", BindingScopes.ChatGpt, "추론 강도 낮춤"),
        new("reasoning_up", BindingScopes.ChatGpt, "추론 강도 높임"),
        new("reasoning_medium", BindingScopes.ChatGpt, "추론 강도 중간"),
        new("model_menu_up", BindingScopes.ChatGpt, "모델 메뉴 위로"),
        new("model_menu_down", BindingScopes.ChatGpt, "모델 메뉴 아래로"),
        new("model_selector", BindingScopes.ChatGpt, "모델 선택 열기"),
        new("skills", BindingScopes.ChatGpt, "Skills 열기"),
        new("automations", BindingScopes.ChatGpt, "자동화 열기"),
        new("settings", BindingScopes.ChatGpt, "설정 열기"),
        new("copy", BindingScopes.ChatGpt, "복사 (Ctrl+C)"),
        new("resume", BindingScopes.CodexCli, "작업 검색/재개"),
        new("reasoning_down", BindingScopes.CodexCli, "추론 강도 낮추기"),
        new("reasoning_up", BindingScopes.CodexCli, "추론 강도 높이기"),
        new("diagnose", BindingScopes.CodexCli, "오류 진단"),
        new("explain_project", BindingScopes.CodexCli, "프로젝트 설명"),
        new("inspect_docs", BindingScopes.CodexCli, "문서 점검"),
        new("copy", BindingScopes.CodexCli, "복사 (Ctrl+C)"),
        new("dictation", BindingScopes.Typeless, "음성 입력 (Left Ctrl+Win+Alt)"),
        new("translation", BindingScopes.Typeless, "번역"),
        new("copy", BindingScopes.Typeless, "복사 (Ctrl+C)")
    ];

    public static readonly IReadOnlyList<string> InputIds =
    [
        "key01", "key02", "key03", "key04", "key05", "key06",
        "key07", "key08", "key09", "key10", "key11", "key12",
        "knob1_ccw", "knob1_press", "knob1_cw",
        "knob2_ccw", "knob2_press", "knob2_cw"
    ];

    public static StudioSettings CreateDefault() => new()
    {
        KeyColors = Enumerable.Range(1, 12).ToDictionary(
            number => $"key{number:00}", _ => "blue", StringComparer.Ordinal),
        Layers = CreateBlankLayers()
    };

    public static StudioSettings CreateBlankFrom(StudioSettings settings) =>
        CreateBlankLayerFrom(settings, 1);

    public static StudioSettings CreateBlankLayerFrom(StudioSettings settings, int layer) =>
        ReplaceLayer(settings, layer, CreateBlankInputs());

    public static StudioSettings ReplaceLayer(
        StudioSettings settings,
        int layer,
        IReadOnlyDictionary<string, InputBinding> inputs)
    {
        if (!LayerIds.Contains(layer))
        {
            throw new InvalidDataException("invalid_layer");
        }
        return new StudioSettings
        {
            SchemaVersion = settings.SchemaVersion,
            Device = settings.Device,
            Layers = settings.Layers.ToDictionary(
                pair => pair.Key,
                pair => pair.Key == layer
                    ? new Dictionary<string, InputBinding>(inputs, StringComparer.Ordinal)
                    : new Dictionary<string, InputBinding>(pair.Value, StringComparer.Ordinal)),
            StatusColors = settings.StatusColors,
            KeyColors = new Dictionary<string, string>(settings.KeyColors, StringComparer.Ordinal),
            RestoreKeyColorsAfterCodexCompletion = settings.RestoreKeyColorsAfterCodexCompletion,
            StartWithWindows = settings.StartWithWindows
        };
    }

    public static Dictionary<string, InputBinding> CreateBlankInputs() =>
        InputIds.ToDictionary(id => id, _ => new InputBinding(), StringComparer.Ordinal);

    public static Dictionary<int, Dictionary<string, InputBinding>> CreateBlankLayers() =>
        LayerIds.ToDictionary(layer => layer, _ => CreateBlankInputs());

    public static StudioSettings CreateKnownV1From(StudioSettings settings)
    {
        var actions = new Dictionary<string, (string Scope, string ActionId)>(StringComparer.Ordinal)
        {
            ["key01"] = (BindingScopes.ChatGpt, "previous_conversation"),
            ["key02"] = (BindingScopes.ChatGpt, "switch_chat"),
            ["key03"] = (BindingScopes.ChatGpt, "next_conversation"),
            ["key04"] = (BindingScopes.Typeless, "dictation"),
            ["key05"] = (BindingScopes.CodexCli, "diagnose"),
            ["key06"] = (BindingScopes.CodexCli, "explain_project"),
            ["key07"] = (BindingScopes.CodexCli, "inspect_docs"),
            ["key08"] = (BindingScopes.Typeless, "translation"),
            ["key09"] = (BindingScopes.ChatGpt, "skills"),
            ["key10"] = (BindingScopes.ChatGpt, "automations"),
            ["key11"] = (BindingScopes.ChatGpt, "settings"),
            ["key12"] = (BindingScopes.ChatGpt, "enter"),
            ["knob1_ccw"] = (BindingScopes.ChatGpt, "reasoning_down"),
            ["knob1_press"] = (BindingScopes.ChatGpt, "reasoning_medium"),
            ["knob1_cw"] = (BindingScopes.ChatGpt, "reasoning_up"),
            ["knob2_ccw"] = (BindingScopes.ChatGpt, "model_menu_up"),
            ["knob2_press"] = (BindingScopes.ChatGpt, "model_selector"),
            ["knob2_cw"] = (BindingScopes.ChatGpt, "model_menu_down")
        };
        return new StudioSettings
        {
            SchemaVersion = settings.SchemaVersion,
            Device = settings.Device,
            Layers = CreateLayersWithLayerOne(actions.ToDictionary(
                    pair => pair.Key,
                    pair => new InputBinding
                    {
                        Scope = pair.Value.Scope,
                        ActionKind = Models.ActionKinds.BuiltIn,
                        BuiltInActionId = pair.Value.ActionId
                    },
                    StringComparer.Ordinal)),
            StatusColors = settings.StatusColors,
            KeyColors = new Dictionary<string, string>(settings.KeyColors, StringComparer.Ordinal),
            RestoreKeyColorsAfterCodexCompletion = settings.RestoreKeyColorsAfterCodexCompletion,
            StartWithWindows = settings.StartWithWindows
        };
    }

    public static StudioSettings CreateV1Imported(
        IReadOnlyDictionary<string, (string Target, string Action)> inputs,
        DeviceIdentity device,
        StatusColorSettings statusColors,
        IReadOnlyDictionary<string, string>? keyColors,
        bool startWithWindows) => new()
        {
            Device = device,
            StatusColors = statusColors,
            KeyColors = keyColors is { Count: 12 }
            ? new Dictionary<string, string>(keyColors, StringComparer.Ordinal)
            : CreateDefault().KeyColors,
            StartWithWindows = startWithWindows,
            Layers = CreateLayersWithLayerOne(InputIds.ToDictionary(
                id => id,
                id => inputs.TryGetValue(id, out var old)
                    ? new InputBinding
                    {
                        Scope = old.Target,
                        ActionKind = Models.ActionKinds.BuiltIn,
                        BuiltInActionId = old.Action
                    }
                    : new InputBinding(),
                StringComparer.Ordinal))
        };

    public static StudioSettings CreateV2Imported(
        IReadOnlyDictionary<string, InputBinding> inputs,
        DeviceIdentity device,
        StatusColorSettings statusColors,
        IReadOnlyDictionary<string, string>? keyColors,
        bool restoreKeyColorsAfterCodexCompletion,
        bool startWithWindows) => new()
        {
            Device = device,
            StatusColors = statusColors,
            KeyColors = keyColors is { Count: 12 }
                ? new Dictionary<string, string>(keyColors, StringComparer.Ordinal)
                : CreateDefault().KeyColors,
            RestoreKeyColorsAfterCodexCompletion = restoreKeyColorsAfterCodexCompletion,
            StartWithWindows = startWithWindows,
            Layers = CreateLayersWithLayerOne(inputs)
        };

    private static Dictionary<int, Dictionary<string, InputBinding>> CreateLayersWithLayerOne(
        IReadOnlyDictionary<string, InputBinding> layerOneInputs)
    {
        var layers = CreateBlankLayers();
        layers[1] = new Dictionary<string, InputBinding>(layerOneInputs, StringComparer.Ordinal);
        return layers;
    }

    public static void Validate(StudioSettings settings)
    {
        if (settings.Device is null || settings.Layers is null || settings.StatusColors is null)
        {
            throw new InvalidDataException("missing_settings_section");
        }
        if (settings.SchemaVersion != 3)
        {
            throw new InvalidDataException("unsupported_schema_version");
        }
        if (settings.Device.VendorId != "514C" || settings.Device.ProductId != "8850" ||
            settings.Device.Layout != "12-key-2-knob")
        {
            throw new InvalidDataException("device_identity_mismatch");
        }
        if (settings.Layers.Count != LayerIds.Count || LayerIds.Any(layer => !settings.Layers.ContainsKey(layer)) ||
            settings.Layers.Keys.Any(layer => !LayerIds.Contains(layer)))
        {
            throw new InvalidDataException("layer_set_mismatch");
        }

        foreach (var layer in LayerIds)
        {
            var inputs = settings.Layers[layer];
            if (inputs is null || inputs.Count != InputIds.Count || InputIds.Any(id => !inputs.ContainsKey(id)) ||
                inputs.Keys.Any(id => !InputIds.Contains(id, StringComparer.Ordinal)))
            {
                throw new InvalidDataException($"input_set_mismatch:{layer}");
            }
            foreach (var pair in inputs)
            {
                BindingCompiler.Compile(
                    layer,
                    pair.Key,
                    pair.Value ?? throw new InvalidDataException("missing_input_binding"));
            }
            ValidateDuplicateShortcuts(layer, inputs);
        }

        var colors = new[] { settings.StatusColors.Running, settings.StatusColors.Approval,
            settings.StatusColors.Completed, settings.StatusColors.Error };
        if (colors.Any(color => !IsLedColorSupported(color)))
        {
            throw new InvalidDataException("unsupported_status_color");
        }
        var keyIds = InputIds.Take(12).ToArray();
        if (settings.KeyColors is null || settings.KeyColors.Count != keyIds.Length ||
            keyIds.Any(id => !settings.KeyColors.ContainsKey(id)) ||
            settings.KeyColors.Keys.Any(id => !keyIds.Contains(id, StringComparer.Ordinal)) ||
            settings.KeyColors.Values.Any(color => !IsLedColorSupported(color)))
        {
            throw new InvalidDataException("invalid_key_colors");
        }
    }

    private static void ValidateDuplicateShortcuts(
        int layer,
        IReadOnlyDictionary<string, InputBinding> inputs)
    {
        var shortcuts = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var inputId in InputIds)
        {
            var binding = inputs[inputId];
            if (binding.ActionKind != Models.ActionKinds.Shortcut || binding.Shortcut is null)
            {
                continue;
            }

            var signature = $"{binding.Scope}\u001f{string.Join('\u001f', ShortcutCatalog.Normalize(binding.Shortcut))}";
            if (shortcuts.TryGetValue(signature, out var existingInputId))
            {
                throw new InvalidDataException($"duplicate_shortcut:{layer}:{binding.Scope}:{existingInputId}:{inputId}");
            }
            shortcuts[signature] = inputId;
        }
    }

    public static string GetActionLabel(InputBinding binding) => binding.ActionKind switch
    {
        Models.ActionKinds.Disabled => "사용 안 함",
        Models.ActionKinds.Shortcut => ShortcutCatalog.Format(binding.Shortcut),
        Models.ActionKinds.Text => string.IsNullOrEmpty(binding.Text) ? "텍스트 입력" : $"텍스트: {Preview(binding.Text)}",
        Models.ActionKinds.BuiltIn => BuiltInActions.FirstOrDefault(
            action => action.Id == binding.BuiltInActionId && action.Scope == binding.Scope)?.Label ?? "알 수 없는 기능",
        _ => "알 수 없는 설정"
    };

    private static string Preview(string text) => text.Length <= 18 ? text : text[..18] + "...";
}
