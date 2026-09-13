using System.Windows;
using System.Windows.Interop;

namespace Keynob.Services;

public sealed class UsbDeviceChangeMonitor : IDisposable
{
    private const int WmDeviceChange = 0x0219;
    private const int DeviceArrival = 0x8000;
    private const int DeviceRemoveComplete = 0x8004;

    private HwndSource? _source;

    public event Action? ConnectionMayHaveChanged;

    public void Start(Window window)
    {
        if (_source is not null)
        {
            return;
        }

        var handle = new WindowInteropHelper(window).Handle;
        _source = HwndSource.FromHwnd(handle)
            ?? throw new InvalidOperationException("window_source_unavailable");
        _source.AddHook(WindowMessageHook);
    }

    public void Dispose()
    {
        if (_source is null)
        {
            return;
        }
        _source.RemoveHook(WindowMessageHook);
        _source = null;
    }

    public static bool IsConnectionChangeMessage(int message, nint parameter) =>
        message == WmDeviceChange && parameter is DeviceArrival or DeviceRemoveComplete;

    private nint WindowMessageHook(
        nint windowHandle,
        int message,
        nint parameter,
        nint data,
        ref bool handled)
    {
        if (IsConnectionChangeMessage(message, parameter))
        {
            ConnectionMayHaveChanged?.Invoke();
        }
        return nint.Zero;
    }
}
