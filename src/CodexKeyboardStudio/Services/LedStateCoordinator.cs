using CodexKeyboardStudio.Models;

namespace CodexKeyboardStudio.Services;

public interface ILedDevice
{
    Task<LedWriteResult> SetLedAsync(string color, CancellationToken cancellationToken = default);
    Task<LedWriteResult> SetLedLayoutAsync(IReadOnlyList<string> colors, CancellationToken cancellationToken = default);
}

public sealed record LedApplyResult(bool Ok, bool Written, string? Error);

public sealed class NoWriteLedDevice : ILedDevice
{
    public Task<LedWriteResult> SetLedAsync(string color, CancellationToken cancellationToken = default) =>
        Task.FromResult(new LedWriteResult(true, null, false));

    public Task<LedWriteResult> SetLedLayoutAsync(
        IReadOnlyList<string> colors,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new LedWriteResult(true, null, false));
}

public sealed class LedStateCoordinator(ILedDevice device)
{
    private static readonly HashSet<string> AllowedColors = StudioSettingsCatalog.LedColors
        .Select(color => color.Id)
        .ToHashSet(StringComparer.Ordinal);

    private readonly SemaphoreSlim _gate = new(1, 1);
    private string? _lastSuccessfulLayout;
    private string[]? _lastSuccessfulColors;

    public string? LastSuccessfulLayout => _lastSuccessfulLayout;
    public IReadOnlyList<string>? LastSuccessfulColors => _lastSuccessfulColors?.ToArray();

    public void Invalidate()
    {
        _lastSuccessfulLayout = null;
        _lastSuccessfulColors = null;
    }

    public Task<LedApplyResult> ApplyColorAsync(string color, CancellationToken cancellationToken = default) =>
        ApplyLayoutAsync(Enumerable.Repeat(color, 12).ToArray(), cancellationToken);

    public async Task<LedApplyResult> ApplyLayoutAsync(
        IReadOnlyList<string> colors,
        CancellationToken cancellationToken = default)
    {
        if (colors.Count != 12 || colors.Any(color => !AllowedColors.Contains(color)))
        {
            return new(false, false, "unsupported_color");
        }

        var layoutKey = string.Join(',', colors);

        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (string.Equals(_lastSuccessfulLayout, layoutKey, StringComparison.Ordinal))
            {
                return new(true, false, null);
            }

            var result = colors.All(color => color == colors[0])
                ? await device.SetLedAsync(colors[0], cancellationToken)
                : await device.SetLedLayoutAsync(colors, cancellationToken);
            if (!result.Ok)
            {
                return new(false, false, result.Error);
            }
            _lastSuccessfulLayout = layoutKey;
            _lastSuccessfulColors = colors.ToArray();
            return new(true, result.Written, null);
        }
        finally
        {
            _gate.Release();
        }
    }
}
