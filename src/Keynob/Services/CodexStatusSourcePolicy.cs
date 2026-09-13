using System.Text.RegularExpressions;

namespace Keynob.Services;

public static class CodexStatusSourceKinds
{
    public const string Unscoped = "unscoped";
    public const string DedicatedCli = "dedicated_cli";
    public const string JsonExec = "json_exec";
    public const string ManualTest = "manual_test";

    public static bool IsSupported(string sourceKind) => sourceKind is
        Unscoped or DedicatedCli or JsonExec or ManualTest;
}

public sealed record CodexSourceDecision(bool Accepted, string Reason);

public interface ICodexProducerLifetime
{
    bool TryObserve(string sourceKind, string instanceId, int processId);
    bool IsRegistered(string sourceKind, string instanceId);
}

public sealed partial class CodexStatusSourcePolicy(
    ICodexProducerLifetime lifetime,
    bool allowManualTestSource = false)
{
    public CodexSourceDecision Evaluate(CodexHookEvent hookEvent)
    {
        if (hookEvent.SourceKind == CodexStatusSourceKinds.Unscoped)
        {
            return new(false, "unscoped");
        }
        if (!CodexStatusSourceKinds.IsSupported(hookEvent.SourceKind))
        {
            return new(false, "unsupported_source");
        }
        if (hookEvent.SourceKind == CodexStatusSourceKinds.ManualTest && !allowManualTestSource)
        {
            return new(false, "test_source_disabled");
        }
        if (string.IsNullOrWhiteSpace(hookEvent.InstanceId))
        {
            return new(false, "instance_missing");
        }

        if (hookEvent.EventName == "InstanceEnd")
        {
            return hookEvent.SourceKind == CodexStatusSourceKinds.DedicatedCli &&
                lifetime.IsRegistered(hookEvent.SourceKind, hookEvent.InstanceId)
                ? new(true, "registered_terminal")
                : new(false, "unregistered_terminal");
        }

        var processId = hookEvent.SourceKind switch
        {
            CodexStatusSourceKinds.DedicatedCli => hookEvent.LauncherProcessId,
            CodexStatusSourceKinds.JsonExec or CodexStatusSourceKinds.ManualTest => hookEvent.ProducerProcessId,
            _ => null
        };
        if (processId is not > 0)
        {
            return new(false, "producer_missing");
        }
        if (hookEvent.SourceKind == CodexStatusSourceKinds.DedicatedCli &&
            !DedicatedInstancePattern().IsMatch(hookEvent.InstanceId))
        {
            return new(false, "dedicated_instance_invalid");
        }

        return lifetime.TryObserve(hookEvent.SourceKind, hookEvent.InstanceId, processId.Value)
            ? new(true, "producer_verified")
            : new(false, "producer_rejected");
    }

    [GeneratedRegex("^[0-9a-f]{32}$", RegexOptions.CultureInvariant)]
    private static partial Regex DedicatedInstancePattern();
}
