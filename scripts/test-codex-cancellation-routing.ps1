[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$startScript = Join-Path $PSScriptRoot 'start-background.ps1'
$stopScript = Join-Path $PSScriptRoot 'stop-background.ps1'
$client = Join-Path $root 'artifacts\portable\CodexStatusHookClient.exe'
$logPath = Join-Path $env:LOCALAPPDATA 'CodexKeyboardStudio\diagnostic.log'
$form = $null
$otherForm = $null
$originalInstanceId = [Environment]::GetEnvironmentVariable('CODEX_KEYBOARD_INSTANCE_ID', 'Process')
$originalNoHardwareWrites = $env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES
$env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES = '1'

function Send-HookEvent {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$Json
    )

    $payload = $Json | ConvertFrom-Json
    $successProperty = $payload.PSObject.Properties['success']
    $failedProperty = $payload.PSObject.Properties['failed']
    $message = [ordered]@{
        eventName = [string]$payload.hook_event_name
        sessionId = [string]$payload.session_id
        turnId = if ($null -eq $payload.turn_id) { $null } else { [string]$payload.turn_id }
        instanceId = $InstanceId
        launcherProcessId = $null
        isError = ($null -ne $failedProperty -and [bool]$failedProperty.Value) -or
            ($null -ne $successProperty -and -not [bool]$successProperty.Value)
        sourceKind = 'manual_test'
        producerProcessId = $PID
    } | ConvertTo-Json -Compress

    $pipe = [IO.Pipes.NamedPipeClientStream]::new(
        '.',
        'CodexKeyboardStudio.Status.v1',
        [IO.Pipes.PipeDirection]::Out,
        [IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $pipe.Connect(1000)
        $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 1024, $true)
        try {
            $writer.WriteLine($message)
            $writer.Flush()
        } finally {
            $writer.Dispose()
        }
    } finally {
        $pipe.Dispose()
    }
}

function Wait-ForLogMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][int]$AfterLineCount,
        [int]$TimeoutMs = 2000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    do {
        $matches = @(
            Get-Content -LiteralPath $logPath -Encoding UTF8 |
                Select-Object -Skip $AfterLineCount |
                Where-Object { $_ -match $Pattern }
        )
        if ($matches.Count -gt 0) {
            return
        }
        Start-Sleep -Milliseconds 20
    } until ([DateTime]::UtcNow -ge $deadline)
    throw "Log event did not appear within $TimeoutMs ms: $Pattern"
}

try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stopScript | Out-Null
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startScript | Out-Null
    if (-not (Test-Path -LiteralPath $client)) {
        throw "Portable hook client is missing: $client"
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexCancellationRoutingProbe {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr window);

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

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);

    public static void SendEscape() {
        const uint KeyUp = 0x0002;
        keybd_event(0x1B, 0, 0, UIntPtr.Zero);
        keybd_event(0x1B, 0, KeyUp, UIntPtr.Zero);
    }

    public static void SendCtrlC() {
        const uint KeyUp = 0x0002;
        keybd_event(0x11, 0, 0, UIntPtr.Zero);
        keybd_event(0x43, 0, 0, UIntPtr.Zero);
        keybd_event(0x43, 0, KeyUp, UIntPtr.Zero);
        keybd_event(0x11, 0, KeyUp, UIntPtr.Zero);
    }

    public static bool ForceForeground(IntPtr window) {
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

    function Focus-TestForm {
        param(
            [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Form,
            [int]$TimeoutMs = 2000
        )

        $Form.Show()
        $Form.TopMost = $true
        $Form.BringToFront()
        $Form.Activate() | Out-Null
        [System.Windows.Forms.Application]::DoEvents()
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        do {
            [CodexCancellationRoutingProbe]::ForceForeground($Form.Handle) | Out-Null
            [System.Windows.Forms.Application]::DoEvents()
            if ([CodexCancellationRoutingProbe]::GetForegroundWindow() -eq $Form.Handle) {
                $Form.TopMost = $false
                return
            }
            Start-Sleep -Milliseconds 25
        } until ([DateTime]::UtcNow -ge $deadline)
        $Form.TopMost = $false
        throw "Test form did not become foreground within $TimeoutMs ms."
    }

    $instanceA = [Guid]::NewGuid().ToString('N')
    $instanceB = [Guid]::NewGuid().ToString('N')
    $form = [System.Windows.Forms.Form]::new()
    $form.Text = "Codex CLI - Keynob - $instanceA"
    $form.Width = 480
    $form.Height = 160
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()

    $baseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
    Send-HookEvent $instanceA '{"hook_event_name":"UserPromptSubmit","session_id":"cancel-route-a","turn_id":"cancel-turn-a"}'
    Send-HookEvent $instanceB '{"hook_event_name":"UserPromptSubmit","session_id":"cancel-route-b","turn_id":"cancel-turn-b"}'
    Wait-ForLogMatch 'codex_status_changed\s+status=running' $baseline

    Focus-TestForm $form
    Start-Sleep -Milliseconds 250
    $cancelBaseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
    [CodexCancellationRoutingProbe]::SendEscape()
    Wait-ForLogMatch "codex_cancel_pending\s+gesture=escape;instance=$instanceA;session=cancel-route-a;turn=cancel-turn-a" $cancelBaseline
    Start-Sleep -Milliseconds 700

    $duringCancellation = @(
        Get-Content -LiteralPath $logPath -Encoding UTF8 |
            Select-Object -Skip $cancelBaseline |
            Where-Object { $_ -match 'codex_status_changed\s+status=completed' }
    )
    if ($duringCancellation.Count -ne 0) {
        throw 'Cancelling instance A incorrectly completed the aggregate while instance B was still running.'
    }

    $finishBaseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
    Send-HookEvent $instanceB '{"hook_event_name":"Stop","session_id":"cancel-route-b","turn_id":"cancel-turn-b","success":true}'
    Wait-ForLogMatch 'codex_status_changed\s+status=completed' $finishBaseline

    $lateBaseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
    Send-HookEvent $instanceA '{"hook_event_name":"PostToolUse","session_id":"cancel-route-a","turn_id":"cancel-turn-a","success":true}'
    Start-Sleep -Milliseconds 250
    $lateRunning = @(
        Get-Content -LiteralPath $logPath -Encoding UTF8 |
            Select-Object -Skip $lateBaseline |
            Where-Object { $_ -match 'codex_status_changed\s+status=running' }
    )
    if ($lateRunning.Count -ne 0) {
        throw 'A late event from the cancelled turn restored the running LED state.'
    }

    $instanceC = [Guid]::NewGuid().ToString('N')
    $form.Text = "Codex CLI - Keynob - $instanceC"
    [System.Windows.Forms.Application]::DoEvents()
    $stopFirstBaseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
    Send-HookEvent $instanceC '{"hook_event_name":"UserPromptSubmit","session_id":"stop-first-session","turn_id":"stop-first-turn"}'
    Wait-ForLogMatch 'codex_status_changed\s+status=running' $stopFirstBaseline
    Focus-TestForm $form
    Start-Sleep -Milliseconds 200
    $stopCancelBaseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
    [CodexCancellationRoutingProbe]::SendEscape()
    Wait-ForLogMatch "codex_cancel_pending\s+gesture=escape;instance=$instanceC;session=stop-first-session;turn=stop-first-turn" $stopCancelBaseline
    Start-Sleep -Milliseconds 100
    Send-HookEvent $instanceC '{"hook_event_name":"Stop","session_id":"stop-first-session","turn_id":"stop-first-turn","success":true}'
    Wait-ForLogMatch 'codex_status_changed\s+status=completed' $stopCancelBaseline
    Start-Sleep -Milliseconds 550
    $fallbackAfterStop = @(
        Get-Content -LiteralPath $logPath -Encoding UTF8 |
            Select-Object -Skip $stopCancelBaseline |
            Where-Object { $_ -match 'codex_cancel_applied' }
    )
    if ($fallbackAfterStop.Count -ne 0) {
        throw 'Fallback completed a turn again after a real Stop arrived during the grace period.'
    }

    $instanceD = [Guid]::NewGuid().ToString('N')
    $form.Text = "Codex CLI - Keynob - $instanceD"
    [System.Windows.Forms.Application]::DoEvents()
    $raceBaseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
    Send-HookEvent $instanceD '{"hook_event_name":"UserPromptSubmit","session_id":"race-route-session","turn_id":"race-old-turn"}'
    Wait-ForLogMatch 'codex_status_changed\s+status=running' $raceBaseline
    Focus-TestForm $form
    Start-Sleep -Milliseconds 200
    $raceCancelBaseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
    [CodexCancellationRoutingProbe]::SendCtrlC()
    Wait-ForLogMatch "codex_cancel_pending\s+gesture=ctrl_c;instance=$instanceD;session=race-route-session;turn=race-old-turn" $raceCancelBaseline
    Start-Sleep -Milliseconds 100
    Send-HookEvent $instanceD '{"hook_event_name":"UserPromptSubmit","session_id":"race-route-session","turn_id":"race-new-turn"}'
    Start-Sleep -Milliseconds 600
    $raceCompletion = @(
        Get-Content -LiteralPath $logPath -Encoding UTF8 |
            Select-Object -Skip $raceCancelBaseline |
            Where-Object { $_ -match 'codex_status_changed\s+status=completed' }
    )
    if ($raceCompletion.Count -ne 0) {
        throw 'The old Ctrl+C fallback completed the new turn.'
    }
    $raceFinishBaseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
    Send-HookEvent $instanceD '{"hook_event_name":"Stop","session_id":"race-route-session","turn_id":"race-new-turn","success":true}'
    Wait-ForLogMatch 'codex_status_changed\s+status=completed' $raceFinishBaseline

    $instanceE = [Guid]::NewGuid().ToString('N')
    $form.Text = ([char]0x2839) + ' Codex dynamic working title'
    [System.Windows.Forms.Application]::DoEvents()
    $deferredBaseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
    Send-HookEvent $instanceE '{"hook_event_name":"UserPromptSubmit","session_id":"deferred-session","turn_id":"deferred-turn"}'
    Wait-ForLogMatch 'codex_status_changed\s+status=running' $deferredBaseline
    Focus-TestForm $form
    Start-Sleep -Milliseconds 200
    $deferredCancelBaseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
    [CodexCancellationRoutingProbe]::SendEscape()
    Wait-ForLogMatch 'codex_cancel_title_wait\s+gesture=escape' $deferredCancelBaseline
    Start-Sleep -Milliseconds 250
    $form.Text = "Codex CLI - Keynob - $instanceE"
    [System.Windows.Forms.Application]::DoEvents()
    Wait-ForLogMatch "codex_cancel_gesture\s+key=escape;instance=$instanceE;resolution=title_restored" $deferredCancelBaseline 2500
    Wait-ForLogMatch "codex_cancel_pending\s+gesture=escape;instance=$instanceE;session=deferred-session;turn=deferred-turn" $deferredCancelBaseline 2500
    Start-Sleep -Milliseconds 700
    Wait-ForLogMatch 'codex_status_changed\s+status=completed' $deferredCancelBaseline

    $instanceF = [Guid]::NewGuid().ToString('N')
    $form.Text = ([char]0x2839) + ' Codex dynamic title before foreground change'
    $otherForm = [System.Windows.Forms.Form]::new()
    $otherForm.Text = 'Different foreground terminal window'
    $otherForm.Width = 360
    $otherForm.Height = 120
    $otherForm.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $foregroundChangeBaseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
    Send-HookEvent $instanceF '{"hook_event_name":"UserPromptSubmit","session_id":"foreground-change-session","turn_id":"foreground-change-turn"}'
    Wait-ForLogMatch 'codex_status_changed\s+status=running' $foregroundChangeBaseline
    Focus-TestForm $form
    Start-Sleep -Milliseconds 200
    $foregroundCancelBaseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
    [CodexCancellationRoutingProbe]::SendEscape()
    Wait-ForLogMatch 'codex_cancel_title_wait\s+gesture=escape' $foregroundCancelBaseline
    Focus-TestForm $otherForm
    $form.Text = "Codex CLI - Keynob - $instanceF"
    [System.Windows.Forms.Application]::DoEvents()
    Wait-ForLogMatch 'codex_cancel_title_unresolved\s+gesture=escape;reason=foreground_changed' $foregroundCancelBaseline
    $wrongCancellation = @(
        Get-Content -LiteralPath $logPath -Encoding UTF8 |
            Select-Object -Skip $foregroundCancelBaseline |
            Where-Object { $_ -match "codex_cancel_pending\s+gesture=escape;instance=$instanceF" }
    )
    if ($wrongCancellation.Count -ne 0) {
        throw 'A title restored after the foreground changed cancelled the wrong instance.'
    }
    $foregroundFinishBaseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
    Send-HookEvent $instanceF '{"hook_event_name":"Stop","session_id":"foreground-change-session","turn_id":"foreground-change-turn","success":true}'
    Wait-ForLogMatch 'codex_status_changed\s+status=completed' $foregroundFinishBaseline

    Write-Output 'CODEX_CANCELLATION_ROUTING_PASS foregroundInstanceOnly=True otherSessionPreserved=True fallback=True lateEventIgnored=True realStopWins=True ctrlC=True newTurnProtected=True deferredTitle=True foregroundChangeSafe=True'
} finally {
    if ($otherForm) {
        $otherForm.Close()
        $otherForm.Dispose()
    }
    if ($form) {
        $form.Close()
        $form.Dispose()
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stopScript | Out-Null
    if ($null -eq $originalInstanceId) {
        Remove-Item Env:CODEX_KEYBOARD_INSTANCE_ID -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_KEYBOARD_INSTANCE_ID = $originalInstanceId
    }
    if ($null -eq $originalNoHardwareWrites) {
        Remove-Item Env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES = $originalNoHardwareWrites
    }
}
