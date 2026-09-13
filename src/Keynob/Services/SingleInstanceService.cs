using System.Threading;
using System.Windows.Threading;

namespace Keynob.Services;

public sealed class SingleInstanceService : IDisposable
{
    private const string MutexName = "Local\\CodexKeyboardStudio.V1.Mutex";
    private const string ActivationEventName = "Local\\CodexKeyboardStudio.V1.Activate";
    private const string ExitEventName = "Local\\CodexKeyboardStudio.V1.Exit";

    private readonly Mutex _mutex;
    private readonly EventWaitHandle _activationEvent;
    private readonly EventWaitHandle _exitEvent;
    private readonly CancellationTokenSource _cancellation = new();
    private RegisteredWaitHandle? _registeredWait;
    private RegisteredWaitHandle? _exitRegisteredWait;

    public SingleInstanceService()
    {
        _mutex = new Mutex(initiallyOwned: true, MutexName, out var isPrimary);
        IsPrimary = isPrimary;
        _activationEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ActivationEventName);
        _exitEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ExitEventName);
    }

    public bool IsPrimary { get; }

    public void SignalPrimary() => _activationEvent.Set();

    public void SignalExit() => _exitEvent.Set();

    public void Listen(Dispatcher dispatcher, Action activate, Action exit)
    {
        if (!IsPrimary || _registeredWait is not null)
        {
            return;
        }

        _registeredWait = ThreadPool.RegisterWaitForSingleObject(
            _activationEvent,
            (_, timedOut) =>
            {
                if (!timedOut && !_cancellation.IsCancellationRequested)
                {
                    _ = dispatcher.BeginInvoke(activate);
                }
            },
            null,
            Timeout.Infinite,
            executeOnlyOnce: false);
        _exitRegisteredWait = ThreadPool.RegisterWaitForSingleObject(
            _exitEvent,
            (_, timedOut) =>
            {
                if (!timedOut && !_cancellation.IsCancellationRequested)
                {
                    _ = dispatcher.BeginInvoke(exit);
                }
            },
            null,
            Timeout.Infinite,
            executeOnlyOnce: false);
    }

    public void Dispose()
    {
        _cancellation.Cancel();
        _registeredWait?.Unregister(null);
        _exitRegisteredWait?.Unregister(null);
        _activationEvent.Dispose();
        _exitEvent.Dispose();
        if (IsPrimary)
        {
            _mutex.ReleaseMutex();
        }
        _mutex.Dispose();
        _cancellation.Dispose();
    }
}
