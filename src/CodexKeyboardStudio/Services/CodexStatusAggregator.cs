namespace CodexKeyboardStudio.Services;

public sealed record CodexHookEvent(
    string EventName,
    string? SessionId,
    string? TurnId,
    string? InstanceId = null,
    int? LauncherProcessId = null,
    bool IsError = false,
    string SourceKind = CodexStatusSourceKinds.Unscoped,
    int? ProducerProcessId = null);

public sealed record CodexAggregateResult(
    string? Status,
    bool Changed,
    int ActiveSessionCount,
    string ActiveSourceSummary)
{
    public int SessionCount => ActiveSessionCount;
    public bool ActivityChanged { get; init; }
}

public sealed record CodexCancellationCandidate(
    string InstanceId,
    string SessionId,
    string TurnId);

public sealed class CodexStatusAggregator
{
    private static readonly IReadOnlyDictionary<string, int> Priority = new Dictionary<string, int>(StringComparer.Ordinal)
    {
        ["completed"] = 1,
        ["running"] = 2,
        ["error"] = 3,
        ["approval"] = 4
    };

    private readonly Dictionary<SessionKey, SessionState> _activeSessions = [];
    private readonly Dictionary<TurnKey, DateTimeOffset> _terminalTurns = [];
    private string? _terminalStatus;
    private DateTimeOffset? _stickyErrorAt;
    private int _currentActiveSessionCount;
    private string _currentActiveSourceSummary = "none";

    public string? CurrentStatus { get; private set; }

    public CodexAggregateResult EnsureCompleted(DateTimeOffset now)
    {
        lock (_activeSessions)
        {
            PruneTerminalTurns(now);
            if (CurrentStatus is null && _activeSessions.Count == 0)
            {
                _terminalStatus = "completed";
            }
            return Recalculate();
        }
    }

    public CodexAggregateResult Apply(CodexHookEvent hookEvent, DateTimeOffset now)
    {
        lock (_activeSessions)
        {
            PruneTerminalTurns(now);
            if (hookEvent.EventName == "InstanceEnd")
            {
                ApplyInstanceEnd(hookEvent, now);
                return Recalculate();
            }
            if (string.IsNullOrWhiteSpace(hookEvent.SessionId))
            {
                return Recalculate();
            }

            var key = new SessionKey(hookEvent.SourceKind, hookEvent.InstanceId, hookEvent.SessionId);
            _activeSessions.TryGetValue(key, out var existing);

            if (hookEvent.EventName == "SessionStart")
            {
                RetirePreviousSessionsForInstance(key, hookEvent, now);
                if (_activeSessions.Count == 0 && _stickyErrorAt is null)
                {
                    _terminalStatus = "completed";
                }
                return Recalculate();
            }
            if (hookEvent.EventName == "SessionEnd")
            {
                CompleteSession(key, existing, hookEvent.IsError || existing?.Status == "error", now);
                return Recalculate();
            }

            var turnId = hookEvent.TurnId ?? existing?.TurnId;
            if (string.IsNullOrWhiteSpace(turnId))
            {
                return Recalculate();
            }
            var turnKey = new TurnKey(key, turnId);
            if (_terminalTurns.ContainsKey(turnKey))
            {
                return Recalculate();
            }

            if (hookEvent.EventName == "UserPromptSubmit")
            {
                if (_stickyErrorAt is not null)
                {
                    _stickyErrorAt = null;
                    _terminalStatus = "completed";
                }
                _activeSessions[key] = new SessionState(
                    hookEvent.SessionId,
                    hookEvent.InstanceId,
                    hookEvent.SourceKind,
                    hookEvent.IsError ? "error" : "running",
                    turnId,
                    now,
                    null);
                return Recalculate();
            }

            if (existing?.TurnId is not null && hookEvent.TurnId is not null &&
                !string.Equals(existing.TurnId, hookEvent.TurnId, StringComparison.Ordinal))
            {
                return Recalculate();
            }

            if (hookEvent.EventName == "Stop")
            {
                var cancelled = string.Equals(existing?.CancellationPendingTurnId, turnId, StringComparison.Ordinal);
                CompleteSession(key, existing, hookEvent.IsError && !cancelled, now, turnId);
                return Recalculate();
            }

            var status = MapActiveStatus(hookEvent);
            if (status is null)
            {
                return Recalculate();
            }
            _activeSessions[key] = new SessionState(
                hookEvent.SessionId,
                hookEvent.InstanceId,
                hookEvent.SourceKind,
                status,
                turnId,
                now,
                existing?.CancellationPendingTurnId);
            return Recalculate();
        }
    }

    public CodexCancellationCandidate? BeginCancellation(string instanceId, DateTimeOffset now)
    {
        lock (_activeSessions)
        {
            PruneTerminalTurns(now);
            var pair = _activeSessions
                .Where(entry =>
                    entry.Value.SourceKind is CodexStatusSourceKinds.DedicatedCli or CodexStatusSourceKinds.ManualTest &&
                    string.Equals(entry.Value.InstanceId, instanceId, StringComparison.Ordinal) &&
                    entry.Value.Status is "running" or "approval" &&
                    !string.IsNullOrWhiteSpace(entry.Value.TurnId))
                .OrderByDescending(entry => entry.Value.UpdatedAt)
                .FirstOrDefault();
            if (pair.Value is null || pair.Value.CancellationPendingTurnId == pair.Value.TurnId)
            {
                return null;
            }
            _activeSessions[pair.Key] = pair.Value with
            {
                CancellationPendingTurnId = pair.Value.TurnId,
                UpdatedAt = now
            };
            return new(instanceId, pair.Value.SessionId, pair.Value.TurnId!);
        }
    }

    public CodexAggregateResult CompleteCancellation(CodexCancellationCandidate candidate, DateTimeOffset now)
    {
        lock (_activeSessions)
        {
            PruneTerminalTurns(now);
            var pair = _activeSessions.FirstOrDefault(entry =>
                entry.Value.SourceKind is CodexStatusSourceKinds.DedicatedCli or CodexStatusSourceKinds.ManualTest &&
                string.Equals(entry.Value.InstanceId, candidate.InstanceId, StringComparison.Ordinal) &&
                string.Equals(entry.Value.SessionId, candidate.SessionId, StringComparison.Ordinal));
            if (pair.Value is null || pair.Value.Status is not ("running" or "approval") ||
                !string.Equals(pair.Value.TurnId, candidate.TurnId, StringComparison.Ordinal) ||
                !string.Equals(pair.Value.CancellationPendingTurnId, candidate.TurnId, StringComparison.Ordinal))
            {
                return Recalculate();
            }

            CompleteSession(pair.Key, pair.Value, false, now, candidate.TurnId);
            return Recalculate();
        }
    }

    public static bool IsSupportedEvent(string eventName) => eventName is
        "SessionStart" or "UserPromptSubmit" or "PreToolUse" or "PostToolUse" or
        "PermissionRequest" or "Stop" or "SessionEnd" or "InstanceEnd";

    private static string? MapActiveStatus(CodexHookEvent hookEvent)
    {
        if (hookEvent.IsError)
        {
            return "error";
        }
        return hookEvent.EventName switch
        {
            "PreToolUse" or "PostToolUse" => "running",
            "PermissionRequest" => "approval",
            _ => null
        };
    }

    private void CompleteSession(
        SessionKey key,
        SessionState? existing,
        bool isError,
        DateTimeOffset now,
        string? explicitTurnId = null)
    {
        if (_activeSessions.Remove(key, out var removed))
        {
            existing = removed;
        }
        var turnId = explicitTurnId ?? existing?.TurnId;
        if (!string.IsNullOrWhiteSpace(turnId))
        {
            _terminalTurns[new(key, turnId)] = now;
        }
        if (isError)
        {
            _stickyErrorAt = now;
            _terminalStatus = "error";
        }
        else if (_stickyErrorAt is null)
        {
            _terminalStatus = "completed";
        }
    }

    private void ApplyInstanceEnd(CodexHookEvent hookEvent, DateTimeOffset now)
    {
        if (string.IsNullOrWhiteSpace(hookEvent.InstanceId))
        {
            return;
        }
        var keys = _activeSessions
            .Where(entry =>
                entry.Value.SourceKind == hookEvent.SourceKind &&
                string.Equals(entry.Value.InstanceId, hookEvent.InstanceId, StringComparison.Ordinal))
            .Select(entry => entry.Key)
            .ToArray();
        var hadUncancelledActive = false;
        foreach (var key in keys)
        {
            var session = _activeSessions[key];
            var wasCancelled = session.CancellationPendingTurnId == session.TurnId;
            hadUncancelledActive |= !wasCancelled;
            CompleteSession(key, session, false, now);
        }
        if (hookEvent.IsError && (hadUncancelledActive || keys.Length == 0))
        {
            _stickyErrorAt = now;
            _terminalStatus = "error";
        }
        else if (_stickyErrorAt is null)
        {
            _terminalStatus = "completed";
        }
    }

    private void RetirePreviousSessionsForInstance(
        SessionKey currentKey,
        CodexHookEvent hookEvent,
        DateTimeOffset now)
    {
        foreach (var key in _activeSessions
                     .Where(entry => entry.Key != currentKey &&
                         entry.Value.SourceKind == hookEvent.SourceKind &&
                         string.Equals(entry.Value.InstanceId, hookEvent.InstanceId, StringComparison.Ordinal))
                     .Select(entry => entry.Key)
                     .ToArray())
        {
            CompleteSession(key, _activeSessions[key], false, now);
        }
    }

    private CodexAggregateResult Recalculate()
    {
        var activeStatus = _activeSessions.Values
            .Select(session => session.Status)
            .OrderByDescending(status => Priority[status])
            .FirstOrDefault();
        var candidates = new[]
        {
            activeStatus,
            _stickyErrorAt is null ? null : "error",
            _activeSessions.Count == 0 ? _terminalStatus : null
        };
        var aggregate = candidates
            .Where(status => status is not null)
            .OrderByDescending(status => Priority[status!])
            .FirstOrDefault();
        var changed = !string.Equals(CurrentStatus, aggregate, StringComparison.Ordinal);
        CurrentStatus = aggregate;
        var sourceSummary = string.Join(",", _activeSessions.Values
            .GroupBy(session => session.SourceKind, StringComparer.Ordinal)
            .OrderBy(group => group.Key, StringComparer.Ordinal)
            .Select(group => $"{group.Key}:{group.Count()}"));
        sourceSummary = string.IsNullOrWhiteSpace(sourceSummary) ? "none" : sourceSummary;
        var activityChanged = changed ||
            _currentActiveSessionCount != _activeSessions.Count ||
            !string.Equals(_currentActiveSourceSummary, sourceSummary, StringComparison.Ordinal);
        _currentActiveSessionCount = _activeSessions.Count;
        _currentActiveSourceSummary = sourceSummary;
        return new(CurrentStatus, changed, _activeSessions.Count, sourceSummary)
        {
            ActivityChanged = activityChanged
        };
    }

    private void PruneTerminalTurns(DateTimeOffset now)
    {
        var cutoff = now - TimeSpan.FromHours(24);
        foreach (var key in _terminalTurns
                     .Where(pair => pair.Value < cutoff)
                     .Select(pair => pair.Key)
                     .ToArray())
        {
            _terminalTurns.Remove(key);
        }
    }

    private readonly record struct SessionKey(string SourceKind, string? InstanceId, string SessionId);
    private readonly record struct TurnKey(SessionKey Session, string TurnId);

    private sealed record SessionState(
        string SessionId,
        string? InstanceId,
        string SourceKind,
        string Status,
        string? TurnId,
        DateTimeOffset UpdatedAt,
        string? CancellationPendingTurnId);
}
