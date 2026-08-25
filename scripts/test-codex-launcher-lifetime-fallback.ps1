[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $root 'artifacts\app\Start-CodexCli.exe'
$hookClient = Join-Path $root 'artifacts\portable\CodexStatusHookClient.exe'
$startScript = Join-Path $PSScriptRoot 'start-background.ps1'
$stopScript = Join-Path $PSScriptRoot 'stop-background.ps1'
$logPath = Join-Path $env:LOCALAPPDATA 'CodexKeyboardStudio\diagnostic.log'
$testRoot = Join-Path $root ('.runtime\launcher-lifetime-' + [Guid]::NewGuid().ToString('N'))
$projectDirectory = Join-Path $testRoot 'project'
$fakeNpmRoot = Join-Path $testRoot 'fake-npm'
$fakeCodexBin = Join-Path $fakeNpmRoot 'node_modules\@openai\codex\bin'
$probePath = Join-Path $testRoot 'probe.json'
$originalPath = $env:PATH
$originalProbe = $env:CODEX_LIFETIME_PROBE
$originalHookClient = $env:CODEX_LIFETIME_HOOK_CLIENT
$originalNoHardwareWrites = $env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES
$launcherProcess = $null
$nodeProcessId = $null
$env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES = '1'

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

try {
    foreach ($required in @($launcher, $hookClient, $startScript, $stopScript)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Required test input is missing: $required"
        }
    }
    [IO.Directory]::CreateDirectory($projectDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($fakeCodexBin) | Out-Null
    [IO.File]::WriteAllText((Join-Path $fakeNpmRoot 'codex.cmd'), "@echo off`r`n", [Text.Encoding]::ASCII)
    $fixture = @'
const fs = require("node:fs");
const childProcess = require("node:child_process");
fs.writeFileSync(process.env.CODEX_LIFETIME_PROBE, JSON.stringify({
  instanceId: process.env.CODEX_KEYBOARD_INSTANCE_ID,
  launcherPid: process.ppid,
  nodePid: process.pid
}), "utf8");
const hook = childProcess.spawnSync(process.env.CODEX_LIFETIME_HOOK_CLIENT, [], {
  input: '{"hook_event_name":"UserPromptSubmit","session_id":"lifetime-session","turn_id":"lifetime-turn"}',
  stdio: ["pipe", "ignore", "ignore"]
});
if (hook.status !== 0) process.exit(70);
setInterval(() => {}, 1000);
'@
    [IO.File]::WriteAllText(
        (Join-Path $fakeCodexBin 'codex.js'),
        $fixture,
        [Text.UTF8Encoding]::new($false))

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stopScript | Out-Null
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startScript | Out-Null
    $baseline = @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count

    $env:PATH = "$fakeNpmRoot;$originalPath"
    $env:CODEX_LIFETIME_PROBE = $probePath
    $env:CODEX_LIFETIME_HOOK_CLIENT = $hookClient
    $launcherProcess = Start-Process -FilePath $launcher `
        -ArgumentList @('--working-directory', ('"' + $projectDirectory + '"')) `
        -WindowStyle Hidden -PassThru

    Wait-ForCondition { Test-Path -LiteralPath $probePath -PathType Leaf } `
        'The lifetime fixture did not write its process probe.'
    $probe = Get-Content -LiteralPath $probePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $nodeProcessId = [int]$probe.nodePid
    if ([int]$probe.launcherPid -ne $launcherProcess.Id -or
        [string]$probe.instanceId -cnotmatch '^[0-9a-f]{32}$') {
        throw "Lifetime fixture process identity mismatch: $($probe | ConvertTo-Json -Compress)"
    }

    Wait-ForCondition {
        @(Get-NewLogLines $baseline | Where-Object {
            $_ -match "codex_launcher_watch_started\s+instance=$($probe.instanceId);pid=$($launcherProcess.Id)"
        }).Count -gt 0
    } 'The app did not register the launcher lifetime watcher.'
    Wait-ForCondition {
        @(Get-NewLogLines $baseline | Where-Object { $_ -match 'codex_status_changed\s+status=running' }).Count -gt 0
    } 'The fixture prompt did not set the running status.'

    Stop-Process -Id $launcherProcess.Id -Force
    $launcherProcess.WaitForExit(3000) | Out-Null
    Wait-ForCondition {
        @(Get-NewLogLines $baseline | Where-Object {
            $_ -match "codex_launcher_exit_fallback\s+instance=$($probe.instanceId);pid=$($launcherProcess.Id)"
        }).Count -gt 0
    } 'The launcher exit fallback was not applied.'
    Wait-ForCondition {
        @(Get-NewLogLines $baseline | Where-Object { $_ -match 'codex_status_changed\s+status=completed' }).Count -gt 0
    } 'The launcher exit fallback did not complete the status.'
    Wait-ForCondition {
        @(Get-NewLogLines $baseline | Where-Object {
            $_ -match 'codex_led_applied\s+status=completed'
        }).Count -gt 0
    } 'The launcher exit fallback did not apply the completed LED.'

    Write-Output "CODEX_LAUNCHER_LIFETIME_PASS launcherPid=$($launcherProcess.Id) instance=$($probe.instanceId) forcedExitFallback=True completedLed=True"
} finally {
    $env:PATH = $originalPath
    $env:CODEX_LIFETIME_PROBE = $originalProbe
    $env:CODEX_LIFETIME_HOOK_CLIENT = $originalHookClient
    if ($null -eq $originalNoHardwareWrites) {
        Remove-Item Env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES = $originalNoHardwareWrites
    }
    if ($null -ne $nodeProcessId) {
        Stop-Process -Id $nodeProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $launcherProcess -and -not $launcherProcess.HasExited) {
        Stop-Process -Id $launcherProcess.Id -Force -ErrorAction SilentlyContinue
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stopScript | Out-Null
    $runtimeRoot = [IO.Path]::GetFullPath((Join-Path $root '.runtime')).TrimEnd('\') + '\'
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTestRoot.StartsWith($runtimeRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
