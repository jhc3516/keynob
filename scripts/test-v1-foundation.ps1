[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$appDir = Join-Path $root 'artifacts\app'
$app = Join-Path $appDir 'CodexKeyboardStudio.exe'
$bridge = Join-Path $appDir 'KeyboardDeviceBridge.exe'
$hid = Join-Path $appDir 'hidapi.dll'

foreach ($required in @($app, $bridge, $hid)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing V1 artifact: $required"
    }
}

$transactionRaw = & $bridge self-test-transaction
if ($LASTEXITCODE -ne 0) {
    throw "Bridge transaction self-test exited with $LASTEXITCODE`: $transactionRaw"
}
$transaction = $transactionRaw | ConvertFrom-Json
if (-not $transaction.ok -or -not $transaction.endToEnd -or -not $transaction.slotWriteFailure -or
    -not $transaction.commitFailure -or -not $transaction.readFailure -or
    -not $transaction.forcedRestore -or -not $transaction.restoreFailureDetected) {
    throw "Bridge transaction fault injection failed: $transactionRaw"
}

$keyCatalogRaw = & $bridge self-test-key-catalog
if ($LASTEXITCODE -ne 0) {
    throw "Bridge key catalog self-test exited with $LASTEXITCODE`: $keyCatalogRaw"
}
$keyCatalog = $keyCatalogRaw | ConvertFrom-Json
if (-not $keyCatalog.ok -or -not $keyCatalog.standardKeyboardKeys -or
    -not $keyCatalog.consumerKeysRejected) {
    throw "Bridge key catalog validation failed: $keyCatalogRaw"
}

$deviceSafetyRaw = & $bridge self-test-device-safety
if ($LASTEXITCODE -ne 0) {
    throw "Bridge device safety self-test exited with $LASTEXITCODE`: $deviceSafetyRaw"
}
$deviceSafety = $deviceSafetyRaw | ConvertFrom-Json
if (-not $deviceSafety.ok -or -not $deviceSafety.differentSerial -or
    -not $deviceSafety.identityFilter -or -not $deviceSafety.multipleRejected -or
    -not $deviceSafety.invalidReportsRejected -or $deviceSafety.mutationWrites -ne 0) {
    throw "Bridge device safety validation failed: $deviceSafetyRaw"
}

$ledTransactionRaw = & $bridge self-test-led-transaction
if ($LASTEXITCODE -ne 0) {
    throw "Bridge LED transaction self-test exited with $LASTEXITCODE`: $ledTransactionRaw"
}
$ledTransaction = $ledTransactionRaw | ConvertFrom-Json
if (-not $ledTransaction.ok -or -not $ledTransaction.writeFailureRestored -or
    -not $ledTransaction.verifyFailureRestored -or -not $ledTransaction.restoreFailureDetected -or
    $ledTransaction.noOpWrites -ne 0) {
    throw "Bridge LED transaction validation failed: $ledTransactionRaw"
}

$raw = & $bridge discover
if ($LASTEXITCODE -ne 0) {
    throw "Device bridge exited with $LASTEXITCODE`: $raw"
}
$probe = $raw | ConvertFrom-Json
if (-not $probe.ok -or -not $probe.connected -or $probe.interface -ne 0 -or $probe.usagePage -ne 'FF00') {
    throw "Unexpected device probe response: $raw"
}

$ledReadRaw = & $bridge read-led
if ($LASTEXITCODE -ne 0) {
    throw "LED readback exited with $LASTEXITCODE`: $ledReadRaw"
}
$ledRead = $ledReadRaw | ConvertFrom-Json
if (-not $ledRead.ok -or -not $ledRead.connected -or $ledRead.mode -lt 0 -or
    $ledRead.mode -gt 5 -or $ledRead.colorsHex -notmatch '^[0-9a-f]{72}$') {
    throw "LED readback failed structural validation: $ledReadRaw"
}

$keymapRaw = & $bridge read-layer1
if ($LASTEXITCODE -ne 0) {
    throw "Layer 1 read exited with $LASTEXITCODE`: $keymapRaw"
}
$keymap = $keymapRaw | ConvertFrom-Json
$slots = @($keymap.slots)
$uniqueSlots = @($slots.slot | Sort-Object -Unique)
$invalidHex = @($slots | Where-Object { $_.hex.Length -ne 128 -or -not $_.hex.StartsWith('03fa') })
if (-not $keymap.ok -or $keymap.layer -ne 1 -or $slots.Count -ne 25 -or
    $uniqueSlots.Count -ne 25 -or $invalidHex.Count -ne 0) {
    throw 'Layer 1 keymap response failed structural validation.'
}

$aliasSlots = [ordered]@{
    key01 = 1; key02 = 2; key03 = 3; key04 = 4; key05 = 5; key06 = 6
    key07 = 7; key08 = 8; key09 = 9; key10 = 10; key11 = 11; key12 = 12
    knob1_ccw = 16; knob1_press = 17; knob1_cw = 18
    knob2_ccw = 19; knob2_press = 20; knob2_cw = 21
}
$encodedAliases = foreach ($entry in $aliasSlots.GetEnumerator()) {
    $encodedRaw = & $bridge encode-input $entry.Key
    if ($LASTEXITCODE -ne 0) {
        throw "Alias encoding failed for $($entry.Key): $encodedRaw"
    }
    $encoded = $encodedRaw | ConvertFrom-Json
    if (-not $encoded.ok -or $encoded.input -ne $entry.Key -or $encoded.slot -ne $entry.Value -or
        $encoded.hex.Length -ne 128 -or -not $encoded.hex.StartsWith('03fa')) {
        throw "Invalid alias encoding for $($entry.Key): $encodedRaw"
    }
    $encoded
}
if (@($encodedAliases.hex | Sort-Object -Unique).Count -ne 18) {
    throw 'Hardware aliases are not unique.'
}

$key04Encoding = $encodedAliases | Where-Object input -eq 'key04' | Select-Object -First 1
$expectedKey04Hex = '03fa04010100030000f10032f40032f3003200003200003200003200003200003200003200003200003200003200003200003200003200003200003200000000'
if ($key04Encoding.hex -ne $expectedKey04Hex) {
    throw 'KEY 4 must encode direct Ctrl+Win+Alt without an F4 key code.'
}

$key04Slot = $slots | Where-Object { $_.slot -eq 4 } | Select-Object -First 1
$genericNoOpRaw = & $bridge program-report key04 $key04Slot.hex $key04Slot.hex
if ($LASTEXITCODE -ne 0) {
    throw "Generic no-op programming exited with $LASTEXITCODE`: $genericNoOpRaw"
}
$genericNoOp = $genericNoOpRaw | ConvertFrom-Json
if (-not $genericNoOp.ok -or $genericNoOp.changed -or -not $genericNoOp.verified -or
    $genericNoOp.reportsWritten -ne 0) {
    throw "Generic no-op programming unexpectedly touched hardware: $genericNoOpRaw"
}

$key01Slot = $slots | Where-Object { $_.slot -eq 1 } | Select-Object -First 1
$unsafeReport = $key01Slot.hex.Substring(0, 18) + 'ff' + $key01Slot.hex.Substring(20)
$unsafeReportRaw = & $bridge program-report key01 $key01Slot.hex $unsafeReport
$unsafeReportExit = $LASTEXITCODE
$unsafeReportResult = $unsafeReportRaw | ConvertFrom-Json
if ($unsafeReportExit -ne 69 -or $unsafeReportResult.ok -or
    $unsafeReportResult.error -ne 'invalid_replacement_slot') {
    throw "Unsafe structured report was not rejected: $unsafeReportRaw"
}

$invalidInputRaw = & $bridge encode-input key99
$invalidInputExit = $LASTEXITCODE
$invalidInput = $invalidInputRaw | ConvertFrom-Json
if ($invalidInputExit -ne 67 -or $invalidInput.ok -or $invalidInput.error -ne 'unsupported_input') {
    throw "Unsupported physical input was not rejected safely: $invalidInputRaw"
}

$unsupportedRaw = & $bridge unsupported-command
$unsupportedExit = $LASTEXITCODE
$unsupported = $unsupportedRaw | ConvertFrom-Json
if ($unsupportedExit -ne 64 -or $unsupported.ok -or $unsupported.error -ne 'unsupported_command') {
    throw "Unsupported bridge command was not rejected safely: $unsupportedRaw"
}

$invalidColorRaw = & $bridge set-led black
$invalidColorExit = $LASTEXITCODE
$invalidColor = $invalidColorRaw | ConvertFrom-Json
if ($invalidColorExit -ne 65 -or $invalidColor.ok -or $invalidColor.error -ne 'unsupported_color') {
    throw "Unsupported LED color was not rejected safely: $invalidColorRaw"
}

$invalidLayoutRaw = & $bridge set-led-layout blue blue blue blue blue blue blue blue blue blue blue black
$invalidLayoutExit = $LASTEXITCODE
$invalidLayout = $invalidLayoutRaw | ConvertFrom-Json
if ($invalidLayoutExit -ne 65 -or $invalidLayout.ok -or $invalidLayout.error -ne 'unsupported_color') {
    throw "Unsupported LED layout color was not rejected safely: $invalidLayoutRaw"
}

$referenceReport0 = '03feb00001ff00000000ff0000ff0000ff0000ff0000ff0000ff0000ff0000ff0000ff0000ff0000ffff0000ffff0000ffff0000ff000000000000000000000000'
$encodedLayoutRaw = & $bridge encode-led-layout red blue blue blue blue blue blue blue blue blue blue blue
if ($LASTEXITCODE -ne 0) {
    throw "LED layout encoding failed: $encodedLayoutRaw"
}
$encodedLayout = $encodedLayoutRaw | ConvertFrom-Json
if (-not $encodedLayout.ok -or $encodedLayout.report0Hex -ne $referenceReport0) {
    throw 'LED layout report no longer matches the exact vendor capture.'
}

$extendedLayoutRaw = & $bridge encode-led-layout orange cyan purple pink blue yellow green red orange cyan purple pink
if ($LASTEXITCODE -ne 0) {
    throw "Extended LED palette encoding failed: $extendedLayoutRaw"
}
$extendedLayout = $extendedLayoutRaw | ConvertFrom-Json
$extendedReferenceColors = 'ff803000ffff800080ff66660000ffffff3c00ff00ff0000ff803000ffff800080ff6666'
if (-not $extendedLayout.ok -or $extendedLayout.report0Hex.Substring(10, 72) -ne $extendedReferenceColors) {
    throw 'Extended LED palette bytes do not match the expected report encoding.'
}

Write-Output "V1_FOUNDATION_PASS app=True bridge=True transactionFaults=endToEnd restoreFailureDetected=True ledTransaction=True ledRestoreFailureDetected=True commonKeyboardKeys=True consumerKeysRejected=True deviceConnected=$($probe.connected) ledReadback=True layer1Slots=$($slots.Count) aliases=18 genericNoOpWriteReports=0 unsafeReportRejected=True invalidInputRejected=True unsafeCommandRejected=True invalidColorRejected=True invalidLayoutRejected=True vendorRgbTemplate=True extendedLedPalette=True"
