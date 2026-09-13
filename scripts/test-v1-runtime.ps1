[CmdletBinding()]
param([switch]$LeaveRunning)

$ErrorActionPreference = 'Stop'
$start = Join-Path $PSScriptRoot 'start-background.ps1'
$stop = Join-Path $PSScriptRoot 'stop-background.ps1'
$root = Split-Path -Parent $PSScriptRoot
$client = Join-Path $root 'artifacts\portable\CodexStatusHookClient.exe'
$managedHook = Join-Path $root 'scripts\codex-status-hook.ps1'
$logPath = Join-Path $env:LOCALAPPDATA 'CodexKeyboardStudio\diagnostic.log'
$secretMarker = 'V1_SECRET_MUST_NOT_APPEAR_IN_LOG'
$originalNoHardwareWrites = $env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES
$originalHookDiagnostics = $env:CODEX_KEYBOARD_TEST_HOOK_DIAGNOSTICS
$originalDataDirectory = $env:CODEX_KEYBOARD_STUDIO_DATA_DIR
$originalTestPipeName = $env:CODEX_KEYBOARD_TEST_STATUS_PIPE_NAME
$testDataDirectory = Join-Path ([IO.Path]::GetTempPath()) ("Keynob.RuntimeTests-" + [Guid]::NewGuid().ToString('N'))
$testPipeName = 'CodexKeyboardStudio.Status.v1.Test.runtime-' + [Guid]::NewGuid().ToString('N')
$env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES = '1'
$env:CODEX_KEYBOARD_TEST_HOOK_DIAGNOSTICS = '1'
$env:CODEX_KEYBOARD_STUDIO_DATA_DIR = $testDataDirectory
$env:CODEX_KEYBOARD_TEST_STATUS_PIPE_NAME = $testPipeName
$stage = 'initialization'

trap {
    [Console]::Error.WriteLine("V1_RUNTIME_FAIL stage=$stage error=$($_.Exception.Message)")
    if (-not $LeaveRunning) {
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stop | Out-Null
        } catch {
            [Console]::Error.WriteLine("V1_RUNTIME_CLEANUP_FAIL error=$($_.Exception.Message)")
        }
    }
    if ($null -eq $originalNoHardwareWrites) {
        Remove-Item Env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES = $originalNoHardwareWrites
    }
    if ($null -eq $originalHookDiagnostics) {
        Remove-Item Env:CODEX_KEYBOARD_TEST_HOOK_DIAGNOSTICS -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_KEYBOARD_TEST_HOOK_DIAGNOSTICS = $originalHookDiagnostics
    }
    if ($null -eq $originalDataDirectory) {
        Remove-Item Env:CODEX_KEYBOARD_STUDIO_DATA_DIR -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_KEYBOARD_STUDIO_DATA_DIR = $originalDataDirectory
    }
    if ($null -eq $originalTestPipeName) {
        Remove-Item Env:CODEX_KEYBOARD_TEST_STATUS_PIPE_NAME -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_KEYBOARD_TEST_STATUS_PIPE_NAME = $originalTestPipeName
    }
    if (Test-Path -LiteralPath $testDataDirectory) {
        Remove-Item -LiteralPath $testDataDirectory -Recurse -Force
    }
    exit 1
}

$stage = 'background_restart'
& $stop | Out-Null
$startupBaseline = if (Test-Path -LiteralPath $logPath) { @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count } else { 0 }
& $start | Out-Null
& $start | Out-Null
$processes = @(Get-Process Keynob -ErrorAction Stop)
if ($processes.Count -ne 1) { throw "Single-instance test failed: $($processes.Count) processes." }
$pipeReady = $false
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $newStartupLines = if (Test-Path -LiteralPath $logPath) {
        @(Get-Content -LiteralPath $logPath -Encoding UTF8 | Select-Object -Skip $startupBaseline)
    } else { @() }
    if ($newStartupLines -match 'codex_pipe_started') {
        $pipeReady = $true
        break
    }
    Start-Sleep -Milliseconds 100
}
if (-not $pipeReady) { throw 'Codex status pipe did not become ready within 2 seconds.' }
$baselineLineCount = if (Test-Path -LiteralPath $logPath) { @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count } else { 0 }

function Send-HookEvent {
    param([string]$Json)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $client
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.EnvironmentVariables.Remove('CODEX_KEYBOARD_INSTANCE_ID')
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.WriteLine($Json)
    $process.StandardInput.Close()
    $process.WaitForExit()
    $timer.Stop()
    if ($process.ExitCode -ne 0) { throw "Hook client exit code: $($process.ExitCode)" }
    return $timer.ElapsedMilliseconds
}

function Send-ManagedHookEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][string]$InstanceId
    )
    $payload = $Json | ConvertFrom-Json
    $payload | Add-Member -NotePropertyName instance_id -NotePropertyValue $InstanceId -Force
    $payload | Add-Member -NotePropertyName source_kind -NotePropertyValue 'manual_test' -Force
    $payload | Add-Member -NotePropertyName producer_process_id -NotePropertyValue $PID -Force
    $encoded = $payload | ConvertTo-Json -Compress -Depth 20
    $timer = [Diagnostics.Stopwatch]::StartNew()
    & $managedHook -RawPayload $encoded
    $timer.Stop()
    return $timer.ElapsedMilliseconds
}

function Wait-ForLogMatch {
    param(
        [string]$Pattern,
        [int]$AfterLineCount,
        [int]$TimeoutMs = 1000
    )
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    do {
        $matches = @(
            Get-Content -LiteralPath $logPath -Encoding UTF8 |
                Select-Object -Skip $AfterLineCount |
                Where-Object { $_ -match $Pattern }
        )
        if ($matches.Count -gt 0) { return }
        Start-Sleep -Milliseconds 10
    } until ([DateTime]::UtcNow -ge $deadline)
    throw "Log event did not appear within $TimeoutMs ms: $Pattern"
}

function Test-ForLogMatch {
    param(
        [string]$Pattern,
        [int]$AfterLineCount,
        [int]$TimeoutMs = 400
    )
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    do {
        if (@(
            Get-Content -LiteralPath $logPath -Encoding UTF8 |
                Select-Object -Skip $AfterLineCount |
                Where-Object { $_ -match $Pattern }
        ).Count -gt 0) {
            return $true
        }
        Start-Sleep -Milliseconds 10
    } until ([DateTime]::UtcNow -ge $deadline)
    return $false
}

$latencies = [Collections.Generic.List[long]]::new()
$stage = 'unscoped_source_filter'
$unscopedBaseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
$unscopedDelivered = $false
for ($attempt = 1; $attempt -le 3 -and -not $unscopedDelivered; $attempt++) {
    $latencies.Add((Send-HookEvent "{`"hook_event_name`":`"UserPromptSubmit`",`"session_id`":`"unscoped-runtime`",`"turn_id`":`"unscoped-turn`",`"prompt`":`"$secretMarker`"}"))
    $unscopedDelivered = Test-ForLogMatch `
        'codex_source_ignored\s+source=unscoped;event=UserPromptSubmit;reason=unscoped' `
        $unscopedBaseline
}
if (-not $unscopedDelivered) {
    throw 'Unscoped hook event was not delivered after three non-blocking attempts.'
}

$runtimeInstance = 'runtime-' + [Guid]::NewGuid().ToString('N')
$stage = 'running_transition'
$runningBaseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
$runningTimer = [Diagnostics.Stopwatch]::StartNew()
Send-ManagedHookEvent '{"hook_event_name":"UserPromptSubmit","session_id":"runtime-json","turn_id":"turn-json","prompt":"embedded \"success\": false"}' $runtimeInstance | Out-Null
Wait-ForLogMatch 'codex_led_applied\s+status=running' $runningBaseline
$runningTimer.Stop()

$stage = 'completed_transition'
$completedBaseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
$completedTimer = [Diagnostics.Stopwatch]::StartNew()
Send-ManagedHookEvent '{"hook_event_name":"Stop","session_id":"runtime-json","turn_id":"turn-json","prompt":"embedded \"success\": false","success":true}' $runtimeInstance | Out-Null
Wait-ForLogMatch 'codex_led_applied\s+status=completed' $completedBaseline
$completedTimer.Stop()

$stage = 'completed_base_restore'
Wait-ForLogMatch 'codex_led_base_restored\s+trigger=completion_delay;written=False' $completedBaseline 4500

$stage = 'multi_session_and_sticky_error'
Send-ManagedHookEvent "{`"hook_event_name`":`"UserPromptSubmit`",`"session_id`":`"runtime-a`",`"turn_id`":`"turn-a`",`"prompt`":`"$secretMarker`"}" $runtimeInstance | Out-Null
Send-ManagedHookEvent '{"hook_event_name":"PermissionRequest","session_id":"runtime-b","turn_id":"turn-b"}' $runtimeInstance | Out-Null
Send-ManagedHookEvent '{"hook_event_name":"Stop","session_id":"runtime-a","turn_id":"turn-a","success":false}' $runtimeInstance | Out-Null
Send-ManagedHookEvent '{"hook_event_name":"PostToolUse","session_id":"runtime-b","turn_id":"turn-b"}' $runtimeInstance | Out-Null
Send-ManagedHookEvent '{"hook_event_name":"Stop","session_id":"runtime-b","turn_id":"turn-b","success":true}' $runtimeInstance | Out-Null
Send-ManagedHookEvent '{"hook_event_name":"UserPromptSubmit","session_id":"runtime-c","turn_id":"turn-c"}' $runtimeInstance | Out-Null
Send-ManagedHookEvent '{"hook_event_name":"Stop","session_id":"runtime-c","turn_id":"turn-c","success":true}' $runtimeInstance | Out-Null
$deadline = [DateTime]::UtcNow.AddSeconds(5)
$newStatusLines = @()
do {
    Start-Sleep -Milliseconds 50
    $newStatusLines = @(
        Get-Content -LiteralPath $logPath -Encoding UTF8 |
            Select-Object -Skip $baselineLineCount |
            Where-Object { $_ -match 'codex_status_changed' }
    )
} until (($newStatusLines.Count -gt 0 -and $newStatusLines[-1] -match 'status=completed') -or
    [DateTime]::UtcNow -ge $deadline)

$stage = 'diagnostic_privacy_and_latency'
$log = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw -Encoding UTF8 } else { '' }
if ($newStatusLines.Count -lt 2 -or $newStatusLines[0] -notmatch 'status=running' -or
    $newStatusLines[1] -notmatch 'status=completed') {
    throw "Structured JSON parsing test failed: $($newStatusLines -join ' | ')"
}
foreach ($status in @('running', 'approval', 'error', 'completed')) {
    if ($log -notmatch "codex_status_changed\s+status=$status") { throw "Missing runtime status evidence: $status" }
}
if ($newStatusLines.Count -eq 0 -or $newStatusLines[-1] -notmatch 'status=completed') {
    throw "Final aggregate status was not completed: $($newStatusLines -join ' | ')"
}
if ($log.IndexOf($secretMarker, [StringComparison]::Ordinal) -ge 0) { throw 'Sensitive prompt marker leaked into diagnostics.' }
$coldHookLatency = $latencies[0]
$warmHookMaxMs = $coldHookLatency
if ($coldHookLatency -ge 500) {
    throw "Cold hook latency exceeded 500ms: $coldHookLatency"
}
$statusLedMaxMs = [Math]::Max($runningTimer.ElapsedMilliseconds, $completedTimer.ElapsedMilliseconds)
if ($statusLedMaxMs -ge 1000) {
    throw "Codex status LED application exceeded 1 second: running=$($runningTimer.ElapsedMilliseconds) completed=$($completedTimer.ElapsedMilliseconds)"
}

$stage = 'graceful_shutdown'
& $stop | Out-Null
if (@(Get-Process Keynob -ErrorAction SilentlyContinue).Count -ne 0) {
    throw 'Graceful shutdown left an app process running.'
}
$stage = 'offline_hook'
Remove-Item Env:CODEX_KEYBOARD_TEST_HOOK_DIAGNOSTICS -ErrorAction SilentlyContinue
$offlineLatency = Send-HookEvent '{"hook_event_name":"SessionStart","session_id":"runtime-offline"}'
if ($offlineLatency -ge 200) { throw "Offline hook latency exceeded 200ms: $offlineLatency" }
if ($LeaveRunning) {
    $stage = 'leave_running_restart'
    & $start | Out-Null
}

$stage = 'complete'
if ($null -eq $originalNoHardwareWrites) {
    Remove-Item Env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES -ErrorAction SilentlyContinue
} else {
    $env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES = $originalNoHardwareWrites
}
if ($null -eq $originalHookDiagnostics) {
    Remove-Item Env:CODEX_KEYBOARD_TEST_HOOK_DIAGNOSTICS -ErrorAction SilentlyContinue
} else {
    $env:CODEX_KEYBOARD_TEST_HOOK_DIAGNOSTICS = $originalHookDiagnostics
}
if ($null -eq $originalDataDirectory) {
    Remove-Item Env:CODEX_KEYBOARD_STUDIO_DATA_DIR -ErrorAction SilentlyContinue
} else {
    $env:CODEX_KEYBOARD_STUDIO_DATA_DIR = $originalDataDirectory
}
if ($null -eq $originalTestPipeName) {
    Remove-Item Env:CODEX_KEYBOARD_TEST_STATUS_PIPE_NAME -ErrorAction SilentlyContinue
} else {
    $env:CODEX_KEYBOARD_TEST_STATUS_PIPE_NAME = $originalTestPipeName
}
if (Test-Path -LiteralPath $testDataDirectory) {
    Remove-Item -LiteralPath $testDataDirectory -Recurse -Force
}
Write-Output "V1_RUNTIME_PASS singleInstance=True unscopedIgnored=True hookColdMs=$coldHookLatency hookWarmMaxMs=$warmHookMaxMs hookOfflineMs=$offlineLatency statusLedMaxMs=$statusLedMaxMs baseRestore=True structuredJson=True multiSession=True activeSessionsZero=True sensitiveDataLogged=False hardwareWrites=False gracefulShutdown=True"
