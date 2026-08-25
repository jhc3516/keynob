using System.ComponentModel;
using System.Diagnostics;

namespace CodexKeyboardStudio.Services;

public sealed class CodexLauncherLifetimeTracker(
    Func<string, string, Task> exitFallback,
    DiagnosticLog log) : ICodexProducerLifetime, IDisposable
{
    private static readonly TimeSpan InstanceEndGracePeriod = TimeSpan.FromMilliseconds(300);
    private readonly object _gate = new();
    private readonly Dictionary<RegistrationKey, Registration> _registrations = [];
    private readonly CancellationTokenSource _cancellation = new();
    private bool _disposed;

    public bool TryObserve(string sourceKind, string instanceId, int processId)
    {
        if (string.IsNullOrWhiteSpace(instanceId) || processId <= 0 ||
            sourceKind is not (CodexStatusSourceKinds.DedicatedCli or
                CodexStatusSourceKinds.JsonExec or CodexStatusSourceKinds.ManualTest))
        {
            return false;
        }

        Process? process = null;
        DateTime startTime;
        try
        {
            process = Process.GetProcessById(processId);
            if (!IsExpectedProducer(sourceKind, process.ProcessName))
            {
                process.Dispose();
                LogRejected(sourceKind, instanceId, "process_name");
                return false;
            }
            startTime = process.StartTime.ToUniversalTime();
        }
        catch (Exception exception) when (
            exception is ArgumentException or InvalidOperationException or Win32Exception)
        {
            process?.Dispose();
            LogRejected(sourceKind, instanceId, "process_missing");
            return false;
        }

        var key = new RegistrationKey(sourceKind, instanceId);
        lock (_gate)
        {
            if (_disposed)
            {
                process.Dispose();
                return false;
            }
            if (_registrations.TryGetValue(key, out var existing))
            {
                process.Dispose();
                if (existing.ProcessId != processId || existing.StartTime != startTime)
                {
                    LogRejected(sourceKind, instanceId, "pid_changed");
                    return false;
                }
                return true;
            }

            try
            {
                process.EnableRaisingEvents = true;
            }
            catch (InvalidOperationException)
            {
                process.Dispose();
                LogRejected(sourceKind, instanceId, "process_exited");
                return false;
            }
            process.Exited += (_, _) => _ = HandleExitedAsync(key, processId, startTime);
            _registrations.Add(key, new(processId, startTime, process));
            LogStarted(sourceKind, instanceId, processId);
        }

        try
        {
            if (process.HasExited)
            {
                _ = HandleExitedAsync(key, processId, startTime);
            }
        }
        catch (InvalidOperationException)
        {
            // A concurrent InstanceEnd may have disposed the watcher already.
        }
        return true;
    }

    public bool IsRegistered(string sourceKind, string instanceId)
    {
        lock (_gate)
        {
            return _registrations.ContainsKey(new(sourceKind, instanceId));
        }
    }

    public void Complete(string sourceKind, string? instanceId)
    {
        if (string.IsNullOrWhiteSpace(instanceId))
        {
            return;
        }
        Registration? registration = null;
        var key = new RegistrationKey(sourceKind, instanceId);
        lock (_gate)
        {
            if (_registrations.Remove(key, out var removed))
            {
                registration = removed;
            }
        }
        registration?.Process.Dispose();
    }

    private async Task HandleExitedAsync(RegistrationKey key, int processId, DateTime startTime)
    {
        try
        {
            await Task.Delay(InstanceEndGracePeriod, _cancellation.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (_cancellation.IsCancellationRequested)
        {
            return;
        }

        Registration? registration = null;
        lock (_gate)
        {
            if (_registrations.TryGetValue(key, out var current) &&
                current.ProcessId == processId &&
                current.StartTime == startTime &&
                _registrations.Remove(key))
            {
                registration = current;
            }
        }
        if (registration is null)
        {
            return;
        }

        registration.Process.Dispose();
        LogExited(key.SourceKind, key.InstanceId, processId);
        try
        {
            await exitFallback(key.SourceKind, key.InstanceId).ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            log.Write("codex_launcher_exit_fallback_error", exception.GetType().Name);
        }
    }

    private static bool IsExpectedProducer(string sourceKind, string processName) => sourceKind switch
    {
        CodexStatusSourceKinds.DedicatedCli =>
            processName.Equals("Start-CodexCli", StringComparison.OrdinalIgnoreCase),
        CodexStatusSourceKinds.JsonExec or CodexStatusSourceKinds.ManualTest =>
            processName.Equals("powershell", StringComparison.OrdinalIgnoreCase) ||
            processName.Equals("pwsh", StringComparison.OrdinalIgnoreCase),
        _ => false
    };

    private void LogStarted(string sourceKind, string instanceId, int processId) =>
        log.Write(
            sourceKind == CodexStatusSourceKinds.DedicatedCli
                ? "codex_launcher_watch_started"
                : "codex_producer_watch_started",
            sourceKind == CodexStatusSourceKinds.DedicatedCli
                ? $"instance={instanceId};pid={processId};source={sourceKind}"
                : $"source={sourceKind};instance={instanceId};pid={processId}");

    private void LogRejected(string sourceKind, string instanceId, string reason) =>
        log.Write(
            sourceKind == CodexStatusSourceKinds.DedicatedCli
                ? "codex_launcher_watch_rejected"
                : "codex_producer_watch_rejected",
            sourceKind == CodexStatusSourceKinds.DedicatedCli
                ? $"instance={instanceId};reason={reason};source={sourceKind}"
                : $"source={sourceKind};instance={instanceId};reason={reason}");

    private void LogExited(string sourceKind, string instanceId, int processId) =>
        log.Write(
            sourceKind == CodexStatusSourceKinds.DedicatedCli
                ? "codex_launcher_exit_fallback"
                : "codex_producer_exit_fallback",
            sourceKind == CodexStatusSourceKinds.DedicatedCli
                ? $"instance={instanceId};pid={processId};source={sourceKind}"
                : $"source={sourceKind};instance={instanceId};pid={processId}");

    public void Dispose()
    {
        List<Registration> registrations;
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            _cancellation.Cancel();
            registrations = [.. _registrations.Values];
            _registrations.Clear();
        }
        foreach (var registration in registrations)
        {
            registration.Process.Dispose();
        }
        _cancellation.Dispose();
    }

    private readonly record struct RegistrationKey(string SourceKind, string InstanceId);
    private sealed record Registration(int ProcessId, DateTime StartTime, Process Process);
}
