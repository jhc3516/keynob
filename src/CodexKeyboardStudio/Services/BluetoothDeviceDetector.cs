using System.Runtime.InteropServices;

namespace CodexKeyboardStudio.Services;

public sealed record BluetoothDeviceState(bool Available, bool Detected);

public sealed class BluetoothDeviceDetector
{
    private const string TargetDevicePrefix = "BTHLE\\DEV_67C81CBF4C20";
    private const uint PresentDevices = 0x00000100;
    private const int Success = 0;

    public BluetoothDeviceState Detect()
    {
        if (CM_Get_Device_ID_List_SizeW(out var characterCount, null, PresentDevices) != Success ||
            characterCount == 0)
        {
            return new(false, false);
        }

        var buffer = new char[characterCount];
        if (CM_Get_Device_ID_ListW(null, buffer, characterCount, PresentDevices) != Success)
        {
            return new(false, false);
        }

        return new(true, ContainsTarget(ParseMultiString(buffer)));
    }

    public static bool ContainsTarget(IEnumerable<string> deviceIds) => deviceIds.Any(deviceId =>
        deviceId.StartsWith(TargetDevicePrefix, StringComparison.OrdinalIgnoreCase));

    private static IEnumerable<string> ParseMultiString(char[] buffer) =>
        new string(buffer).Split('\0', StringSplitOptions.RemoveEmptyEntries);

    [DllImport("CfgMgr32.dll", CharSet = CharSet.Unicode)]
    private static extern int CM_Get_Device_ID_List_SizeW(
        out uint characterCount,
        string? filter,
        uint flags);

    [DllImport("CfgMgr32.dll", CharSet = CharSet.Unicode)]
    private static extern int CM_Get_Device_ID_ListW(
        string? filter,
        [Out] char[] buffer,
        uint bufferLength,
        uint flags);
}
