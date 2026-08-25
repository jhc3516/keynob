using System.Diagnostics;
using System.IO;
using System.Text.Json;
using CodexKeyboardStudio.Models;

namespace CodexKeyboardStudio.Services;

public sealed class DeviceBridgeClient : ILedDevice
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    public async Task<DeviceProbeResult> DiscoverAsync(CancellationToken cancellationToken = default)
    {
        var bridgePath = Path.Combine(AppContext.BaseDirectory, "KeyboardDeviceBridge.exe");
        if (!File.Exists(bridgePath))
        {
            return new(false, false, "device_bridge_missing");
        }

        try
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = bridgePath,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                }
            };
            process.StartInfo.ArgumentList.Add("discover");
            process.Start();

            var stdoutTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken);
            var stdout = await stdoutTask;
            var stderr = await stderrTask;

            var response = JsonSerializer.Deserialize<DeviceProbeResponse>(stdout, JsonOptions);
            if (process.ExitCode != 0 || response is null)
            {
                var error = response?.Error ?? stderr.Trim();
                return new(false, false, string.IsNullOrWhiteSpace(error) ? "device_bridge_failed" : error);
            }

            return new(response.Ok, response.Connected, response.Error, response.Serial);
        }
        catch (Exception exception)
        {
            return new(false, false, exception.Message);
        }
    }

    public Task<LayerReadResult> ReadLayer1Async(CancellationToken cancellationToken = default) =>
        ReadLayerAsync(1, cancellationToken);

    public async Task<LedReadResult> ReadLedAsync(CancellationToken cancellationToken = default)
    {
        var bridgePath = Path.Combine(AppContext.BaseDirectory, "KeyboardDeviceBridge.exe");
        if (!File.Exists(bridgePath)) return new(false, null, "device_bridge_missing");
        try
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = bridgePath,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                }
            };
            process.StartInfo.ArgumentList.Add("read-led");
            process.Start();
            var stdoutTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken);
            var stdout = await stdoutTask;
            var stderr = await stderrTask;
            var response = JsonSerializer.Deserialize<LedReadResponse>(stdout, JsonOptions);
            if (process.ExitCode != 0 || response is null || !response.Ok ||
                response.Mode is < 0 or > 5 || response.ColorsHex?.Length != 72)
            {
                var error = response?.Error ?? stderr.Trim();
                return new(false, null, string.IsNullOrWhiteSpace(error) ? "led_read_failed" : error);
            }
            try
            {
                if (Convert.FromHexString(response.ColorsHex).Length != 36) return new(false, null, "invalid_led_response");
            }
            catch (FormatException)
            {
                return new(false, null, "invalid_led_response");
            }
            return new(true, new DeviceLedSnapshot(response.Mode, response.ColorsHex), null);
        }
        catch (Exception exception)
        {
            return new(false, null, exception.Message);
        }
    }

    public async Task<LayerReadResult> ReadLayerAsync(
        int layer,
        CancellationToken cancellationToken = default)
    {
        if (!StudioSettingsCatalog.LayerIds.Contains(layer))
        {
            return new(false, new Dictionary<int, string>(), "invalid_layer", layer);
        }
        var bridgePath = Path.Combine(AppContext.BaseDirectory, "KeyboardDeviceBridge.exe");
        if (!File.Exists(bridgePath))
        {
            return new(false, new Dictionary<int, string>(), "device_bridge_missing");
        }

        try
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = bridgePath,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                }
            };
            process.StartInfo.ArgumentList.Add("read-layer");
            process.StartInfo.ArgumentList.Add(layer.ToString());
            process.Start();

            var stdoutTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken);
            var stdout = await stdoutTask;
            var stderr = await stderrTask;

            var response = JsonSerializer.Deserialize<LayerReadResponse>(stdout, JsonOptions);
            if (process.ExitCode != 0 || response is null || !response.Ok)
            {
                var error = response?.Error ?? stderr.Trim();
                return new(false, new Dictionary<int, string>(), string.IsNullOrWhiteSpace(error) ? "keymap_read_failed" : error);
            }

            var slots = response.Slots ?? [];
            if (response.Layer != layer || slots.Length != 25 ||
                slots.Select(slot => slot.Slot).Distinct().Count() != 25 ||
                slots.Any(slot => !IsLayerSlotResponse(layer, slot)))
            {
                return new(false, new Dictionary<int, string>(), "invalid_keymap_response", layer);
            }

            return new(true, slots.ToDictionary(slot => slot.Slot, slot => slot.Hex), null, layer);
        }
        catch (Exception exception)
        {
            return new(false, new Dictionary<int, string>(), exception.Message, layer);
        }
    }

    private static bool IsLayerSlotResponse(int layer, LayerSlotResponse slot)
    {
        if (slot.Slot is < 1 or > 25 || slot.Hex.Length != 128)
        {
            return false;
        }
        try
        {
            var report = Convert.FromHexString(slot.Hex);
            return report[0] == 0x03 && report[1] == 0xFA && report[2] == slot.Slot &&
                report[3] == layer;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    public async Task<InputProgramResult> ProgramInputAsync(
        string inputId,
        string expectedHex,
        CancellationToken cancellationToken = default)
    {
        var bridgePath = Path.Combine(AppContext.BaseDirectory, "KeyboardDeviceBridge.exe");
        if (!File.Exists(bridgePath))
        {
            return new(false, false, false, 0, null, "device_bridge_missing");
        }

        try
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = bridgePath,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                }
            };
            process.StartInfo.ArgumentList.Add("program-input");
            process.StartInfo.ArgumentList.Add(inputId);
            process.StartInfo.ArgumentList.Add(expectedHex);
            process.Start();

            var stdoutTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken);
            var stdout = await stdoutTask;
            var stderr = await stderrTask;
            var response = JsonSerializer.Deserialize<InputProgramResponse>(stdout, JsonOptions);
            if (process.ExitCode != 0 || response is null || !response.Ok || !response.Verified ||
                response.ReportsWritten is not (0 or 2) || response.Hex?.Length != 128)
            {
                var error = response?.Error ?? stderr.Trim();
                return new(
                    false,
                    false,
                    false,
                    0,
                    null,
                    string.IsNullOrWhiteSpace(error) ? "input_program_failed" : error,
                    response?.RestoreAttempted == true,
                    response?.RestoreVerified == true);
            }
            return new(true, response.Changed, response.Verified, response.ReportsWritten, response.Hex, null);
        }
        catch (Exception exception)
        {
            return new(false, false, false, 0, null, exception.Message);
        }
    }

    public async Task<InputProgramResult> ProgramReportAsync(
        string inputId,
        string expectedHex,
        string replacementHex,
        CancellationToken cancellationToken = default)
        => await ProgramReportAsync(1, inputId, expectedHex, replacementHex, cancellationToken);

    public async Task<InputProgramResult> ProgramReportAsync(
        int layer,
        string inputId,
        string expectedHex,
        string replacementHex,
        CancellationToken cancellationToken = default)
    {
        if (!DeviceReportEncoder.MatchesInputSlot(layer, inputId, expectedHex) ||
            !DeviceReportEncoder.MatchesInputSlot(layer, inputId, replacementHex))
        {
            return new(false, false, false, 0, null, "invalid_slot_report");
        }
        return await RunProgramCommandAsync(
            "program-report",
            [layer.ToString(), inputId, expectedHex, replacementHex],
            layer,
            cancellationToken);
    }

    public async Task<BatchProgramResult> ApplyBindingsAsync(
        StudioSettings settings,
        IReadOnlyDictionary<int, string> currentSlots,
        CancellationToken cancellationToken = default)
        => await ApplyBindingsAsync(1, settings, currentSlots, cancellationToken);

    public async Task<BatchProgramResult> ApplyBindingsAsync(
        int layer,
        StudioSettings settings,
        IReadOnlyDictionary<int, string> currentSlots,
        CancellationToken cancellationToken = default)
    {
        StudioSettingsCatalog.Validate(settings);
        var compiled = BindingCompiler.CompileLayer(settings, layer);
        var changes = new List<DeviceSlotChange>();
        foreach (var inputId in StudioSettingsCatalog.InputIds)
        {
            if (!InputAliasCatalog.TryGetByInputId(layer, inputId, out var alias) ||
                !currentSlots.TryGetValue(alias.Slot, out var originalHex) ||
                !DeviceReportEncoder.MatchesInputSlot(layer, inputId, originalHex) ||
                !DeviceReportEncoder.IsSupportedReport(layer, inputId, originalHex))
            {
                return new(false, false, [], "unsupported_current_slot");
            }
            var replacementHex = DeviceReportEncoder.EncodeHex(compiled[inputId]);
            if (!string.Equals(originalHex, replacementHex, StringComparison.OrdinalIgnoreCase))
            {
                changes.Add(new(inputId, alias.Slot, originalHex, replacementHex, layer));
            }
        }
        return await BatchProgramCoordinator.ApplyAsync(
            changes,
            (change, rollback, token) => rollback
                ? RestoreReportAsync(
                    change.Layer, change.InputId, change.ReplacementHex, change.OriginalHex, token)
                : ProgramReportAsync(
                    change.Layer, change.InputId, change.OriginalHex, change.ReplacementHex, token),
            cancellationToken);
    }

    public async Task<BatchProgramResult> RestoreSnapshotAsync(
        IReadOnlyDictionary<int, string> originalSlots,
        IReadOnlyDictionary<int, string> currentSlots,
        CancellationToken cancellationToken = default)
        => await RestoreSnapshotAsync(1, originalSlots, currentSlots, cancellationToken);

    public async Task<BatchProgramResult> RestoreSnapshotAsync(
        int layer,
        IReadOnlyDictionary<int, string> originalSlots,
        IReadOnlyDictionary<int, string> currentSlots,
        CancellationToken cancellationToken = default)
    {
        var changes = PlanSnapshotRestore(layer, originalSlots, currentSlots);
        if (changes is null)
        {
            return new(false, false, [], "invalid_restore_snapshot");
        }
        return await BatchProgramCoordinator.ApplyAsync(
            changes,
            (change, rollback, token) => RestoreReportAsync(
                change.Layer,
                change.InputId,
                rollback ? change.ReplacementHex : change.OriginalHex,
                rollback ? change.OriginalHex : change.ReplacementHex,
                token),
            cancellationToken);
    }

    private async Task<InputProgramResult> RestoreReportAsync(
        int layer,
        string inputId,
        string expectedHex,
        string replacementHex,
        CancellationToken cancellationToken)
    {
        if (!DeviceReportEncoder.MatchesInputSlot(layer, inputId, expectedHex) ||
            !DeviceReportEncoder.MatchesInputSlot(layer, inputId, replacementHex) ||
            !DeviceReportEncoder.IsSupportedReport(layer, inputId, replacementHex))
        {
            return new(false, false, false, 0, null, "invalid_restore_slot");
        }
        return await RunProgramCommandAsync(
            "restore-report",
            [layer.ToString(), inputId, expectedHex, replacementHex],
            layer,
            cancellationToken);
    }

    public static IReadOnlyList<DeviceSlotChange>? PlanSnapshotRestore(
        IReadOnlyDictionary<int, string> originalSlots,
        IReadOnlyDictionary<int, string> currentSlots)
        => PlanSnapshotRestore(1, originalSlots, currentSlots);

    public static IReadOnlyList<DeviceSlotChange>? PlanSnapshotRestore(
        int layer,
        IReadOnlyDictionary<int, string> originalSlots,
        IReadOnlyDictionary<int, string> currentSlots)
    {
        var changes = new List<DeviceSlotChange>();
        foreach (var inputId in StudioSettingsCatalog.InputIds)
        {
            if (!InputAliasCatalog.TryGetByInputId(layer, inputId, out var alias) ||
                !originalSlots.TryGetValue(alias.Slot, out var originalHex) ||
                !currentSlots.TryGetValue(alias.Slot, out var currentHex) ||
                !DeviceReportEncoder.MatchesInputSlot(layer, inputId, originalHex) ||
                !DeviceReportEncoder.MatchesInputSlot(layer, inputId, currentHex) ||
                !DeviceReportEncoder.IsSupportedReport(layer, inputId, originalHex) ||
                !DeviceReportEncoder.IsSupportedReport(layer, inputId, currentHex))
            {
                return null;
            }
            if (!string.Equals(originalHex, currentHex, StringComparison.OrdinalIgnoreCase))
            {
                changes.Add(new(inputId, alias.Slot, currentHex, originalHex, layer));
            }
        }
        return changes;
    }

    private static async Task<InputProgramResult> RunProgramCommandAsync(
        string command,
        IReadOnlyList<string> arguments,
        int expectedLayer,
        CancellationToken cancellationToken)
    {
        var bridgePath = Path.Combine(AppContext.BaseDirectory, "KeyboardDeviceBridge.exe");
        if (!File.Exists(bridgePath))
        {
            return new(false, false, false, 0, null, "device_bridge_missing");
        }

        try
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = bridgePath,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                }
            };
            process.StartInfo.ArgumentList.Add(command);
            foreach (var argument in arguments) process.StartInfo.ArgumentList.Add(argument);
            process.Start();
            var stdoutTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken);
            var stdout = await stdoutTask;
            var stderr = await stderrTask;
            var response = JsonSerializer.Deserialize<InputProgramResponse>(stdout, JsonOptions);
            if (process.ExitCode != 0 || response is null || !response.Ok || !response.Verified ||
                response.Layer != expectedLayer ||
                response.ReportsWritten is not (0 or 2) || response.Hex?.Length != 128)
            {
                var error = response?.Error ?? stderr.Trim();
                return new(
                    false,
                    false,
                    false,
                    0,
                    null,
                    string.IsNullOrWhiteSpace(error) ? "input_program_failed" : error,
                    response?.RestoreAttempted == true,
                    response?.RestoreVerified == true);
            }
            return new(true, response.Changed, response.Verified, response.ReportsWritten, response.Hex, null);
        }
        catch (Exception exception)
        {
            return new(false, false, false, 0, null, exception.Message);
        }
    }

    public async Task<LedWriteResult> SetLedAsync(string color, CancellationToken cancellationToken = default)
    {
        return await SetLedCommandAsync("set-led", [color], cancellationToken);
    }

    public async Task<LedWriteResult> SetLedLayoutAsync(
        IReadOnlyList<string> colors,
        CancellationToken cancellationToken = default)
    {
        if (colors.Count != 12)
        {
            return new(false, "invalid_led_layout");
        }
        return await SetLedCommandAsync("set-led-layout", colors, cancellationToken);
    }

    public async Task<LedWriteResult> RestoreLedAsync(
        DeviceLedSnapshot snapshot,
        CancellationToken cancellationToken = default)
    {
        if (snapshot.Mode is < 0 or > 5 || snapshot.ColorsHex.Length != 72)
        {
            return new(false, "invalid_led_snapshot");
        }
        return await SetLedCommandAsync(
            "restore-led", [snapshot.Mode.ToString(), snapshot.ColorsHex], cancellationToken);
    }

    private static async Task<LedWriteResult> SetLedCommandAsync(
        string command,
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken)
    {
        var bridgePath = Path.Combine(AppContext.BaseDirectory, "KeyboardDeviceBridge.exe");
        if (!File.Exists(bridgePath))
        {
            return new(false, "device_bridge_missing");
        }

        try
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = bridgePath,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                }
            };
            process.StartInfo.ArgumentList.Add(command);
            foreach (var argument in arguments)
            {
                process.StartInfo.ArgumentList.Add(argument);
            }
            process.Start();

            var stdoutTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken);
            var stdout = await stdoutTask;
            var stderr = await stderrTask;
            var response = JsonSerializer.Deserialize<LedWriteResponse>(stdout, JsonOptions);
            if (process.ExitCode != 0 || response is null || !response.Ok ||
                response.ReportsWritten is not (0 or 3))
            {
                var error = response?.Error ?? stderr.Trim();
                return new(
                    false,
                    string.IsNullOrWhiteSpace(error) ? "led_write_failed" : error,
                    false,
                    response?.RestoreAttempted == true,
                    response?.RestoreVerified == true);
            }
            return new(true, null, response.ReportsWritten > 0, false, true);
        }
        catch (Exception exception)
        {
            return new(false, exception.Message);
        }
    }

    private sealed record DeviceProbeResponse(bool Ok, bool Connected, string? Error, string? Serial);
    private sealed record LayerReadResponse(bool Ok, int Layer, LayerSlotResponse[]? Slots, string? Error);
    private sealed record LayerSlotResponse(int Slot, string Hex);
    private sealed record LedReadResponse(bool Ok, int Mode, string? ColorsHex, string? Error);
    private sealed record LedWriteResponse(
        bool Ok,
        int ReportsWritten,
        string? Error,
        bool RestoreAttempted = false,
        bool RestoreVerified = false);
    private sealed record InputProgramResponse(
        bool Ok,
        int Layer,
        bool Changed,
        bool Verified,
        int ReportsWritten,
        string? Hex,
        string? Error,
        bool RestoreAttempted = false,
        bool RestoreVerified = false);
}

public sealed record DeviceProbeResult(bool Ok, bool Connected, string? Error, string? Serial = null);
public sealed record LayerReadResult(
    bool Ok,
    IReadOnlyDictionary<int, string> Slots,
    string? Error,
    int Layer = 1)
{
    public int SlotCount => Slots.Count;
}
public sealed record LedReadResult(bool Ok, DeviceLedSnapshot? Snapshot, string? Error);
public sealed record LedWriteResult(
    bool Ok,
    string? Error,
    bool Written = true,
    bool RestoreAttempted = false,
    bool RestoreVerified = false);
public sealed record InputProgramResult(
    bool Ok,
    bool Changed,
    bool Verified,
    int ReportsWritten,
    string? Hex,
    string? Error,
    bool RestoreAttempted = false,
    bool RestoreVerified = false);
public sealed record BatchProgramResult(
    bool Ok,
    bool RollbackVerified,
    IReadOnlyList<int> ChangedSlots,
    string? Error);
public sealed record DeviceSlotChange(
    string InputId,
    int Slot,
    string OriginalHex,
    string ReplacementHex,
    int Layer = 1);

public static class BatchProgramCoordinator
{
    public static async Task<BatchProgramResult> ApplyAsync(
        IReadOnlyList<DeviceSlotChange> changes,
        Func<DeviceSlotChange, bool, CancellationToken, Task<InputProgramResult>> program,
        CancellationToken cancellationToken = default)
    {
        var completed = new List<DeviceSlotChange>();
        foreach (var change in changes)
        {
            var result = await program(change, false, cancellationToken);
            if (result.Ok && result.Verified)
            {
                completed.Add(change);
                continue;
            }

            var rollbackOk = !result.RestoreAttempted || result.RestoreVerified;
            foreach (var applied in completed.AsEnumerable().Reverse())
            {
                var rollback = await program(applied, true, CancellationToken.None);
                rollbackOk &= rollback.Ok && rollback.Verified;
            }
            return new(false, rollbackOk, [], rollbackOk
                ? result.Error ?? "batch_program_failed_rolled_back"
                : "batch_program_failed_rollback_failed");
        }
        return new(true, true, changes.Select(change => change.Slot).ToArray(), null);
    }
}

public sealed record SettingsPersistenceResult(
    bool Saved,
    bool RestoreAttempted,
    bool RestoreVerified,
    string? Error);

public static class SettingsPersistenceCoordinator
{
    public static async Task<SettingsPersistenceResult> SaveAsync(
        Func<CancellationToken, Task> save,
        Func<CancellationToken, Task<BatchProgramResult>> restore,
        CancellationToken cancellationToken = default)
    {
        try
        {
            await save(cancellationToken);
            return new(true, false, true, null);
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            var result = await restore(CancellationToken.None);
            return new(false, true, result.Ok && result.RollbackVerified, exception.Message);
        }
    }
}
