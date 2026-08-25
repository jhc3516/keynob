[CmdletBinding()]
param(
    [ValidateSet('key01','key02','key03','key04','key05','key06','key07','key08','key09','key10','key11','key12')]
    [string]$InputId = 'key12',
    [ValidateRange(5, 60)]
    [int]$Seconds = 15,
    [switch]$ConfirmHardwareWrite
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmHardwareWrite) {
    throw 'This test temporarily writes one slot. Pass -ConfirmHardwareWrite to continue.'
}

$root = Split-Path -Parent $PSScriptRoot
$localBridge = Join-Path $PSScriptRoot 'KeyboardDeviceBridge.exe'
$bridge = if (Test-Path -LiteralPath $localBridge) {
    $localBridge
} else {
    Join-Path $root 'artifacts\portable\KeyboardDeviceBridge.exe'
}
$monitor = Join-Path $PSScriptRoot 'monitor-key-events.ps1'
$slot = [int]$InputId.Substring(3)

$layer = (& $bridge read-layer1) | ConvertFrom-Json
if (-not $layer.ok) { throw 'Could not read layer 1.' }
$original = ($layer.slots | Where-Object slot -eq $slot | Select-Object -First 1).hex
if (-not $original) { throw "Missing original slot $slot." }

$report = [byte[]]::new(64)
$report[0] = 0x03
$report[1] = 0xfa
$report[2] = $slot
$report[3] = 0x01
$report[4] = 0x01
$report[6] = 0x01
$disabled = -join ($report | ForEach-Object { $_.ToString('x2') })

try {
    $write = (& $bridge program-report $InputId $original $disabled) | ConvertFrom-Json
    if (-not $write.ok -or -not $write.verified) { throw 'Disabled report write was not verified.' }
    Write-Output "DISABLED_TEST_ACTIVE input=$InputId seconds=$Seconds press_now=True"
    $monitorOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $monitor -Seconds $Seconds)
    $monitorOutput | Write-Output
    $keyEvents = @($monitorOutput | Where-Object { $_ -match '\bVK=\d+' })
    if ($keyEvents.Count -gt 0) {
        throw "Disabled input produced raw keyboard events: $($keyEvents -join ' | ')"
    }
    Write-Output "V2_DISABLED_INPUT_PASS input=$InputId rawKeyEvents=0"
}
finally {
    $currentRaw = & $bridge read-layer1
    if ($LASTEXITCODE -ne 0) { throw "CRITICAL: could not read $InputId before restore" }
    $currentLayer = $currentRaw | ConvertFrom-Json
    if (-not $currentLayer.ok) { throw "CRITICAL: device rejected read before restoring $InputId" }
    $current = ($currentLayer.slots | Where-Object slot -eq $slot | Select-Object -First 1).hex
    if (-not $current) { throw "CRITICAL: missing current slot while restoring $InputId" }
    if ($current -ne $original) {
        $restore = (& $bridge program-report $InputId $current $original) | ConvertFrom-Json
        if (-not $restore.ok -or -not $restore.verified) {
            throw "CRITICAL: failed to restore $InputId"
        }
    }
    $finalRaw = & $bridge read-layer1
    if ($LASTEXITCODE -ne 0) { throw "CRITICAL: could not verify restored $InputId" }
    $finalLayer = $finalRaw | ConvertFrom-Json
    $final = ($finalLayer.slots | Where-Object slot -eq $slot | Select-Object -First 1).hex
    if (-not $finalLayer.ok -or $final -ne $original) {
        throw "CRITICAL: independent reread did not match original $InputId"
    }
    Write-Output "DISABLED_TEST_RESTORED input=$InputId verified=True"
}
