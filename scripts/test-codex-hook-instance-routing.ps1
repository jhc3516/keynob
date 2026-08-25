[CmdletBinding()]
param(
    [string]$HookClient,
    [string]$Launcher
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$HookClient = if ([string]::IsNullOrWhiteSpace($HookClient)) {
    Join-Path $root 'artifacts\app\CodexStatusHookClient.exe'
} else {
    $HookClient
}
$Launcher = if ([string]::IsNullOrWhiteSpace($Launcher)) {
    Join-Path $root 'artifacts\app\Start-CodexCli.exe'
} else {
    $Launcher
}
$pipeName = 'CodexKeyboardStudio.Status.v1.Test.' + [Guid]::NewGuid().ToString('N')
$testRoot = Join-Path $root '.runtime\hook-instance-routing'
$inputPath = Join-Path $testRoot 'hook-input.json'
$launcherProbePath = Join-Path $testRoot 'launcher-probe.json'
$launcherHookProbePath = Join-Path $testRoot 'launcher-hook-probe.json'
$launcherErrorProbePath = Join-Path $testRoot 'launcher-error-probe.json'
$launcherInterruptProbePath = Join-Path $testRoot 'launcher-interrupt-probe.json'
$launcherProject = Join-Path $testRoot 'launcher-project'
$fakeNpmRoot = Join-Path $testRoot 'fake-npm'
$fakeCodexBin = Join-Path $fakeNpmRoot 'node_modules\@openai\codex\bin'
if (-not (Test-Path -LiteralPath $HookClient)) {
    throw "Hook client is missing: $HookClient"
}
if (-not (Test-Path -LiteralPath $Launcher)) {
    throw "Native launcher is missing: $Launcher"
}
if (Get-Process -Name CodexKeyboardStudio -ErrorAction SilentlyContinue) {
    throw 'Stop CodexKeyboardStudio before the isolated named-pipe routing test.'
}

function Receive-StatusMessage {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$StartSender,
        [int[]]$ExpectedExitCodes = @(0)
    )

    $pipe = [IO.Pipes.NamedPipeServerStream]::new(
        $pipeName,
        [IO.Pipes.PipeDirection]::In,
        1,
        [IO.Pipes.PipeTransmissionMode]::Byte,
        [IO.Pipes.PipeOptions]::Asynchronous)
    $pending = $null
    $reader = $null
    $readTask = $null
    $connectionCompleted = $false
    $sender = $null
    try {
        $pending = $pipe.BeginWaitForConnection($null, $null)
        $sender = & $StartSender
        if ($sender -isnot [Diagnostics.Process]) {
            throw 'The named-pipe sender did not return a process handle.'
        }
        if (-not $pending.AsyncWaitHandle.WaitOne(3000)) {
            $pipe.Dispose()
            try { $pipe.EndWaitForConnection($pending) } catch { }
            $connectionCompleted = $true
            throw 'Timed out waiting for the hook client pipe connection.'
        }
        $pipe.EndWaitForConnection($pending)
        $connectionCompleted = $true
        $reader = [IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false), $false, 1024, $true)
        $readTask = $reader.ReadLineAsync()
        if (-not $readTask.Wait(3000)) {
            $pipe.Dispose()
            try { $null = $readTask.GetAwaiter().GetResult() } catch { }
            throw 'Timed out waiting for a complete hook client pipe message.'
        }
        $line = $readTask.Result
        if ([string]::IsNullOrWhiteSpace($line)) {
            throw 'Hook client sent an empty pipe message.'
        }
        if (-not $sender.WaitForExit(3000)) {
            $sender.Kill()
            throw 'The named-pipe sender did not exit after delivering its message.'
        }
        if ($sender.ExitCode -notin $ExpectedExitCodes) {
            throw "The named-pipe sender exited with unexpected code $($sender.ExitCode)."
        }
        return $line | ConvertFrom-Json
    } finally {
        if ($null -ne $sender) {
            if (-not $sender.HasExited) {
                $sender.Kill()
                $sender.WaitForExit()
            }
            $sender.Dispose()
        }
        if ($null -ne $pending -and -not $connectionCompleted) {
            $pipe.Dispose()
            try { $pipe.EndWaitForConnection($pending) } catch { }
        }
        if ($null -ne $reader) {
            $reader.Dispose()
        }
        if ($null -ne $pending) {
            $pending.AsyncWaitHandle.Dispose()
        }
        $pipe.Dispose()
    }
}

function Start-HookClient {
    param([Parameter(Mandatory = $true)][string]$Json)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $HookClient
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $process.StandardInput.Write($Json)
        $process.StandardInput.Close()
        return $process
    } catch {
        if (-not $process.HasExited) { $process.Kill() }
        $process.Dispose()
        throw
    }
}

function Start-TestLauncher {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Launcher
    $startInfo.Arguments = "--working-directory `"$launcherProject`""
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    return [Diagnostics.Process]::Start($startInfo)
}

$originalInstanceId = [Environment]::GetEnvironmentVariable('CODEX_KEYBOARD_INSTANCE_ID', 'Process')
$originalPath = $env:PATH
$originalLauncherProbe = $env:CODEX_LAUNCH_PROBE
$originalFakeExit = $env:CODEX_LAUNCH_FAKE_EXIT
$originalTestHookClient = $env:CODEX_TEST_HOOK_CLIENT
$originalTestPipeName = $env:CODEX_KEYBOARD_TEST_STATUS_PIPE_NAME
$originalHookDiagnostics = $env:CODEX_KEYBOARD_TEST_HOOK_DIAGNOSTICS
try {
    Write-Output 'HOOK_ROUTING_STAGE setup'
    $env:CODEX_KEYBOARD_TEST_STATUS_PIPE_NAME = $pipeName
    $env:CODEX_KEYBOARD_TEST_HOOK_DIAGNOSTICS = '1'
    New-Item -ItemType Directory -Path $testRoot, $launcherProject, $fakeCodexBin -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $fakeNpmRoot 'codex.cmd'), "@echo off`r`n", [Text.Encoding]::ASCII)
    $fakeCodex = @'
const fs = require("node:fs");
const childProcess = require("node:child_process");
fs.writeFileSync(process.env.CODEX_LAUNCH_PROBE, JSON.stringify({
  instance: process.env.CODEX_KEYBOARD_INSTANCE_ID || null,
  launcherPid: process.ppid
}), "utf8");
if (process.env.CODEX_TEST_HOOK_CLIENT) {
  childProcess.spawnSync(process.env.CODEX_TEST_HOOK_CLIENT, [], {
    input: '{"hook_event_name":"UserPromptSubmit","session_id":"launcher-hook-session","turn_id":"launcher-hook-turn"}',
    stdio: ["pipe", "ignore", "ignore"]
  });
}
process.exit(Number.parseInt(process.env.CODEX_LAUNCH_FAKE_EXIT || "0", 10));
'@
    [IO.File]::WriteAllText(
        (Join-Path $fakeCodexBin 'codex.js'),
        $fakeCodex,
        [Text.UTF8Encoding]::new($false))
    $env:PATH = "$fakeNpmRoot;$originalPath"
    $env:CODEX_LAUNCH_PROBE = $launcherProbePath

    $instanceId = [Guid]::NewGuid().ToString('N')
    $env:CODEX_KEYBOARD_INSTANCE_ID = $instanceId
    $payload = '{"hook_event_name":"UserPromptSubmit","session_id":"session-probe","turn_id":"turn-probe"}'
    [IO.File]::WriteAllText($inputPath, $payload, [Text.UTF8Encoding]::new($false))
    Write-Output 'HOOK_ROUTING_STAGE unscoped'
    $hookMessage = Receive-StatusMessage -StartSender {
        Start-HookClient -Json (Get-Content -LiteralPath $inputPath -Raw -Encoding UTF8)
    }
    if ($hookMessage.eventName -cne 'UserPromptSubmit' -or
        $hookMessage.sessionId -cne 'session-probe' -or
        $hookMessage.turnId -cne 'turn-probe' -or
        $null -ne $hookMessage.instanceId -or
        $hookMessage.sourceKind -cne 'unscoped' -or
        $hookMessage.isError) {
        throw "Native hook routing mismatch: $($hookMessage | ConvertTo-Json -Compress)"
    }
    if ($null -ne $hookMessage.launcherProcessId) {
        throw "A hook client outside Start-CodexCli reported a launcher PID: $($hookMessage.launcherProcessId)"
    }

    $env:CODEX_LAUNCH_PROBE = $launcherHookProbePath
    $env:CODEX_TEST_HOOK_CLIENT = (Resolve-Path -LiteralPath $HookClient).Path
    Write-Output 'HOOK_ROUTING_STAGE dedicated-hook'
    $launcherHookMessage = Receive-StatusMessage -StartSender {
        Start-TestLauncher
    }
    $launcherHookProbe = Get-Content -LiteralPath $launcherHookProbePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($launcherHookMessage.eventName -cne 'UserPromptSubmit' -or
        $launcherHookMessage.instanceId -cne $launcherHookProbe.instance -or
        [int]$launcherHookMessage.launcherProcessId -ne [int]$launcherHookProbe.launcherPid -or
        $launcherHookMessage.sourceKind -cne 'dedicated_cli' -or
        $null -ne $launcherHookMessage.producerProcessId) {
        throw "Launcher ancestry routing mismatch: $($launcherHookMessage | ConvertTo-Json -Compress)"
    }
    Remove-Item Env:CODEX_TEST_HOOK_CLIENT -ErrorAction SilentlyContinue

    $env:CODEX_LAUNCH_PROBE = $launcherProbePath
    Write-Output 'HOOK_ROUTING_STAGE normal-end'
    $instanceEnd = Receive-StatusMessage -StartSender {
        Start-TestLauncher
    }
    $launcherProbe = Get-Content -LiteralPath $launcherProbePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($instanceEnd.eventName -cne 'InstanceEnd' -or
        $null -ne $instanceEnd.sessionId -or
        $null -ne $instanceEnd.turnId -or
        $instanceEnd.instanceId -cne $launcherProbe.instance -or
        $instanceEnd.sourceKind -cne 'dedicated_cli' -or
        [string]$launcherProbe.instance -cnotmatch '^[0-9a-f]{32}$' -or
        $instanceEnd.isError) {
        throw "Native launcher InstanceEnd mismatch: $($instanceEnd | ConvertTo-Json -Compress)"
    }

    $env:CODEX_LAUNCH_PROBE = $launcherErrorProbePath
    $env:CODEX_LAUNCH_FAKE_EXIT = '42'
    Write-Output 'HOOK_ROUTING_STAGE error-end'
    $errorInstanceEnd = Receive-StatusMessage -StartSender { Start-TestLauncher } -ExpectedExitCodes @(42)
    $errorProbe = Get-Content -LiteralPath $launcherErrorProbePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($errorInstanceEnd.eventName -cne 'InstanceEnd' -or
        $errorInstanceEnd.instanceId -cne $errorProbe.instance -or
        -not $errorInstanceEnd.isError) {
        throw "Native launcher error InstanceEnd mismatch: $($errorInstanceEnd | ConvertTo-Json -Compress)"
    }

    $env:CODEX_LAUNCH_PROBE = $launcherInterruptProbePath
    $env:CODEX_LAUNCH_FAKE_EXIT = '130'
    Write-Output 'HOOK_ROUTING_STAGE interrupt-end'
    $interruptInstanceEnd = Receive-StatusMessage -StartSender { Start-TestLauncher } -ExpectedExitCodes @(130)
    $interruptProbe = Get-Content -LiteralPath $launcherInterruptProbePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($interruptInstanceEnd.eventName -cne 'InstanceEnd' -or
        $interruptInstanceEnd.instanceId -cne $interruptProbe.instance -or
        $interruptInstanceEnd.isError) {
        throw "Native launcher interrupted InstanceEnd mismatch: $($interruptInstanceEnd | ConvertTo-Json -Compress)"
    }

    $env:CODEX_KEYBOARD_INSTANCE_ID = 'invalid instance id'
    Write-Output 'HOOK_ROUTING_STAGE invalid-instance'
    $withoutInstance = Receive-StatusMessage -StartSender {
        Start-HookClient -Json (Get-Content -LiteralPath $inputPath -Raw -Encoding UTF8)
    }
    if ($null -ne $withoutInstance.instanceId) {
        throw "Unsafe environment ID was forwarded: $($withoutInstance.instanceId)"
    }
} finally {
    if ($null -eq $originalInstanceId) {
        Remove-Item Env:CODEX_KEYBOARD_INSTANCE_ID -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_KEYBOARD_INSTANCE_ID = $originalInstanceId
    }
    $env:PATH = $originalPath
    $env:CODEX_LAUNCH_PROBE = $originalLauncherProbe
    $env:CODEX_LAUNCH_FAKE_EXIT = $originalFakeExit
    $env:CODEX_TEST_HOOK_CLIENT = $originalTestHookClient
    if ($null -eq $originalTestPipeName) {
        Remove-Item Env:CODEX_KEYBOARD_TEST_STATUS_PIPE_NAME -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_KEYBOARD_TEST_STATUS_PIPE_NAME = $originalTestPipeName
    }
    if ($null -eq $originalHookDiagnostics) {
        Remove-Item Env:CODEX_KEYBOARD_TEST_HOOK_DIAGNOSTICS -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_KEYBOARD_TEST_HOOK_DIAGNOSTICS = $originalHookDiagnostics
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output 'CODEX_HOOK_INSTANCE_ROUTING_PASS unscopedOutsideLauncher=True launcherAncestryPid=True sourceKind=True nativeLauncherInstanceEnd=True errorExit=True interruptedExitCompleted=True unsafeIdRejected=True'
