[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$portable = Join-Path $root 'artifacts\portable\CodexKeyboardStudio.exe'
$framework = Join-Path $root 'artifacts\app\CodexKeyboardStudio.exe'
$app = if (Test-Path -LiteralPath $portable) { $portable } else { $framework }
if (-not (Test-Path -LiteralPath $app)) {
    throw 'Codex Keyboard Studio is missing. Run scripts\build-v1-portable.ps1 first.'
}

$logPath = Join-Path $env:LOCALAPPDATA 'CodexKeyboardStudio\diagnostic.log'
$logBaseline = if (Test-Path -LiteralPath $logPath) {
    @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
} else { 0 }
$before = @(Get-Process CodexKeyboardStudio -ErrorAction SilentlyContinue)
Start-Process -FilePath $app -ArgumentList '--background' -WorkingDirectory (Split-Path -Parent $app) -WindowStyle Hidden
Start-Sleep -Milliseconds 700
$after = @(Get-Process CodexKeyboardStudio -ErrorAction SilentlyContinue)
if ($after.Count -ne 1) {
    throw "Expected one background app process, found $($after.Count)."
}
$mode = if ($before.Count -eq 0) { 'started' } else { 'already-running' }
if ($mode -eq 'started') {
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 100
        $newLogLines = if (Test-Path -LiteralPath $logPath) {
            @(Get-Content -LiteralPath $logPath -Encoding UTF8 | Select-Object -Skip $logBaseline)
        } else { @() }
        $hookStarted = @($newLogLines | Where-Object { $_ -match "\thook_started\t" }).Count -gt 0
        $after = @(Get-Process CodexKeyboardStudio -ErrorAction SilentlyContinue)
    } until (($hookStarted -and $after.Count -eq 1) -or [DateTime]::UtcNow -ge $deadline)
    if (-not $hookStarted -or $after.Count -ne 1) {
        throw 'Background app did not initialize its keyboard hook.'
    }
    Start-Sleep -Seconds 2
    $after = @(Get-Process CodexKeyboardStudio -ErrorAction SilentlyContinue)
    if ($after.Count -ne 1) {
        throw 'Background app exited during the startup stability check.'
    }
}
Write-Output "V1_BACKGROUND_OK mode=$mode pid=$($after[0].Id) path=$($after[0].Path)"
