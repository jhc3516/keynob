using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using CodexKeyboardStudio.Models;

namespace CodexKeyboardStudio.Services;

public sealed class SettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    public SettingsStore(string? settingsPath = null)
    {
        var dataRoot = Environment.GetEnvironmentVariable("CODEX_KEYBOARD_STUDIO_DATA_DIR");
        SettingsPath = settingsPath ?? Path.Combine(
            string.IsNullOrWhiteSpace(dataRoot)
                ? Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "CodexKeyboardStudio")
                : Path.GetFullPath(dataRoot),
            "settings.json");
    }

    public string SettingsPath { get; }

    public async Task<SettingsLoadResult> LoadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(SettingsPath))
        {
            return new(true, StudioSettingsCatalog.CreateDefault(), true, false, null);
        }

        try
        {
            var json = await File.ReadAllTextAsync(SettingsPath, cancellationToken);
            using var document = JsonDocument.Parse(json);
            if (!document.RootElement.TryGetProperty("schemaVersion", out var versionProperty) ||
                !versionProperty.TryGetInt32(out var version))
            {
                throw new InvalidDataException("missing_schema_version");
            }

            StudioSettings settings;
            var migrated = false;
            if (version == 1)
            {
                var legacy = JsonSerializer.Deserialize<LegacyStudioSettings>(json, JsonOptions)
                    ?? throw new InvalidDataException("empty_settings");
                if (legacy.SchemaVersion != 1 || legacy.Device is null || legacy.Inputs is null ||
                    legacy.StatusColors is null || legacy.KeyColors is null ||
                    legacy.Inputs.Count != StudioSettingsCatalog.InputIds.Count ||
                    StudioSettingsCatalog.InputIds.Any(id => !legacy.Inputs.ContainsKey(id)) ||
                    legacy.Inputs.Keys.Any(id => !StudioSettingsCatalog.InputIds.Contains(id, StringComparer.Ordinal)) ||
                    legacy.Inputs.Values.Any(binding => binding is null ||
                        !StudioSettingsCatalog.BuiltInActions.Any(action =>
                            action.Scope == binding.TargetAppId && action.Id == binding.ActionId)))
                {
                    throw new InvalidDataException("invalid_legacy_settings");
                }
                settings = StudioSettingsCatalog.CreateV1Imported(
                    legacy.Inputs.ToDictionary(
                        pair => pair.Key,
                        pair => (pair.Value.TargetAppId, pair.Value.ActionId),
                        StringComparer.Ordinal),
                    legacy.Device,
                    legacy.StatusColors,
                    legacy.KeyColors,
                    legacy.StartWithWindows);
                migrated = true;
            }
            else if (version == 2)
            {
                var legacy = JsonSerializer.Deserialize<LegacyV2StudioSettings>(json, JsonOptions)
                    ?? throw new InvalidDataException("empty_settings");
                ValidateLegacyV2(legacy);
                settings = StudioSettingsCatalog.CreateV2Imported(
                    legacy.Inputs,
                    legacy.Device,
                    legacy.StatusColors,
                    legacy.KeyColors,
                    legacy.RestoreKeyColorsAfterCodexCompletion,
                    legacy.StartWithWindows);
                migrated = true;
            }
            else
            {
                settings = JsonSerializer.Deserialize<StudioSettings>(json, JsonOptions)
                    ?? throw new InvalidDataException("empty_settings");
            }
            StudioSettingsCatalog.Validate(settings);
            return new(true, settings, false, migrated, null);
        }
        catch (Exception exception) when (exception is JsonException or InvalidDataException or IOException or UnauthorizedAccessException)
        {
            return new(false, StudioSettingsCatalog.CreateDefault(), false, false, exception.Message);
        }
    }

    public async Task SaveAsync(StudioSettings settings, CancellationToken cancellationToken = default)
    {
        StudioSettingsCatalog.Validate(settings);

        var directory = Path.GetDirectoryName(SettingsPath)
            ?? throw new InvalidOperationException("settings_directory_missing");
        Directory.CreateDirectory(directory);
        var temporaryPath = SettingsPath + ".tmp";

        try
        {
            await using (var stream = new FileStream(
                temporaryPath, FileMode.Create, FileAccess.Write, FileShare.None, 4096,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await JsonSerializer.SerializeAsync(stream, settings, JsonOptions, cancellationToken);
                await stream.FlushAsync(cancellationToken);
                stream.Flush(true);
            }

            if (File.Exists(SettingsPath))
            {
                File.Replace(temporaryPath, SettingsPath, null);
            }
            else
            {
                File.Move(temporaryPath, SettingsPath);
            }
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private static void ValidateLegacyV2(LegacyV2StudioSettings settings)
    {
        if (settings.SchemaVersion != 2 || settings.Device is null || settings.Inputs is null ||
            settings.StatusColors is null || settings.KeyColors is null ||
            settings.Inputs.Count != StudioSettingsCatalog.InputIds.Count ||
            StudioSettingsCatalog.InputIds.Any(id => !settings.Inputs.ContainsKey(id)) ||
            settings.Inputs.Keys.Any(id => !StudioSettingsCatalog.InputIds.Contains(id, StringComparer.Ordinal)) ||
            settings.Inputs.Values.Any(binding => binding is null))
        {
            throw new InvalidDataException("invalid_v2_settings");
        }

        var migrated = StudioSettingsCatalog.CreateV2Imported(
            settings.Inputs,
            settings.Device,
            settings.StatusColors,
            settings.KeyColors,
            settings.RestoreKeyColorsAfterCodexCompletion,
            settings.StartWithWindows);
        StudioSettingsCatalog.Validate(migrated);
    }
}

public sealed record SettingsLoadResult(
    bool Ok,
    StudioSettings Settings,
    bool IsDefault,
    bool WasMigrated,
    string? Error);

internal sealed class LegacyStudioSettings
{
    [JsonRequired]
    public int SchemaVersion { get; init; }
    [JsonRequired]
    public DeviceIdentity Device { get; init; } = new();
    [JsonRequired]
    public Dictionary<string, LegacyInputBinding> Inputs { get; init; } = [];
    [JsonRequired]
    public StatusColorSettings StatusColors { get; init; } = new();
    public Dictionary<string, string> KeyColors { get; init; } = [];
    public bool StartWithWindows { get; init; }
}

internal sealed class LegacyInputBinding
{
    [JsonRequired]
    public string TargetAppId { get; init; } = string.Empty;
    [JsonRequired]
    public string ActionId { get; init; } = string.Empty;
}

internal sealed class LegacyV2StudioSettings
{
    [JsonRequired]
    public int SchemaVersion { get; init; }
    [JsonRequired]
    public DeviceIdentity Device { get; init; } = new();
    [JsonRequired]
    public Dictionary<string, InputBinding> Inputs { get; init; } = [];
    [JsonRequired]
    public StatusColorSettings StatusColors { get; init; } = new();
    public Dictionary<string, string> KeyColors { get; init; } = [];
    public bool RestoreKeyColorsAfterCodexCompletion { get; init; } = true;
    public bool StartWithWindows { get; init; }
}
