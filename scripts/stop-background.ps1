[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$processes = @(Get-Process CodexKeyboardStudio -ErrorAction SilentlyContinue)
if ($processes.Count -eq 0) {
    Write-Output 'V1_BACKGROUND_STOP_OK mode=not-running'
    exit 0
}
if ($processes.Count -ne 1) {
    throw "Refusing ambiguous shutdown with $($processes.Count) processes."
}

$app = $processes[0].Path
$signal = Start-Process -FilePath $app -ArgumentList '--exit' -WorkingDirectory (Split-Path -Parent $app) -WindowStyle Hidden -PassThru
$signal.WaitForExit(3000) | Out-Null
if (-not $processes[0].WaitForExit(5000)) {
    throw 'Codex Keyboard Studio did not exit after the graceful shutdown signal.'
}
Write-Output 'V1_BACKGROUND_STOP_OK mode=graceful'
