using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Channels;

namespace CodexKeyboardStudio.Services;

public sealed class CodexStatusPipeServer(
    Func<CodexHookEvent, Task> eventHandler,
    DiagnosticLog log,
    string? pipeName = null) : IAsyncDisposable
{
    public const string PipeName = "CodexKeyboardStudio.Status.v1";
    private const int MaxMessageCharacters = 4096;
    private const int ListenerCount = 4;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    private CancellationTokenSource? _cancellation;
    private Channel<CodexHookEvent>? _events;
    private Task? _listener;
    private Task? _processor;
    private readonly string _pipeName = string.IsNullOrWhiteSpace(pipeName) ? PipeName : pipeName;

    public bool IsRunning => _cancellation is not null;

    public void Start()
    {
        if (IsRunning)
        {
            return;
        }
        _cancellation = new CancellationTokenSource();
        _events = Channel.CreateUnbounded<CodexHookEvent>(new UnboundedChannelOptions
        {
            SingleReader = true,
            SingleWriter = false
        });
        _listener = Task.WhenAll(Enumerable.Range(0, ListenerCount)
            .Select(_ => Task.Run(() => RunListenerAsync(_events.Writer, _cancellation.Token))));
        _processor = Task.Run(() => RunProcessorAsync(_events.Reader));
        log.Write("codex_pipe_started", $"listeners={ListenerCount};processor=1");
    }

    public async Task StopAsync()
    {
        var cancellation = _cancellation;
        if (cancellation is null)
        {
            return;
        }
        _cancellation = null;
        cancellation.Cancel();
        var listener = _listener;
        var processor = _processor;
        var events = _events;
        try
        {
            if (listener is not null)
            {
                await listener;
            }
            events?.Writer.TryComplete();
            if (processor is not null && await Task.WhenAny(processor, Task.Delay(1000)) != processor)
            {
                log.Write("codex_pipe_stop_timeout", "processor_abandoned_on_process_exit");
            }
        }
        catch (OperationCanceledException)
        {
        }
        cancellation.Dispose();
        _events = null;
        _listener = null;
        _processor = null;
        log.Write("codex_pipe_stopped", "ok");
    }

    public async ValueTask DisposeAsync() => await StopAsync();

    private async Task RunListenerAsync(
        ChannelWriter<CodexHookEvent> writer,
        CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await using var pipe = new NamedPipeServerStream(
                    _pipeName,
                    PipeDirection.In,
                    NamedPipeServerStream.MaxAllowedServerInstances,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(cancellationToken);
                using var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 1024, leaveOpen: false);
                var line = await reader.ReadLineAsync(cancellationToken);
                if (string.IsNullOrWhiteSpace(line) || line.Length > MaxMessageCharacters)
                {
                    log.Write("codex_pipe_rejected", "invalid_length");
                    continue;
                }

                var hookEvent = JsonSerializer.Deserialize<CodexHookEvent>(line, JsonOptions);
                if (!IsValid(hookEvent))
                {
                    log.Write("codex_pipe_rejected", "invalid_event");
                    continue;
                }
                await writer.WriteAsync(hookEvent!, cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException)
            {
                log.Write("codex_pipe_error", exception.GetType().Name);
            }
        }
    }

    private async Task RunProcessorAsync(ChannelReader<CodexHookEvent> reader)
    {
        await foreach (var hookEvent in reader.ReadAllAsync())
        {
            try
            {
                await eventHandler(hookEvent);
            }
            catch (Exception exception)
            {
                log.Write("codex_event_error", exception.GetType().Name);
            }
        }
    }

    internal static bool IsValid(CodexHookEvent? hookEvent)
    {
        if (hookEvent is null || !CodexStatusAggregator.IsSupportedEvent(hookEvent.EventName))
        {
            return false;
        }
        if (!CodexStatusSourceKinds.IsSupported(hookEvent.SourceKind))
        {
            return false;
        }
        if (hookEvent.EventName == "InstanceEnd")
        {
            return hookEvent.SessionId is null && hookEvent.TurnId is null &&
                hookEvent.SourceKind == CodexStatusSourceKinds.DedicatedCli &&
                hookEvent.InstanceId is not null && IsSafeId(hookEvent.InstanceId) &&
                hookEvent.LauncherProcessId is null && hookEvent.ProducerProcessId is null;
        }
        if (hookEvent.SessionId is null || !IsSafeId(hookEvent.SessionId) ||
            (hookEvent.TurnId is not null && !IsSafeId(hookEvent.TurnId)))
        {
            return false;
        }
        return hookEvent.SourceKind switch
        {
            CodexStatusSourceKinds.Unscoped =>
                hookEvent.InstanceId is null && hookEvent.LauncherProcessId is null &&
                hookEvent.ProducerProcessId is null,
            CodexStatusSourceKinds.DedicatedCli =>
                hookEvent.InstanceId is not null && IsSafeId(hookEvent.InstanceId) &&
                hookEvent.LauncherProcessId is > 0 && hookEvent.ProducerProcessId is null,
            CodexStatusSourceKinds.JsonExec or CodexStatusSourceKinds.ManualTest =>
                hookEvent.InstanceId is not null && IsSafeId(hookEvent.InstanceId) &&
                hookEvent.LauncherProcessId is null && hookEvent.ProducerProcessId is > 0,
            _ => false
        };
    }

    private static bool IsSafeId(string value) =>
        value.Length is > 0 and <= 128 &&
        value.All(character => char.IsAsciiLetterOrDigit(character) || character is '-' or '_' or '.');
}
