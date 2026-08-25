if (-not ('CodexKeyboardTestWindowFocus' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CodexKeyboardTestWindowFocus {
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, IntPtr processId);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint attach, uint attachTo, bool value);

    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(IntPtr window);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr window, int command);

    public static bool Force(IntPtr window) {
        IntPtr foreground = GetForegroundWindow();
        uint currentThread = GetCurrentThreadId();
        uint foregroundThread = foreground == IntPtr.Zero
            ? 0
            : GetWindowThreadProcessId(foreground, IntPtr.Zero);
        bool attached = foregroundThread != 0 && foregroundThread != currentThread &&
            AttachThreadInput(currentThread, foregroundThread, true);
        try {
            ShowWindow(window, 5);
            BringWindowToTop(window);
            SetForegroundWindow(window);
            return GetForegroundWindow() == window;
        } finally {
            if (attached) AttachThreadInput(currentThread, foregroundThread, false);
        }
    }
}
'@
}

function Set-CodexKeyboardTestForeground {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Handle,
        $Form = $null,
        [int]$TimeoutMs = 3000
    )

    if ($Form) {
        $Form.Show()
        $Form.TopMost = $true
        $Form.BringToFront()
        $Form.Activate() | Out-Null
        [System.Windows.Forms.Application]::DoEvents()
    }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    do {
        [CodexKeyboardTestWindowFocus]::Force($Handle) | Out-Null
        [System.Windows.Forms.Application]::DoEvents()
        if ([CodexKeyboardTestWindowFocus]::GetForegroundWindow() -eq $Handle) {
            if ($Form) { $Form.TopMost = $false }
            return
        }
        Start-Sleep -Milliseconds 25
    } until ([DateTime]::UtcNow -ge $deadline)
    if ($Form) { $Form.TopMost = $false }
    throw "Could not activate integration probe window within $TimeoutMs ms. expected=$Handle actual=$([CodexKeyboardTestWindowFocus]::GetForegroundWindow())"
}
