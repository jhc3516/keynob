param([int]$Seconds = 30)

$source = @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class KeyboardMonitor {
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_SYSKEYDOWN = 0x0104;
    private static HookProc proc = Callback;
    private static IntPtr hook = IntPtr.Zero;

    public static void Run(int milliseconds) {
        hook = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(null), 0);
        if (hook == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        var timer = new Timer { Interval = milliseconds };
        timer.Tick += (s, e) => { timer.Stop(); Application.ExitThread(); };
        timer.Start();
        Application.Run();
        UnhookWindowsHookEx(hook);
    }

    private static IntPtr Callback(int code, IntPtr wParam, IntPtr lParam) {
        if (code >= 0 && (wParam == (IntPtr)WM_KEYDOWN || wParam == (IntPtr)WM_SYSKEYDOWN)) {
            int vk = Marshal.ReadInt32(lParam);
            Console.WriteLine("{0:HH:mm:ss.fff} VK={1} Key={2}", DateTime.Now, vk, (Keys)vk);
            Console.Out.Flush();
        }
        return CallNextHookEx(hook, code, wParam, lParam);
    }

    private delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr SetWindowsHookEx(int idHook, HookProc callback, IntPtr module, uint threadId);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet=CharSet.Auto)] private static extern IntPtr GetModuleHandle(string name);
}
'@

Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms
Write-Output "Monitoring keyboard events for $Seconds seconds..."
[KeyboardMonitor]::Run($Seconds * 1000)
Write-Output 'Monitoring complete.'
