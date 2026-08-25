using System.Diagnostics;
using System.Runtime.InteropServices;
using CodexKeyboardStudio.Models;

namespace CodexKeyboardStudio.Services;

public sealed class InputActionDispatcher(ForegroundAppDetector detector, DiagnosticLog log)
{
    public const ulong InjectedInputMarker = 0x434B53545544494FUL;

    private const uint Control = 0x11;
    private const uint Shift = 0x10;
    private const uint Alt = 0x12;
    private const uint LeftControl = 0xA2;
    private const uint LeftWindows = 0x5B;
    private const uint LeftAlt = 0xA4;
    private const uint Home = 0x24;
    private const uint PageUp = 0x21;
    private const uint PageDown = 0x22;
    private const uint G = 0x47;
    private const uint C = 0x43;
    private const uint F13 = 0x7C;
    private const uint OemComma = 0xBC;
    private const uint OemPeriod = 0xBE;
    private static readonly HashSet<uint> ExtendedVirtualKeys =
    [
        0xA3, 0xA5, 0x5B, 0x5C,
        0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2C, 0x2D, 0x2E,
        0x5D, 0x6F, 0x90
    ];

    public static int NativeInputSize => Marshal.SizeOf<INPUT>();

    public Task<bool> DispatchAsync(string inputId, InputBinding binding) =>
        DispatchAsync(1, inputId, binding);

    public async Task<bool> DispatchAsync(int layer, string inputId, InputBinding binding)
    {
        var compiled = BindingCompiler.Compile(layer, inputId, binding);
        if (compiled.Delivery != BindingDelivery.AppRouted)
        {
            log.Write("input_ignored", $"input={inputId};delivery={compiled.Delivery}");
            return false;
        }
        if (!detector.IsTargetAvailable(binding.Scope))
        {
            log.Write("input_ignored", $"input={inputId};scope={binding.Scope};kind={binding.ActionKind}");
            return false;
        }

        await Task.Delay(20);
        if (!detector.IsTargetAvailable(binding.Scope))
        {
            log.Write("input_ignored", $"input={inputId};scope_changed={binding.Scope};kind={binding.ActionKind}");
            return false;
        }
        ReleaseAliasInput(layer, inputId);
        var result = binding.ActionKind switch
        {
            ActionKinds.Shortcut => DispatchShortcut(binding.Shortcut),
            ActionKinds.Text => binding.Text is not null && SendText(binding.Text),
            ActionKinds.BuiltIn => await DispatchBuiltInAsync(binding.Scope, binding.BuiltInActionId!),
            _ => false
        };
        var detail = $"layer={layer};input={inputId};scope={binding.Scope};kind={binding.ActionKind};builtin={binding.BuiltInActionId ?? "none"}";
        if (!result)
        {
            detail += $";win32Error={Marshal.GetLastWin32Error()}";
        }
        log.Write(result ? "input_dispatched" : "input_failed", detail);
        return result;
    }

    public Task<bool> DispatchManualTestAsync(string inputId, InputBinding binding) =>
        DispatchManualTestAsync(1, inputId, binding);

    public async Task<bool> DispatchManualTestAsync(int layer, string inputId, InputBinding binding)
    {
        var compiled = BindingCompiler.Compile(layer, inputId, binding);
        if (compiled.Delivery == BindingDelivery.Disabled)
        {
            log.Write("manual_test_ignored", $"input={inputId};delivery=disabled");
            return false;
        }
        if (compiled.Delivery == BindingDelivery.AppRouted)
        {
            return await DispatchAsync(layer, inputId, binding);
        }
        if (binding.Scope == BindingScopes.Typeless && !detector.IsTargetAvailable(binding.Scope))
        {
            log.Write("manual_test_ignored", $"input={inputId};scope=typeless_not_running");
            return false;
        }

        var virtualKeys = compiled.DeviceKeys
            .Select(name => ShortcutCatalog.TryGetVirtualKey(name, out var key) ? key : 0)
            .ToArray();
        var result = virtualKeys.All(key => key != 0) && SendChord(virtualKeys);
        log.Write(
            result ? "manual_test_dispatched" : "manual_test_failed",
            $"input={inputId};scope={binding.Scope};kind={binding.ActionKind}");
        return result;
    }

    private static async Task<bool> DispatchBuiltInAsync(string scope, string actionId) => scope switch
    {
        BindingScopes.ChatGpt => await DispatchChatGptAsync(actionId),
        BindingScopes.CodexCli => DispatchCodexCli(actionId),
        BindingScopes.Typeless => DispatchTypeless(actionId),
        _ => false
    };

    private static bool DispatchTypeless(string actionId)
    {
        var keys = GetTypelessShortcut(actionId);
        return keys is not null && SendChord(keys);
    }

    private static bool DispatchShortcut(ShortcutDefinition? shortcut)
    {
        if (shortcut is null)
        {
            return false;
        }
        var virtualKeys = ShortcutCatalog.Normalize(shortcut)
            .Select(name => ShortcutCatalog.TryGetVirtualKey(name, out var key) ? key : 0)
            .ToArray();
        return virtualKeys.All(key => key != 0) && SendChord(virtualKeys);
    }

    private static async Task<bool> DispatchChatGptAsync(string actionId)
    {
        switch (actionId)
        {
            case "previous_conversation":
                return SendChord(Control, PageUp);
            case "next_conversation":
                return SendChord(Control, PageDown);
            case "switch_chat":
                return SendChord(Control, G);
            case "enter":
                return SendChord(InputAliasCatalog.Enter);
            case "reasoning_down":
                return SendChord(Control, Shift, Alt, InputAliasCatalog.Left);
            case "reasoning_up":
                return SendChord(Control, Shift, Alt, InputAliasCatalog.Right);
            case "reasoning_medium":
                for (var index = 0; index < 6; index++)
                {
                    if (!SendChord(Control, Shift, Alt, InputAliasCatalog.Left))
                    {
                        return false;
                    }
                    await Task.Delay(25);
                }
                return SendChord(Control, Shift, Alt, InputAliasCatalog.Right);
            case "model_menu_up":
                return SendChord(InputAliasCatalog.Up);
            case "model_menu_down":
                return SendChord(InputAliasCatalog.Down);
            case "model_selector":
                return SendChord(Control, Shift, Alt, Home);
            case "skills":
                return OpenAllowedUri("codex://skills");
            case "automations":
                return OpenAllowedUri("codex://automations");
            case "settings":
                return OpenAllowedUri("codex://settings");
            case "copy":
                return SendChord(Control, C);
            default:
                return false;
        }
    }

    private static bool DispatchCodexCli(string actionId)
    {
        var shortcut = GetCodexCliShortcut(actionId);
        if (shortcut is not null)
        {
            return SendChord(shortcut);
        }

        var text = actionId switch
        {
            "resume" => "/resume",
            "diagnose" => "현재 프로젝트에서 재현 가능한 오류와 이상 상태를 조사하고 원인을 설명해줘.",
            "explain_project" => "이 프로젝트의 구조, 실행 방법, 핵심 흐름을 간결하게 설명해줘.",
            "inspect_docs" => "README와 사용 문서를 점검하고 실제 코드와 맞지 않는 부분을 알려줘.",
            _ => null
        };
        return text is not null && SendTextAndEnter(text);
    }

    internal static uint[]? GetCodexCliShortcut(string actionId) => actionId switch
    {
        "reasoning_down" => [Alt, OemComma],
        "reasoning_up" => [Alt, OemPeriod],
        "copy" => [Control, C],
        _ => null
    };

    internal static uint[]? GetTypelessShortcut(string actionId) => actionId switch
    {
        "dictation" => [LeftControl, LeftWindows, LeftAlt],
        "translation" => [F13],
        "copy" => [Control, C],
        _ => null
    };

    private static bool OpenAllowedUri(string uri)
    {
        if (!uri.StartsWith("codex://", StringComparison.Ordinal))
        {
            return false;
        }
        try
        {
            Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true });
            return true;
        }
        catch
        {
            return false;
        }
    }

    internal static uint[] GetAliasReleaseKeys(string inputId)
        => GetAliasReleaseKeys(1, inputId);

    internal static uint[] GetAliasReleaseKeys(int layer, string inputId)
    {
        var keys = new List<uint>(4);
        if (InputAliasCatalog.TryGetByInputId(layer, inputId, out var alias))
        {
            keys.Add(alias.VirtualKey);
        }
        keys.AddRange([Control, Shift, Alt]);
        return keys.ToArray();
    }

    private static void ReleaseAliasInput(int layer, string inputId)
    {
        var inputs = GetAliasReleaseKeys(layer, inputId)
            .Select(key => KeyInput(key, keyUp: true))
            .ToArray();
        _ = SendKeyboardInputs(inputs);
    }

    private static bool SendChord(params uint[] keys)
    {
        var inputs = new List<INPUT>(keys.Length * 2);
        inputs.AddRange(keys.Select(key => KeyInput(key, keyUp: false)));
        inputs.AddRange(keys.Reverse().Select(key => KeyInput(key, keyUp: true)));
        return SendKeyboardInputs(inputs.ToArray());
    }

    private static bool SendTextAndEnter(string text)
    {
        var inputs = new List<INPUT>(text.Length * 2 + 2);
        foreach (var character in text)
        {
            inputs.Add(UnicodeInput(character, keyUp: false));
            inputs.Add(UnicodeInput(character, keyUp: true));
        }
        inputs.Add(KeyInput(InputAliasCatalog.Enter, keyUp: false));
        inputs.Add(KeyInput(InputAliasCatalog.Enter, keyUp: true));
        return SendKeyboardInputs(inputs.ToArray());
    }

    private static bool SendText(string text)
    {
        var inputs = new List<INPUT>(text.Length * 2);
        foreach (var character in text)
        {
            inputs.Add(UnicodeInput(character, keyUp: false));
            inputs.Add(UnicodeInput(character, keyUp: true));
        }
        return SendKeyboardInputs(inputs.ToArray());
    }

    private static bool SendKeyboardInputs(params INPUT[] inputs) =>
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>()) == (uint)inputs.Length;

    private static INPUT KeyInput(uint virtualKey, bool keyUp) => new()
    {
        Type = 1,
        Union = new InputUnion
        {
            Keyboard = new KEYBDINPUT
            {
                VirtualKey = (ushort)virtualKey,
                Flags = GetKeyboardFlags(virtualKey, keyUp),
                ExtraInfo = new UIntPtr(InjectedInputMarker)
            }
        }
    };

    internal static uint GetKeyboardFlags(uint virtualKey, bool keyUp) =>
        (keyUp ? 0x0002u : 0) | (ExtendedVirtualKeys.Contains(virtualKey) ? 0x0001u : 0);

    private static INPUT UnicodeInput(char character, bool keyUp) => new()
    {
        Type = 1,
        Union = new InputUnion
        {
            Keyboard = new KEYBDINPUT
            {
                ScanCode = character,
                Flags = 0x0004u | (keyUp ? 0x0002u : 0),
                ExtraInfo = new UIntPtr(InjectedInputMarker)
            }
        }
    };

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint Type;
        public InputUnion Union;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT Mouse;
        [FieldOffset(0)] public KEYBDINPUT Keyboard;
        [FieldOffset(0)] public HARDWAREINPUT Hardware;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int X;
        public int Y;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT
    {
        public uint Message;
        public ushort ParameterLow;
        public ushort ParameterHigh;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint inputCount, INPUT[] inputs, int inputSize);
}
