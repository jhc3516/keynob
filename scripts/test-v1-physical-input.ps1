[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'key01','key02','key03','key04','key05','key06','key07','key08','key09','key10','key11','key12',
        'knob1_ccw','knob1_press','knob1_cw','knob2_ccw','knob2_press','knob2_cw')]
    [string]$InputId,
    [Parameter(Mandatory = $true)]
    [ValidateSet('accepted','blocked','accepted-with-duplicate','single-action')]
    [string]$ExpectedOutcome,
    [ValidateRange(3, 60)]
    [int]$TimeoutSeconds = 15,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$siblingApp = Join-Path $PSScriptRoot 'Keynob.exe'
$repoApp = Join-Path $root 'artifacts\portable\Keynob.exe'
$app = if (Test-Path -LiteralPath $siblingApp) { $siblingApp } else { $repoApp }
if (-not (Test-Path -LiteralPath $app)) {
    throw 'Codex Keyboard Studio portable app is missing.'
}
if ($ValidateOnly) {
    Write-Output "V1_PHYSICAL_INPUT_TEST_READY app=$app inputs=18 outcomes=4"
    exit 0
}

$processes = @(Get-Process Keynob -ErrorAction SilentlyContinue)
if ($processes.Count -eq 0) {
    Start-Process -FilePath $app -ArgumentList '--background' -WorkingDirectory (Split-Path -Parent $app) -WindowStyle Hidden
    Start-Sleep -Milliseconds 700
    $processes = @(Get-Process Keynob -ErrorAction SilentlyContinue)
}
if ($processes.Count -ne 1) {
    throw "Expected one Codex Keyboard Studio process, found $($processes.Count)."
}

$logPath = Join-Path $env:LOCALAPPDATA 'CodexKeyboardStudio\diagnostic.log'
$baseline = if (Test-Path -LiteralPath $logPath) {
    @(Get-Content -LiteralPath $logPath -Encoding UTF8).Count
} else { 0 }

Write-Host "Keep the target app in the foreground and press $InputId once. Timeout: $TimeoutSeconds seconds." -ForegroundColor Cyan
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$inputPattern = 'input=' + [regex]::Escape($InputId) + '(?:;|$)'
$duplicatePattern = '\tinput_duplicate\t' + [regex]::Escape($InputId) + '$'
$singleActionObservedAt = $null
do {
    Start-Sleep -Milliseconds 100
    $lines = if (Test-Path -LiteralPath $logPath) {
        @(Get-Content -LiteralPath $logPath -Encoding UTF8 | Select-Object -Skip $baseline)
    } else { @() }
    $inputLines = @($lines | Where-Object { $_ -match $inputPattern })
    $actionCount = @($inputLines | Where-Object { $_ -match "\t(input_dispatched|input_passthrough)\t" }).Count
    $accepted = $actionCount -gt 0
    $blocked = @($inputLines | Where-Object { $_ -match "\tinput_blocked\t" }).Count -gt 0
    $duplicate = @($lines | Where-Object { $_ -match $duplicatePattern }).Count -gt 0

    $passed = switch ($ExpectedOutcome) {
        'accepted' { $accepted }
        'blocked' { $blocked }
        'accepted-with-duplicate' { $accepted -and $duplicate }
        'single-action' {
            if ($actionCount -gt 1) {
                throw "Physical input executed more than once. input=$InputId actionCount=$actionCount"
            }
            if ($actionCount -eq 1 -and $null -eq $singleActionObservedAt) {
                $singleActionObservedAt = [DateTime]::UtcNow
            }
            $null -ne $singleActionObservedAt -and
                [DateTime]::UtcNow -ge $singleActionObservedAt.AddMilliseconds(500)
        }
    }
    if ($passed) {
        Write-Output "V1_PHYSICAL_INPUT_PASS input=$InputId outcome=$ExpectedOutcome actionCount=$actionCount accepted=$accepted blocked=$blocked duplicate=$duplicate"
        exit 0
    }
} until ([DateTime]::UtcNow -ge $deadline)

throw "Physical input was not observed as expected. input=$InputId outcome=$ExpectedOutcome"
