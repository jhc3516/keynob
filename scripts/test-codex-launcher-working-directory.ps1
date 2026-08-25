[CmdletBinding()]
param(
    [string]$Launcher
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$runtimeRoot = Join-Path $root '.runtime'
$testRoot = Join-Path $runtimeRoot ("native-launcher-" + [Guid]::NewGuid().ToString('N'))
$koreanFolderPrefix = ([string][char]0xD55C) + ([string][char]0xAE00)
$projectDirectory = Join-Path $testRoot ($koreanFolderPrefix + ' project & safe')
$fakeNpmRoot = Join-Path $testRoot 'fake-npm'
$fakeCodexBin = Join-Path $fakeNpmRoot 'node_modules\@openai\codex\bin'
$fakeCodexScript = Join-Path $fakeCodexBin 'codex.js'
$fakeCodexCommand = Join-Path $fakeNpmRoot 'codex.cmd'
$shadowCodexBin = Join-Path $projectDirectory 'node_modules\@openai\codex\bin'
$probePath = Join-Path $testRoot 'probe.json'
$secondProbePath = Join-Path $testRoot 'probe-second.json'
$rootProbePath = Join-Path $testRoot 'probe-root.json'
$interruptProbePath = Join-Path $testRoot 'probe-interrupt.json'
$concurrentProbePath = Join-Path $testRoot 'probe-concurrent.json'
$concurrentSecondProbePath = Join-Path $testRoot 'probe-concurrent-second.json'
$injectionSentinel = Join-Path $testRoot 'injected.txt'
$Launcher = if ([string]::IsNullOrWhiteSpace($Launcher)) {
    Join-Path $root 'artifacts\app\Start-CodexCli.exe'
} else {
    (Resolve-Path -LiteralPath $Launcher -ErrorAction Stop).Path
}
$originalPath = $env:PATH
$originalProbe = $env:CODEX_LAUNCH_PROBE
$originalFakeExit = $env:CODEX_LAUNCH_FAKE_EXIT
$originalFakeDelay = $env:CODEX_LAUNCH_FAKE_DELAY
$firstConcurrent = $null
$secondConcurrent = $null

try {
    if (-not (Test-Path -LiteralPath $Launcher -PathType Leaf)) {
        throw "Native Codex launcher is missing: $Launcher"
    }
    [IO.Directory]::CreateDirectory($projectDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($fakeCodexBin) | Out-Null
    [IO.Directory]::CreateDirectory($shadowCodexBin) | Out-Null
    [IO.File]::WriteAllText($fakeCodexCommand, "@echo off`r`n", [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $projectDirectory 'codex.cmd'), "@echo off`r`n", [Text.Encoding]::ASCII)
    $shadowFixture = 'require("node:fs").writeFileSync(' +
        'process.env.CODEX_LAUNCH_INJECTION_SENTINEL, "unsafe", "utf8");'
    [IO.File]::WriteAllText(
        (Join-Path $shadowCodexBin 'codex.js'),
        $shadowFixture,
        [Text.UTF8Encoding]::new($false))
    $fixture = @'
const fs = require("node:fs");

const delay = Number.parseInt(process.env.CODEX_LAUNCH_FAKE_DELAY || "100", 10);
const exitCode = Number.parseInt(process.env.CODEX_LAUNCH_FAKE_EXIT || "0", 10);
setTimeout(() => {
  const record = {
    cwd: process.cwd(),
    args: process.argv.slice(2),
    instance: process.env.CODEX_KEYBOARD_INSTANCE_ID || null,
  };
  fs.writeFileSync(process.env.CODEX_LAUNCH_PROBE, JSON.stringify(record), "utf8");
  process.exit(exitCode);
}, delay);
'@
    [IO.File]::WriteAllText($fakeCodexScript, $fixture, [Text.UTF8Encoding]::new($false))

    $env:PATH = "$fakeNpmRoot;$originalPath"
    $env:CODEX_LAUNCH_PROBE = $probePath
    $env:CODEX_LAUNCH_INJECTION_SENTINEL = $injectionSentinel

    $strictErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        & $Launcher --unsupported-option 2>$null
        $unsupportedExit = $LASTEXITCODE
        & $Launcher --working-directory (Join-Path $testRoot 'missing') --validate-only 2>$null
        $missingDirectoryExit = $LASTEXITCODE
        $fakePath = $env:PATH
        $env:PATH = $testRoot
        & $Launcher --working-directory $projectDirectory --validate-only 2>$null
        $missingCodexExit = $LASTEXITCODE
        $env:PATH = $fakePath
    } finally {
        $ErrorActionPreference = $strictErrorPreference
    }
    if ($unsupportedExit -ne 64) {
        throw "Unsupported launcher option did not return 64: $unsupportedExit"
    }
    if ($missingDirectoryExit -ne 66) {
        throw "Missing working directory did not return 66: $missingDirectoryExit"
    }
    if ($missingCodexExit -ne 69) {
        throw "Missing npm Codex did not return 69: $missingCodexExit"
    }

    $validation = & $Launcher --working-directory $projectDirectory --validate-only
    $validationText = $validation -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0 -or
        $validationText -notmatch '^CODEX_NATIVE_LAUNCHER_READY ' -or
        $validationText -notmatch 'titleGuardMs=750(?:\s|$)' -or
        $validationText -notmatch 'terminalTitleUpdates=False(?:\s|$)' -or
        $validationText -notmatch 'shell=False(?:\s|$)') {
        throw "Native launcher validation mismatch: $validationText"
    }

    $titleValidation = & $Launcher --working-directory $projectDirectory --validate-title-guard
    $titleValidationText = $titleValidation -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0 -or
        $titleValidationText -notmatch '^CODEX_TITLE_GUARD_PASS intervalMs=750 ') {
        throw "Native title guard validation failed: $titleValidationText"
    }

    Push-Location -LiteralPath $projectDirectory
    try {
        & $Launcher --working-directory $projectDirectory
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Native launcher probe failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $probePath)) {
        throw 'Fake Codex entry point did not receive the launcher invocation.'
    }
    $probe = Get-Content -LiteralPath $probePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [string]::Equals($probe.cwd, $projectDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Launcher working directory mismatch. expected=$projectDirectory actual=$($probe.cwd)"
    }
    if ($probe.args.Count -ne 4 -or
        $probe.args[0] -cne '--config' -or
        $probe.args[1] -cne 'tui.terminal_title=[]' -or
        $probe.args[2] -cne '-C' -or
        -not [string]::Equals($probe.args[3], $projectDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Launcher arguments mismatch: $($probe.args -join '|')"
    }
    if ([string]$probe.instance -cnotmatch '^[0-9a-f]{32}$') {
        throw "Launcher instance ID was invalid: $($probe.instance)"
    }
    if (Test-Path -LiteralPath $injectionSentinel) {
        throw "Working directory text was interpreted as a shell command: $injectionSentinel"
    }

    $env:CODEX_LAUNCH_PROBE = $secondProbePath
    & $Launcher --working-directory $projectDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "Second native launcher probe failed with exit code $LASTEXITCODE."
    }
    $secondProbe = Get-Content -LiteralPath $secondProbePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$secondProbe.instance -cnotmatch '^[0-9a-f]{32}$' -or
        $secondProbe.instance -ceq $probe.instance) {
        throw "Launcher did not issue a unique second instance ID. first=$($probe.instance) second=$($secondProbe.instance)"
    }

    $driveRoot = [IO.Path]::GetPathRoot($root)
    $env:CODEX_LAUNCH_PROBE = $rootProbePath
    & $Launcher --working-directory $driveRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Drive-root launcher probe failed with exit code $LASTEXITCODE."
    }
    $rootProbe = Get-Content -LiteralPath $rootProbePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [string]::Equals($rootProbe.cwd, $driveRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $rootProbe.args.Count -ne 4 -or
        $rootProbe.args[0] -cne '--config' -or
        $rootProbe.args[1] -cne 'tui.terminal_title=[]' -or
        $rootProbe.args[2] -cne '-C' -or
        -not [string]::Equals($rootProbe.args[3], $driveRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Trailing-backslash working directory was not preserved: $($rootProbe | ConvertTo-Json -Compress)"
    }

    $env:CODEX_LAUNCH_PROBE = $interruptProbePath
    $env:CODEX_LAUNCH_FAKE_EXIT = '130'
    & $Launcher --working-directory $projectDirectory
    if ($LASTEXITCODE -ne 130) {
        throw "Interrupted native launcher did not preserve exit code 130: $LASTEXITCODE"
    }
    $interruptProbe = Get-Content -LiteralPath $interruptProbePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$interruptProbe.instance -cnotmatch '^[0-9a-f]{32}$') {
        throw "Interrupted launcher instance ID was invalid: $($interruptProbe.instance)"
    }

    Remove-Item Env:CODEX_LAUNCH_FAKE_EXIT -ErrorAction SilentlyContinue
    $env:CODEX_LAUNCH_PROBE = $concurrentProbePath
    $env:CODEX_LAUNCH_FAKE_DELAY = '500'
    $firstConcurrent = Start-Process -FilePath $Launcher `
        -ArgumentList @('--working-directory', ('"' + $projectDirectory + '"')) `
        -WindowStyle Hidden -PassThru
    $env:CODEX_LAUNCH_PROBE = $concurrentSecondProbePath
    $env:CODEX_LAUNCH_FAKE_DELAY = '1500'
    $secondConcurrent = Start-Process -FilePath $Launcher `
        -ArgumentList @('--working-directory', ('"' + $projectDirectory + '"')) `
        -WindowStyle Hidden -PassThru
    if (-not $firstConcurrent.WaitForExit(5000)) {
        throw 'First concurrent native launcher did not exit.'
    }
    $secondConcurrent.Refresh()
    if ($secondConcurrent.HasExited) {
        throw 'Second concurrent native launcher exited with the first instance.'
    }
    if (-not $secondConcurrent.WaitForExit(5000)) {
        throw 'Second concurrent native launcher did not exit.'
    }
    $firstConcurrentProbe = Get-Content -LiteralPath $concurrentProbePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $secondConcurrentProbe = Get-Content -LiteralPath $concurrentSecondProbePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$firstConcurrentProbe.instance -cnotmatch '^[0-9a-f]{32}$' -or
        [string]$secondConcurrentProbe.instance -cnotmatch '^[0-9a-f]{32}$' -or
        $firstConcurrentProbe.instance -ceq $secondConcurrentProbe.instance) {
        throw 'Concurrent native launchers did not use independent instance IDs.'
    }

    Write-Output "CODEX_NATIVE_LAUNCHER_PASS cwd=$($probe.cwd) titleGuardMs=750 titleGuardRestored=True terminalTitleUpdates=False instanceEnvironment=True uniqueInstances=True concurrentInstances=True independentLifetime=True exit130Preserved=True invalidArgumentsRejected=True missingCodexRejected=True specialPath=True driveRootPath=True currentDirectoryShadowIgnored=True shell=False"
} finally {
    $env:PATH = $originalPath
    $env:CODEX_LAUNCH_PROBE = $originalProbe
    $env:CODEX_LAUNCH_FAKE_EXIT = $originalFakeExit
    $env:CODEX_LAUNCH_FAKE_DELAY = $originalFakeDelay
    Remove-Item Env:CODEX_LAUNCH_INJECTION_SENTINEL -ErrorAction SilentlyContinue
    foreach ($process in @($firstConcurrent, $secondConcurrent)) {
        if ($null -ne $process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    $resolvedRuntimeRoot = [IO.Path]::GetFullPath($runtimeRoot).TrimEnd('\') + '\'
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTestRoot.StartsWith($resolvedRuntimeRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
