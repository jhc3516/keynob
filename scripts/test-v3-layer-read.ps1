[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bridge = Join-Path $root 'artifacts\app\KeyboardDeviceBridge.exe'
if (-not (Test-Path -LiteralPath $bridge -PathType Leaf)) {
    $bridge = Join-Path $root 'artifacts\portable\KeyboardDeviceBridge.exe'
}
if (-not (Test-Path -LiteralPath $bridge -PathType Leaf)) {
    throw 'KeyboardDeviceBridge.exe is missing. Build the app first.'
}

foreach ($layer in 1..3) {
    $raw = & $bridge read-layer $layer
    if ($LASTEXITCODE -ne 0) {
        throw "Layer $layer read failed with exit code ${LASTEXITCODE}: $raw"
    }
    $response = $raw | ConvertFrom-Json
    if (-not $response.ok -or -not $response.connected -or $response.layer -ne $layer) {
        throw "Layer $layer response did not identify the connected target device."
    }
    if (@($response.slots).Count -ne 25 -or
        @($response.slots | Select-Object -ExpandProperty slot -Unique).Count -ne 25) {
        throw "Layer $layer did not return 25 unique slots."
    }
    foreach ($slot in $response.slots) {
        if ($slot.slot -lt 1 -or $slot.slot -gt 25 -or
            $slot.hex -notmatch '^[0-9a-fA-F]{128}$' -or
            $slot.hex.Substring(0, 4) -ine '03fa' -or
            $slot.hex.Substring(4, 2) -ine ('{0:x2}' -f $slot.slot) -or
            $slot.hex.Substring(6, 2) -ine ('{0:x2}' -f $layer)) {
            throw "Layer $layer slot $($slot.slot) has an invalid report header."
        }
    }
    Write-Output "LAYER_READ_PASS layer=$layer slots=25 hardwareWrites=False"
}
