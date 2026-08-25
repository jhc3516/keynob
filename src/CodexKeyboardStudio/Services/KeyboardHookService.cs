using System.Collections.Concurrent;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using CodexKeyboardStudio.Models;

namespace CodexKeyboardStudio.Services;

public sealed record CodexCancellationRequest(string InstanceId, string Gesture);

public sealed class KeyboardHookService : IDisposable
{
    private const int KeyboardHook = 13;
    private const int KeyDown = 0x0100;
    private const int KeyUp = 0x0101;
    private const int SysKeyDown = 0x0104;
    private const int SysKeyUp = 0x0105;
    private const int Control = 0x11;
    private const int Shift = 0x10;
    private const int Alt = 0x12;
    private const uint Escape = 0x1B;
    private const uint C = 0x43;
    private static readonly TimeSpan CodexTitleResolutionTimeout = TimeSpan.FromMilliseconds(1500);
    private static readonly TimeSpan CodexTitleResolutionPollInterval = TimeSpan.FromMilliseconds(20);

    private readonly Func<StudioSettings> _settingsProvider;
    private readonly ForegroundAppDetector _detector;
    private readonly InputActionDispatcher _dispatcher;
    private readonly Func<CodexCancellationRequest, Task> _codexCancellationHandler;
    private readonly Dispatcher _uiDispatcher;
    private readonly DiagnosticLog _log;
    private readonly HookProc _callback;
    private readonly HashSet<uint> _suppressedKeys = [];
    private readonly ConcurrentDictionary<(IntPtr Window, string Gesture), byte> _pendingCancellationResolutions = [];
    private readonly InputDeduplicator _deduplicator = new(TimeSpan.FromMilliseconds(150));
    private IntPtr _hook;
    private CancellationTokenSource? _resolutionCancellation;

    public KeyboardHookService(
        Func<StudioSettings> settingsProvider,
        ForegroundAppDetector detector,
        InputActionDispatcher dispatcher,
        Func<CodexCancellationRequest, Task> codexCancellationHandler,
        Dispatcher uiDispatcher,
        DiagnosticLog log)
    {
        _settingsProvider = settingsProvider;
        _detector = detector;
        _dispatcher = dispatcher;
        _codexCancellationHandler = codexCancellationHandler;
        _uiDispatcher = uiDispatcher;
        _log = log;
        _callback = HookCallback;
    }

    public bool IsRunning => _hook != IntPtr.Zero;

    public bool Start()
    {
        if (IsRunning)
        {
            return true;
        }
        _hook = SetWindowsHookExW(KeyboardHook, _callback, GetModuleHandleW(null), 0);
        if (_hook == IntPtr.Zero)
        {
            _log.Write("hook_start_failed", Marshal.GetLastWin32Error().ToString());
            return false;
        }
        _resolutionCancellation = new CancellationTokenSource();
        _log.Write("hook_started", "aliases=18");
        return true;
    }

    public void Dispose()
    {
        Stop();
        GC.SuppressFinalize(this);
    }

    public void Stop()
    {
        var resolutionCancellation = _resolutionCancellation;
        _resolutionCancellation = null;
        resolutionCancellation?.Cancel();
        if (_hook != IntPtr.Zero)
        {
            _ = UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
            _log.Write("hook_stopped", "ok");
        }
        _pendingCancellationResolutions.Clear();
        resolutionCancellation?.Dispose();
    }

    private IntPtr HookCallback(int code, IntPtr message, IntPtr dataPointer)
    {
        if (code < 0)
        {
            return CallNextHookEx(_hook, code, message, dataPointer);
        }

        var data = Marshal.PtrToStructure<KeyboardData>(dataPointer);
        if (data.ExtraInfo.ToUInt64() == InputActionDispatcher.InjectedInputMarker)
        {
            return CallNextHookEx(_hook, code, message, dataPointer);
        }

        var messageId = message.ToInt32();
        if (messageId is KeyDown or SysKeyDown)
        {
            var controlPressed = IsPressed(Control);
            var gesture = GetCancellationGesture(data.VirtualKey, controlPressed);
            if (gesture is not null)
            {
                var foreground = _detector.DetectForegroundApp();
                var cancellationRequest = CreateCodexCancellationRequest(
                    data.VirtualKey,
                    controlPressed,
                    foreground);
                if (cancellationRequest is not null)
                {
                    DispatchCodexCancellation(cancellationRequest, "immediate");
                }
                else if (foreground.IsTerminal && foreground.IsCodexTitleCandidate &&
                    foreground.WindowHandle != IntPtr.Zero)
                {
                    BeginDeferredCodexCancellationResolution(foreground.WindowHandle, gesture);
                }
            }
        }
        if (messageId is KeyUp or SysKeyUp)
        {
            if (_suppressedKeys.Remove(data.VirtualKey))
            {
                return (IntPtr)1;
            }
            return CallNextHookEx(_hook, code, message, dataPointer);
        }
        if (messageId is not (KeyDown or SysKeyDown) ||
            !InputAliasCatalog.TryGetByVirtualKey(data.VirtualKey, out var alias) ||
            !IsPressed(Control) || !IsPressed(Shift) || !IsPressed(Alt))
        {
            return CallNextHookEx(_hook, code, message, dataPointer);
        }

        _suppressedKeys.Add(data.VirtualKey);
        var routedInputId = $"{alias.Layer}:{alias.InputId}";
        if (!_deduplicator.ShouldAccept(routedInputId, DateTimeOffset.UtcNow))
        {
            _log.Write("input_duplicate", routedInputId);
            return (IntPtr)1;
        }

        var settings = _settingsProvider();
        if (!settings.GetLayerInputs(alias.Layer).TryGetValue(alias.InputId, out var binding))
        {
            _log.Write("input_unknown", routedInputId);
            return (IntPtr)1;
        }
        CompiledBinding compiled;
        try
        {
            compiled = BindingCompiler.Compile(alias.Layer, alias.InputId, binding);
        }
        catch (InvalidDataException exception)
        {
            _log.Write("input_invalid", $"layer={alias.Layer};input={alias.InputId};error={exception.Message}");
            return (IntPtr)1;
        }
        if (compiled.Delivery != BindingDelivery.AppRouted)
        {
            if (compiled.Delivery == BindingDelivery.DeviceDirect)
            {
                _suppressedKeys.Remove(data.VirtualKey);
                _log.Write("input_passthrough", $"layer={alias.Layer};input={alias.InputId};delivery=device_direct");
                return CallNextHookEx(_hook, code, message, dataPointer);
            }
            _log.Write("input_unexpected_alias", $"layer={alias.Layer};input={alias.InputId};delivery=disabled");
            return (IntPtr)1;
        }
        if (!_detector.IsTargetAvailable(binding.Scope))
        {
            _log.Write("input_blocked", $"layer={alias.Layer};input={alias.InputId};scope={binding.Scope}");
            return (IntPtr)1;
        }

        _log.Write(
            "input_accepted",
            $"layer={alias.Layer};input={alias.InputId};scope={binding.Scope};kind={binding.ActionKind}");

        _ = _uiDispatcher.BeginInvoke(async () =>
            await _dispatcher.DispatchAsync(alias.Layer, alias.InputId, binding));
        return (IntPtr)1;
    }

    private static bool IsPressed(int virtualKey) => (GetAsyncKeyState(virtualKey) & 0x8000) != 0;

    public static CodexCancellationRequest? CreateCodexCancellationRequest(
        uint virtualKey,
        bool controlPressed,
        ForegroundAppMatch foreground)
    {
        if (!string.Equals(foreground.TargetAppId, "codex_cli", StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(foreground.CodexInstanceId))
        {
            return null;
        }
        return virtualKey switch
        {
            Escape => new(foreground.CodexInstanceId, "escape"),
            C when controlPressed => new(foreground.CodexInstanceId, "ctrl_c"),
            _ => null
        };
    }

    private static string? GetCancellationGesture(uint virtualKey, bool controlPressed) => virtualKey switch
    {
        Escape => "escape",
        C when controlPressed => "ctrl_c",
        _ => null
    };

    private void DispatchCodexCancellation(CodexCancellationRequest request, string resolution)
    {
        _log.Write(
            "codex_cancel_gesture",
            $"key={request.Gesture};instance={request.InstanceId};resolution={resolution}");
        _ = _uiDispatcher.BeginInvoke(async () => await _codexCancellationHandler(request));
    }

    private void BeginDeferredCodexCancellationResolution(IntPtr window, string gesture)
    {
        var key = (window, gesture);
        if (!_pendingCancellationResolutions.TryAdd(key, 0))
        {
            return;
        }
        var cancellationToken = _resolutionCancellation?.Token ?? CancellationToken.None;
        _log.Write("codex_cancel_title_wait", $"gesture={gesture};window={window}");
        _ = ResolveCodexCancellationAsync(key, cancellationToken);
    }

    private async Task ResolveCodexCancellationAsync(
        (IntPtr Window, string Gesture) key,
        CancellationToken cancellationToken)
    {
        try
        {
            var deadline = DateTimeOffset.UtcNow + CodexTitleResolutionTimeout;
            while (DateTimeOffset.UtcNow < deadline)
            {
                await Task.Delay(CodexTitleResolutionPollInterval, cancellationToken).ConfigureAwait(false);
                var foreground = _detector.DetectForegroundApp();
                if (foreground.WindowHandle != key.Window)
                {
                    _log.Write(
                        "codex_cancel_title_unresolved",
                        $"gesture={key.Gesture};reason=foreground_changed");
                    return;
                }
                if (string.Equals(foreground.TargetAppId, "codex_cli", StringComparison.Ordinal) &&
                    !string.IsNullOrWhiteSpace(foreground.CodexInstanceId))
                {
                    DispatchCodexCancellation(
                        new CodexCancellationRequest(foreground.CodexInstanceId, key.Gesture),
                        "title_restored");
                    return;
                }
            }
            _log.Write(
                "codex_cancel_title_unresolved",
                $"gesture={key.Gesture};reason=timeout");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // The hook is stopping; no cancellation should outlive the service.
        }
        finally
        {
            _pendingCancellationResolutions.TryRemove(key, out _);
        }
    }

    private delegate IntPtr HookProc(int code, IntPtr message, IntPtr dataPointer);

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardData
    {
        public uint VirtualKey;
        public uint ScanCode;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookExW(int hookId, HookProc callback, IntPtr module, uint threadId);

    [DllImport("user32.dll")]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr dataPointer);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int virtualKey);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandleW(string? moduleName);
}
