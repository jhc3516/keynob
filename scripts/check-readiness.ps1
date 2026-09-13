[CmdletBinding()]
param(
    [switch]$DevelopmentWorktree
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$portable = Join-Path $root 'artifacts\portable'
$required = @(
    'Keynob.exe', 'KeyboardDeviceBridge.exe', 'CodexStatusHookClient.exe', 'Start-CodexCli.exe',
    'hidapi.dll', 'coreclr.dll', 'hostfxr.dll', 'PresentationFramework.dll', 'LICENSE', 'THIRD_PARTY_NOTICES.md',
    'DOTNET-LIBRARY-LICENSE.txt', 'DOTNET-MIT-LICENSE.txt', 'DOTNET-THIRD-PARTY-NOTICES.txt',
    'WPF-THIRD-PARTY-NOTICES.txt', 'WINDOWS-SDK-LICENSE.rtf',
    'Install-CodexHooks.ps1', 'set-codex-cli-status.ps1',
    'Run-CodexExecWithStatus.ps1', 'codex-json-status.ps1', 'Test-V1PhysicalInput.ps1'
)
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $portable $_)) })
if ($missing.Count -gt 0) { throw "Portable package is incomplete: $($missing -join ', ')" }
if (Test-Path -LiteralPath (Join-Path $portable 'Launch-CodexCli.ps1')) {
    throw 'Portable package still contains the persistent PowerShell Codex launcher.'
}

$bridge = Join-Path $portable 'KeyboardDeviceBridge.exe'
$probeRaw = & $bridge discover
if ($LASTEXITCODE -ne 0) { throw "Device probe failed: $probeRaw" }
$probe = $probeRaw | ConvertFrom-Json
if (-not $probe.ok -or -not $probe.connected) { throw 'The registered USB keyboard is not connected.' }

$hooksPath = Join-Path $env:USERPROFILE '.codex\hooks.json'
if (-not (Test-Path -LiteralPath $hooksPath)) { throw 'Global Codex hooks.json is missing.' }
$hookBytes = [IO.File]::ReadAllBytes($hooksPath)
if ($hookBytes.Length -ge 3 -and $hookBytes[0] -eq 0xef -and $hookBytes[1] -eq 0xbb -and $hookBytes[2] -eq 0xbf) {
    throw 'Global Codex hooks.json must be UTF-8 without BOM.'
}
$hooks = [Text.Encoding]::UTF8.GetString($hookBytes) | ConvertFrom-Json
$installedClient = Join-Path $env:USERPROFILE '.codex\CodexStatusHookClient.exe'
$events = @('SessionStart', 'UserPromptSubmit', 'PermissionRequest', 'PreToolUse', 'PostToolUse', 'Stop', 'SessionEnd')
foreach ($eventName in $events) {
    $groups = @($hooks.hooks.PSObject.Properties[$eventName].Value)
    $handlers = @(
        $groups |
            ForEach-Object { @($_.hooks) } |
            Where-Object { ([string]$_.command) -match '(?i)CodexStatusHookClient\.exe' }
    )
    if ($handlers.Count -ne 1) {
        throw "Expected one Codex status hook for $eventName, found $($handlers.Count)."
    }
    if ([string]$handlers[0].type -ne 'command' -or [int]$handlers[0].timeout -ne 1) {
        throw "Invalid Codex status hook definition for $eventName."
    }
}
if (-not (Test-Path -LiteralPath $installedClient)) {
    throw 'Installed Codex status hook client is missing.'
}
$portableClient = Join-Path $portable 'CodexStatusHookClient.exe'
$installedHash = (Get-FileHash -LiteralPath $installedClient -Algorithm SHA256).Hash
$portableHash = (Get-FileHash -LiteralPath $portableClient -Algorithm SHA256).Hash
$hookBinaryMatch = 'True'
$packageHookBinaryMatch = 'NotChecked'
if ($DevelopmentWorktree) {
    $frameworkClient = Join-Path $root 'artifacts\app\CodexStatusHookClient.exe'
    if (-not (Test-Path -LiteralPath $frameworkClient)) {
        throw 'Development app hook client is missing. Run build-v1-portable.ps1 first.'
    }
    $frameworkHash = (Get-FileHash -LiteralPath $frameworkClient -Algorithm SHA256).Hash
    if ($frameworkHash -ne $portableHash) {
        throw "Development app and portable hook clients differ. app=$frameworkHash portable=$portableHash"
    }
    $hookBinaryMatch = 'StableInstallPreserved'
    $packageHookBinaryMatch = 'True'
} elseif ($installedHash -ne $portableHash) {
    throw "Installed Codex hook client is stale. installed=$installedHash portable=$portableHash"
}
if (-not (Get-Command codex.cmd -ErrorAction SilentlyContinue)) { throw 'codex.cmd was not found in PATH.' }
$nativeLauncher = Join-Path $portable 'Start-CodexCli.exe'
$launcherResult = & $nativeLauncher --working-directory $env:TEMP --validate-only
if ($LASTEXITCODE -ne 0 -or $launcherResult -notmatch '^CODEX_NATIVE_LAUNCHER_READY') {
    throw "Portable Codex launcher validation failed: $launcherResult"
}
$titleGuardResult = & $nativeLauncher --working-directory $env:TEMP --validate-title-guard
if ($LASTEXITCODE -ne 0 -or $titleGuardResult -notmatch '^CODEX_TITLE_GUARD_PASS') {
    throw "Portable Codex title guard validation failed: $titleGuardResult"
}
$execWrapperResult = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $portable 'Run-CodexExecWithStatus.ps1') -Prompt validate -WorkingDirectory $env:TEMP -ValidateOnly
if ($LASTEXITCODE -ne 0 -or $execWrapperResult -notmatch '^CODEX_EXEC_WRAPPER_READY') {
    throw "Portable Codex exec wrapper validation failed: $execWrapperResult"
}
$physicalTestResult = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $portable 'Test-V1PhysicalInput.ps1') -InputId key01 -ExpectedOutcome blocked -ValidateOnly
if ($LASTEXITCODE -ne 0 -or $physicalTestResult -notmatch '^V1_PHYSICAL_INPUT_TEST_READY') {
    throw "Portable physical input test validation failed: $physicalTestResult"
}

Write-Output "V1_READINESS_PASS portable=True selfContained=True deviceConnected=True hooks=7 hookBinaryMatch=$hookBinaryMatch packageHookBinaryMatch=$packageHookBinaryMatch codexCli=True launchers=True titleGuard=True jsonStatusParser=True physicalInputTest=True arbitraryWorkingDirectory=True hookTrust=USER_CONFIRMATION_REQUIRED"
