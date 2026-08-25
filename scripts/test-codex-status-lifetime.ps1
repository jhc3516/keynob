[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$startScript = Join-Path $PSScriptRoot 'start-background.ps1'
$stopScript = Join-Path $PSScriptRoot 'stop-background.ps1'
$setStatusScript = Join-Path $PSScriptRoot 'set-codex-cli-status.ps1'
$logPath = Join-Path $env:LOCALAPPDATA 'CodexKeyboardStudio\diagnostic.log'
$producerA = $null
$producerB = $null
$originalNoWrite = $env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES
$originalDataDirectory = $env:CODEX_KEYBOARD_STUDIO_DATA_DIR
$originalTestPipeName = $env:CODEX_KEYBOARD_TEST_STATUS_PIPE_NAME
$testDataDirectory = Join-Path ([IO.Path]::GetTempPath()) ("CodexKeyboardStudio.StatusLifetime-" + [Guid]::NewGuid().ToString('N'))
$testPipeName = 'CodexKeyboardStudio.Status.v1.Test.lifetime-' + [Guid]::NewGuid().ToString('N')
$env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES = '1'
$env:CODEX_KEYBOARD_STUDIO_DATA_DIR = $testDataDirectory
$env:CODEX_KEYBOARD_TEST_STATUS_PIPE_NAME = $testPipeName

function Wait-ForCondition {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [Parameter(Mandatory = $true)][string]$Failure,
        [int]$TimeoutMs = 5000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    do {
        if (& $Condition) {
            return
        }
        Start-Sleep -Milliseconds 25
    } until ([DateTime]::UtcNow -ge $deadline)
    throw $Failure
}

function Get-NewLogLines {
    param([int]$AfterLineCount)

    return @(Get-Content -LiteralPath $logPath -Encoding UTF8 | Select-Object -Skip $AfterLineCount)
}

function Start-JsonStatusProducer {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$SessionId
    )

    $escapedStatusScript = $setStatusScript.Replace("'", "''")
    $producerBody = @"
& '$escapedStatusScript' -Status running -SessionId '$SessionId' -InstanceId '$InstanceId' -SourceKind json_exec -ProducerProcessId `$PID | Out-Null
Start-Sleep -Seconds 60
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($producerBody))
    return Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) `
        -WindowStyle Hidden -PassThru
}

try {
    foreach ($required in @($startScript, $stopScript, $setStatusScript)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Required test input is missing: $required"
        }
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stopScript | Out-Null
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startScript | Out-Null

    $instanceA = 'json-lifetime-' + [Guid]::NewGuid().ToString('N')
    $sessionA = 'json-session-' + [Guid]::NewGuid().ToString('N')
    $baselineA = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
    $producerA = Start-JsonStatusProducer $instanceA $sessionA
    Wait-ForCondition {
        @(Get-NewLogLines $baselineA | Where-Object {
            $_ -match "codex_producer_watch_started\s+source=json_exec;instance=$instanceA;pid=$($producerA.Id)"
        }).Count -gt 0
    } 'The JSON status producer was not registered.'
    Wait-ForCondition {
        @(Get-NewLogLines $baselineA | Where-Object {
            $_ -match 'codex_status_changed\s+status=running;activeSessions=1;sources=json_exec:1'
        }).Count -gt 0
    } 'The JSON status producer did not set running.'

    $fallbackClock = [Diagnostics.Stopwatch]::StartNew()
    Stop-Process -Id $producerA.Id -Force
    $producerA.WaitForExit(3000) | Out-Null
    Wait-ForCondition {
        @(Get-NewLogLines $baselineA | Where-Object {
            $_ -match "codex_producer_exit_fallback\s+source=json_exec;instance=$instanceA;pid=$($producerA.Id)"
        }).Count -gt 0
    } 'The JSON producer exit fallback was not applied.' 1200
    Wait-ForCondition {
        @(Get-NewLogLines $baselineA | Where-Object {
            $_ -match 'codex_status_changed\s+status=completed;activeSessions=0;sources=none'
        }).Count -gt 0
    } 'The JSON producer exit fallback did not clear the active state.' 1200
    $fallbackClock.Stop()
    if ($fallbackClock.ElapsedMilliseconds -gt 1000) {
        throw "JSON producer fallback exceeded 1000 ms: $($fallbackClock.ElapsedMilliseconds) ms."
    }

    $instanceB = 'json-restart-' + [Guid]::NewGuid().ToString('N')
    $sessionB = 'restart-session-' + [Guid]::NewGuid().ToString('N')
    $baselineB = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
    $producerB = Start-JsonStatusProducer $instanceB $sessionB
    Wait-ForCondition {
        @(Get-NewLogLines $baselineB | Where-Object {
            $_ -match 'codex_status_changed\s+status=running;activeSessions=1;sources=json_exec:1'
        }).Count -gt 0
    } 'The restart fixture did not set running.'

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stopScript | Out-Null
    $restartBaseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startScript | Out-Null
    Wait-ForCondition {
        @(Get-NewLogLines $restartBaseline | Where-Object {
            $_ -match 'codex_status_changed\s+status=completed;activeSessions=0;sources=none'
        }).Count -gt 0
    } 'The restarted app did not initialize to completed with zero active sessions.'
    Start-Sleep -Milliseconds 750
    $restartLines = Get-NewLogLines $restartBaseline
    if (@($restartLines | Where-Object {
        $_ -match 'codex_status_changed\s+status=(running|approval)'
    }).Count -ne 0) {
        throw 'The restarted app restored a stale running or approval state.'
    }
    if (@($restartLines | Where-Object {
        $_ -match 'codex_led_base_restored\s+trigger=startup_or_usb;written=False'
    }).Count -eq 0) {
        throw 'The restarted app did not restore the base LED layout through the no-write LED device.'
    }

    Write-Output "CODEX_STATUS_LIFETIME_PASS jsonFallbackMs=$($fallbackClock.ElapsedMilliseconds) activeSessionsZero=True restartCompleted=True restartBaseLayout=True staleStateRestored=False hardwareWrites=False"
} finally {
    foreach ($producer in @($producerA, $producerB)) {
        if ($null -ne $producer) {
            $producer.Refresh()
            if (-not $producer.HasExited) {
                Stop-Process -Id $producer.Id -Force -ErrorAction SilentlyContinue
            }
            $producer.Dispose()
        }
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stopScript | Out-Null
    if ($null -eq $originalNoWrite) {
        Remove-Item Env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES = $originalNoWrite
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
}
