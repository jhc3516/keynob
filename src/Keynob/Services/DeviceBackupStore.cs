using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Keynob.Services;

public sealed record DeviceLedSnapshot(int Mode, string ColorsHex);

public sealed record DeviceBackup(
    int SchemaVersion,
    string VendorId,
    string ProductId,
    int Interface,
    string UsagePage,
    string Layout,
    string? ReportedSerial,
    int Layer,
    Dictionary<int, string> Slots,
    DeviceLedSnapshot Led,
    DateTimeOffset CreatedUtc,
    string Checksum);

public sealed record DeviceBackupLoadResult(bool Ok, DeviceBackup? Backup, string? Error);

public sealed class DeviceBackupStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    public DeviceBackupStore(string settingsPath, string? backupPath = null)
    {
        var dataDirectory = Path.GetDirectoryName(settingsPath)
            ?? throw new InvalidOperationException("settings_directory_missing");
        BackupPath = backupPath ?? Path.Combine(dataDirectory, "backups", "latest.json");
    }

    public string BackupPath { get; }

    public async Task<DeviceBackup> SaveAsync(
        int layer,
        IReadOnlyDictionary<int, string> slots,
        DeviceLedSnapshot led,
        string? reportedSerial,
        CancellationToken cancellationToken = default)
    {
        var backup = new DeviceBackup(
            1, "514C", "8850", 0, "FF00", "12-key-2-knob", reportedSerial,
            layer, new Dictionary<int, string>(slots), led, DateTimeOffset.UtcNow, "");
        backup = backup with { Checksum = ComputeChecksum(backup) };
        Validate(backup);

        var directory = Path.GetDirectoryName(BackupPath)
            ?? throw new InvalidOperationException("backup_directory_missing");
        Directory.CreateDirectory(directory);
        var temporaryPath = BackupPath + ".tmp";
        try
        {
            await using (var stream = new FileStream(
                temporaryPath, FileMode.Create, FileAccess.Write, FileShare.None, 4096,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await JsonSerializer.SerializeAsync(stream, backup, JsonOptions, cancellationToken);
                await stream.FlushAsync(cancellationToken);
                stream.Flush(true);
            }
            if (File.Exists(BackupPath)) File.Replace(temporaryPath, BackupPath, null);
            else File.Move(temporaryPath, BackupPath);
            return backup;
        }
        finally
        {
            if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
        }
    }

    public async Task<DeviceBackupLoadResult> LoadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(BackupPath)) return new(false, null, "backup_missing");
        try
        {
            var json = await File.ReadAllTextAsync(BackupPath, cancellationToken);
            var backup = JsonSerializer.Deserialize<DeviceBackup>(json, JsonOptions)
                ?? throw new InvalidDataException("empty_backup");
            Validate(backup);
            return new(true, backup, null);
        }
        catch (Exception exception) when (exception is JsonException or InvalidDataException or IOException or UnauthorizedAccessException)
        {
            return new(false, null, exception.Message);
        }
    }

    public static void Validate(DeviceBackup backup)
    {
        if (backup.SchemaVersion != 1 || backup.VendorId != "514C" || backup.ProductId != "8850" ||
            backup.Interface != 0 || backup.UsagePage != "FF00" || backup.Layout != "12-key-2-knob" ||
            backup.Layer is < 1 or > 3 || backup.Slots is null || backup.Slots.Count != 25 ||
            backup.Led is null || backup.Led.Mode is < 0 or > 5 || backup.Led.ColorsHex is null)
        {
            throw new InvalidDataException("invalid_backup_metadata");
        }
        for (var slot = 1; slot <= 25; slot++)
        {
            if (!backup.Slots.TryGetValue(slot, out var hex) || string.IsNullOrEmpty(hex) || hex.Length != 128)
            {
                throw new InvalidDataException("invalid_backup_slots");
            }
            try
            {
                var report = Convert.FromHexString(hex);
                if (report[0] != 0x03 || report[1] != 0xFA || report[2] != slot || report[3] != backup.Layer)
                {
                    throw new InvalidDataException("invalid_backup_slots");
                }
            }
            catch (FormatException)
            {
                throw new InvalidDataException("invalid_backup_slots");
            }
        }
        try
        {
            if (Convert.FromHexString(backup.Led.ColorsHex).Length != 36)
            {
                throw new InvalidDataException("invalid_backup_led");
            }
        }
        catch (FormatException)
        {
            throw new InvalidDataException("invalid_backup_led");
        }
        if (!string.Equals(backup.Checksum, ComputeChecksum(backup), StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("backup_checksum_mismatch");
        }
    }

    private static string ComputeChecksum(DeviceBackup backup)
    {
        var canonical = JsonSerializer.Serialize(backup with { Checksum = "" }, JsonOptions);
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical))).ToLowerInvariant();
    }
}
