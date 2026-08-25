[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$running = @(Get-Process CodexKeyboardStudio -ErrorAction SilentlyContinue)
$script = if ($running.Count -gt 0) { 'stop-background.ps1' } else { 'start-background.ps1' }
& (Join-Path $PSScriptRoot $script)
