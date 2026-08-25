namespace CodexKeyboardStudio.Services;

public sealed class InputDeduplicator(TimeSpan window)
{
    private readonly Dictionary<string, long> _lastTicks = new(StringComparer.Ordinal);
    private readonly long _windowTicks = window.Ticks;

    public bool ShouldAccept(string inputId, DateTimeOffset timestamp)
    {
        var ticks = timestamp.UtcTicks;
        if (_lastTicks.TryGetValue(inputId, out var previous) && ticks - previous >= 0 && ticks - previous < _windowTicks)
        {
            return false;
        }
        _lastTicks[inputId] = ticks;
        return true;
    }
}
