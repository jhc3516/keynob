[CmdletBinding()]
param(
    [string]$Launcher,
    [ValidateRange(60, 3600)]
    [int]$DurationSeconds = 60
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$runtimeRoot = Join-Path $root '.runtime'
$testRoot = Join-Path $runtimeRoot ("native-launcher-resources-" + [Guid]::NewGuid().ToString('N'))
$projectDirectory = Join-Path $testRoot 'project'
$fakeNpmRoot = Join-Path $testRoot 'fake-npm'
$fakeCodexBin = Join-Path $fakeNpmRoot 'node_modules\@openai\codex\bin'
$probePath = Join-Path $testRoot 'probe.json'
$finishPath = Join-Path $testRoot 'finish.signal'
$Launcher = if ([string]::IsNullOrWhiteSpace($Launcher)) {
    Join-Path $root 'artifacts\portable\Start-CodexCli.exe'
} else {
    (Resolve-Path -LiteralPath $Launcher -ErrorAction Stop).Path
}
$originalPath = $env:PATH
$originalProbe = $env:CODEX_LAUNCH_PROBE
$originalFinish = $env:CODEX_LAUNCH_FINISH
$launcherProcess = $null
$observedDescendants = @()

function Get-Descendants {
    param([int]$RootProcessId)

    $all = @(Get-CimInstance Win32_Process)
    $pending = [Collections.Generic.Queue[uint32]]::new()
    $pending.Enqueue([uint32]$RootProcessId)
    $result = [Collections.Generic.List[object]]::new()
    while ($pending.Count -gt 0) {
        $parentId = $pending.Dequeue()
        foreach ($child in $all | Where-Object { $_.ParentProcessId -eq $parentId }) {
            $result.Add($child)
            $pending.Enqueue([uint32]$child.ProcessId)
        }
    }
    return $result.ToArray()
}

try {
    if (-not (Test-Path -LiteralPath $Launcher -PathType Leaf)) {
        throw "Native Codex launcher is missing: $Launcher"
    }
    [IO.Directory]::CreateDirectory($projectDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($fakeCodexBin) | Out-Null
    [IO.File]::WriteAllText((Join-Path $fakeNpmRoot 'codex.cmd'), "@echo off`r`n", [Text.Encoding]::ASCII)
    $fixture = @'
const fs = require("node:fs");
const timer = setInterval(() => {
  if (!fs.existsSync(process.env.CODEX_LAUNCH_FINISH)) return;
  clearInterval(timer);
  fs.writeFileSync(process.env.CODEX_LAUNCH_PROBE, "{}", "utf8");
}, 100);
'@
    [IO.File]::WriteAllText(
        (Join-Path $fakeCodexBin 'codex.js'),
        $fixture,
        [Text.UTF8Encoding]::new($false))

    $env:PATH = "$fakeNpmRoot;$originalPath"
    $env:CODEX_LAUNCH_PROBE = $probePath
    $env:CODEX_LAUNCH_FINISH = $finishPath
    $launcherProcess = Start-Process -FilePath $Launcher `
        -ArgumentList @('--working-directory', ('"' + $projectDirectory + '"')) `
        -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2
    $launcherProcess.Refresh()
    if ($launcherProcess.HasExited) {
        throw "Native launcher exited before resource sampling: $($launcherProcess.ExitCode)"
    }

    $observedDescendants = @(Get-Descendants -RootProcessId $launcherProcess.Id)
    $forbidden = @($observedDescendants | Where-Object { $_.Name -in @('powershell.exe', 'pwsh.exe', 'cmd.exe') })
    if ($forbidden.Count -gt 0) {
        throw "Forbidden launcher descendants were found: $($forbidden.Name -join ', ')"
    }
    if (-not ($observedDescendants | Where-Object { $_.Name -eq 'node.exe' })) {
        throw 'The fake npm Node entry point was not a launcher descendant.'
    }

    $samples = [Collections.Generic.List[object]]::new()
    $cpuStart = $launcherProcess.TotalProcessorTime
    for ($index = 0; $index -lt ($DurationSeconds * 2); $index++) {
        Start-Sleep -Milliseconds 500
        $launcherProcess.Refresh()
        if ($launcherProcess.HasExited) {
            throw "Native launcher exited during resource sampling: $($launcherProcess.ExitCode)"
        }
        $samples.Add([pscustomobject]@{
            WorkingSet = [double]$launcherProcess.WorkingSet64
            Private = [double]$launcherProcess.PrivateMemorySize64
        })
    }
    $launcherProcess.Refresh()
    $cpuMilliseconds = ($launcherProcess.TotalProcessorTime - $cpuStart).TotalMilliseconds
    $averageWorkingSetMb = (($samples | Measure-Object WorkingSet -Average).Average / 1MB)
    $averagePrivateMb = (($samples | Measure-Object Private -Average).Average / 1MB)
    $privateGrowthMb = (($samples[$samples.Count - 1].Private - $samples[0].Private) / 1MB)
    $privateSavingsMb = 71.1 - $averagePrivateMb
    $allowedCpuMilliseconds = [Math]::Ceiling($DurationSeconds / 60.0) * 100

    if ($averagePrivateMb -gt 10) {
        throw ("Native launcher average Private Memory exceeded 10MB: {0:N2}MB" -f $averagePrivateMb)
    }
    if ($averageWorkingSetMb -gt 15) {
        throw ("Native launcher average Working Set exceeded 15MB: {0:N2}MB" -f $averageWorkingSetMb)
    }
    if ($privateSavingsMb -lt 50) {
        throw ("Native launcher Private Memory savings were below 50MB: {0:N2}MB" -f $privateSavingsMb)
    }
    if ($cpuMilliseconds -gt $allowedCpuMilliseconds) {
        throw ("Native launcher CPU exceeded the limit: {0:N2}ms > {1:N2}ms" -f $cpuMilliseconds, $allowedCpuMilliseconds)
    }
    if ($DurationSeconds -ge 1800 -and $privateGrowthMb -gt 2) {
        throw ("Native launcher 30-minute Private Memory growth exceeded 2MB: {0:N2}MB" -f $privateGrowthMb)
    }

    [IO.File]::WriteAllText($finishPath, 'finish', [Text.Encoding]::ASCII)
    if (-not $launcherProcess.WaitForExit(20000)) {
        throw 'Native launcher did not exit after the fake Codex entry point completed.'
    }
    if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
        throw 'The fake Codex entry point did not acknowledge the finish signal.'
    }
    $leftoverChildren = @($observedDescendants | Where-Object {
        Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
    })
    if ($leftoverChildren.Count -gt 0) {
        throw "Native launcher child processes remained after exit: $($leftoverChildren.Name -join ', ')"
    }
    Write-Output ("CODEX_NATIVE_LAUNCHER_RESOURCES_PASS durationSeconds={0} averagePrivateMb={1:N2} averageWorkingSetMb={2:N2} privateSavingsMb={3:N2} privateGrowthMb={4:N2} cpuMs={5:N2} powershellDescendants=0 cmdDescendants=0 leftoverProcessTree=0" -f `
        $DurationSeconds, $averagePrivateMb, $averageWorkingSetMb, $privateSavingsMb, $privateGrowthMb, $cpuMilliseconds)
} finally {
    $env:PATH = $originalPath
    $env:CODEX_LAUNCH_PROBE = $originalProbe
    $env:CODEX_LAUNCH_FINISH = $originalFinish
    foreach ($child in @($observedDescendants | Sort-Object ProcessId -Descending)) {
        Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $launcherProcess -and -not $launcherProcess.HasExited) {
        Stop-Process -Id $launcherProcess.Id -Force -ErrorAction SilentlyContinue
    }
    $resolvedRuntimeRoot = [IO.Path]::GetFullPath($runtimeRoot).TrimEnd('\') + '\'
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTestRoot.StartsWith($resolvedRuntimeRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
