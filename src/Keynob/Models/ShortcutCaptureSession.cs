using System.IO;

namespace Keynob.Models;

public enum ShortcutCaptureState
{
    Idle,
    Recording,
    Completed,
    Cancelled,
    Invalid
}

public sealed record ShortcutCaptureUpdate(
    ShortcutCaptureState State,
    ShortcutDefinition? Shortcut = null,
    string? Error = null);

public sealed class ShortcutCaptureSession
{
    private readonly HashSet<string> _pressed = new(StringComparer.Ordinal);
    private readonly HashSet<string> _captured = new(StringComparer.Ordinal);

    public bool IsRecording { get; private set; }

    public ShortcutCaptureUpdate Begin()
    {
        _pressed.Clear();
        _captured.Clear();
        IsRecording = true;
        return new(ShortcutCaptureState.Recording);
    }

    public ShortcutCaptureUpdate KeyDown(string key)
    {
        if (!IsRecording) return new(ShortcutCaptureState.Idle);
        _pressed.Add(key);
        _captured.Add(key);
        return new(ShortcutCaptureState.Recording);
    }

    public ShortcutCaptureUpdate KeyUp(string key)
    {
        if (!IsRecording) return new(ShortcutCaptureState.Idle);
        return Complete();
    }

    public ShortcutCaptureUpdate Cancel()
    {
        IsRecording = false;
        _pressed.Clear();
        _captured.Clear();
        return new(ShortcutCaptureState.Cancelled);
    }

    private ShortcutCaptureUpdate Complete()
    {
        IsRecording = false;
        var modifiers = _captured.Where(ShortcutCatalog.IsModifier).ToList();
        var regularKeys = _captured.Where(key => !ShortcutCatalog.IsModifier(key)).ToArray();
        _pressed.Clear();
        _captured.Clear();
        if (regularKeys.Length > 1)
        {
            return new(ShortcutCaptureState.Invalid, Error: "multiple_regular_keys");
        }
        var shortcut = new ShortcutDefinition { Modifiers = modifiers, Key = regularKeys.SingleOrDefault() };
        try
        {
            _ = ShortcutCatalog.Normalize(shortcut);
            return new(ShortcutCaptureState.Completed, shortcut);
        }
        catch (InvalidDataException exception)
        {
            return new(ShortcutCaptureState.Invalid, Error: exception.Message);
        }
    }
}
