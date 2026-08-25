using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace CodexKeyboardStudio.Services;

public sealed record ForegroundAppMatch(
    string? TargetAppId,
    string? CodexInstanceId,
    IntPtr WindowHandle = default,
    bool IsTerminal = false,
    bool IsCodexTitleCandidate = false);

public sealed class ForegroundAppDetector
{
    public const string CodexCliWindowMarker = "Codex CLI - MacroPad Studio";
    public const string CodexInstanceEnvironmentVariable = "CODEX_KEYBOARD_INSTANCE_ID";

    public string? DetectTargetApp() => DetectForegroundApp().TargetAppId;

    public ForegroundAppMatch DetectForegroundApp()
    {
        var window = GetForegroundWindow();
        if (window == IntPtr.Zero)
        {
            return new(null, null);
        }

        GetWindowThreadProcessId(window, out var processId);
        if (processId == 0)
        {
            return new(null, null, window);
        }

        try
        {
            using var process = Process.GetProcessById((int)processId);
            var title = GetTitle(window);
            string? path = null;
            try
            {
                path = process.MainModule?.FileName;
            }
            catch
            {
                // Process identity still provides a conservative fallback.
            }
            return ClassifyForeground(process.ProcessName, path, title) with { WindowHandle = window };
        }
        catch
        {
            return new(null, null, window);
        }
    }

    public bool IsTargetAvailable(string targetAppId)
    {
        var foregroundTarget = DetectTargetApp();
        var typelessRunning = string.Equals(targetAppId, "typeless", StringComparison.Ordinal) &&
            IsTypelessRunning();
        return IsTargetAvailable(targetAppId, foregroundTarget, typelessRunning);
    }

    public static bool IsTargetAvailable(string targetAppId, string? foregroundTarget, bool typelessRunning) =>
        string.Equals(targetAppId, "typeless", StringComparison.Ordinal)
            ? typelessRunning
            : string.Equals(foregroundTarget, targetAppId, StringComparison.Ordinal);

    public static string? Classify(string processName, string? executablePath, string? windowTitle)
        => ClassifyForeground(processName, executablePath, windowTitle).TargetAppId;

    public static ForegroundAppMatch ClassifyForeground(
        string processName,
        string? executablePath,
        string? windowTitle)
    {
        if (processName.Equals("ChatGPT", StringComparison.OrdinalIgnoreCase))
        {
            return new("chatgpt", null);
        }
        if (processName.Equals("Typeless", StringComparison.OrdinalIgnoreCase))
        {
            return new("typeless", null);
        }
        var instanceId = ParseCodexInstanceId(windowTitle);
        var officialNpmCodex = processName.Equals("codex", StringComparison.OrdinalIgnoreCase) &&
            executablePath?.Contains("\\node_modules\\@openai\\codex\\", StringComparison.OrdinalIgnoreCase) == true;
        if (officialNpmCodex)
        {
            return new("codex_cli", instanceId, IsTerminal: false);
        }

        var terminal = processName.Equals("WindowsTerminal", StringComparison.OrdinalIgnoreCase) ||
            processName.Equals("powershell", StringComparison.OrdinalIgnoreCase) ||
            processName.Equals("pwsh", StringComparison.OrdinalIgnoreCase) ||
            processName.Equals("cmd", StringComparison.OrdinalIgnoreCase) ||
            processName.Equals("conhost", StringComparison.OrdinalIgnoreCase);
        var hasMarker = windowTitle?.StartsWith(CodexCliWindowMarker, StringComparison.OrdinalIgnoreCase) == true;
        var isCodexTitleCandidate = hasMarker || IsLikelyCodexDynamicTitle(windowTitle);
        return terminal && hasMarker
            ? new("codex_cli", instanceId, IsTerminal: true, IsCodexTitleCandidate: true)
            : new(null, null, IsTerminal: terminal, IsCodexTitleCandidate: terminal && isCodexTitleCandidate);
    }

    public static bool IsLikelyCodexDynamicTitle(string? windowTitle) =>
        windowTitle is { Length: >= 3 } &&
        "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏".Contains(windowTitle[0]) &&
        char.IsWhiteSpace(windowTitle[1]);

    public static string? ParseCodexInstanceId(string? windowTitle)
    {
        const int instanceIdLength = 32;
        var prefix = CodexCliWindowMarker + " - ";
        if (windowTitle is null || !windowTitle.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }
        var instanceId = windowTitle[prefix.Length..];
        return instanceId.Length == instanceIdLength && instanceId.All(Uri.IsHexDigit)
            ? instanceId.ToLowerInvariant()
            : null;
    }

    private static bool IsTypelessRunning()
    {
        var processes = Process.GetProcessesByName("Typeless");
        try
        {
            return processes.Length > 0;
        }
        finally
        {
            foreach (var process in processes)
            {
                process.Dispose();
            }
        }
    }

    private static string GetTitle(IntPtr window)
    {
        var length = GetWindowTextLengthW(window);
        if (length <= 0)
        {
            return string.Empty;
        }
        var builder = new StringBuilder(length + 1);
        _ = GetWindowTextW(window, builder, builder.Capacity);
        return builder.ToString();
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextW(IntPtr window, StringBuilder text, int maxCount);

    [DllImport("user32.dll")]
    private static extern int GetWindowTextLengthW(IntPtr window);
}
