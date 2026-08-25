[CmdletBinding()]
param(
    [switch]$UseExistingFrameworkArtifacts
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dotnet = 'C:\Program Files\dotnet\dotnet.exe'
$appProject = Join-Path $root 'src\CodexKeyboardStudio\CodexKeyboardStudio.csproj'
$nugetConfig = Join-Path $root 'NuGet.Portable.Config'
$frameworkBuild = Join-Path $root 'scripts\build-v1-app.ps1'
$frameworkArtifacts = Join-Path $root 'artifacts\app'
$portableDir = Join-Path $root 'artifacts\portable'
$dotnetAppData = Join-Path $root '.runtime\dotnet-appdata'
$nugetPackages = Join-Path $root '.runtime\nuget-packages'

if (-not $UseExistingFrameworkArtifacts) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $frameworkBuild
    if ($LASTEXITCODE -ne 0) {
        throw "Framework build failed with exit code $LASTEXITCODE"
    }
} elseif (-not (Test-Path -LiteralPath (Join-Path $frameworkArtifacts 'Start-CodexCli.exe'))) {
    throw 'Existing framework artifacts do not contain Start-CodexCli.exe.'
}

New-Item -ItemType Directory -Path $portableDir -Force | Out-Null
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:APPDATA = $dotnetAppData
$env:NUGET_PACKAGES = $nugetPackages
& $dotnet publish $appProject -c Release -r win-x64 --self-contained true `
    -p:RestoreConfigFile=$nugetConfig -p:PublishSingleFile=false -o $portableDir
if ($LASTEXITCODE -ne 0) {
    throw "Self-contained publish failed with exit code $LASTEXITCODE"
}

foreach ($fileName in @('KeyboardDeviceBridge.exe', 'CodexStatusHookClient.exe', 'Start-CodexCli.exe', 'hidapi.dll', 'codex-keyboard.ico')) {
    Copy-Item -LiteralPath (Join-Path $frameworkArtifacts $fileName) -Destination (Join-Path $portableDir $fileName) -Force
}
foreach ($fileName in @(
    'LICENSE', 'THIRD_PARTY_NOTICES.md', 'DOTNET-LIBRARY-LICENSE.txt', 'DOTNET-MIT-LICENSE.txt',
    'DOTNET-THIRD-PARTY-NOTICES.txt', 'WPF-THIRD-PARTY-NOTICES.txt', 'WINDOWS-SDK-LICENSE.rtf')) {
    Copy-Item -LiteralPath (Join-Path $root $fileName) -Destination (Join-Path $portableDir $fileName) -Force
}
$launcherSource = Join-Path $frameworkArtifacts 'Start-CodexCli.exe'
$launcherDestination = Join-Path $root 'Start-CodexCli.exe'
$launcherCopyRequired = -not (Test-Path -LiteralPath $launcherDestination -PathType Leaf)
if (-not $launcherCopyRequired) {
    $launcherCopyRequired = (Get-FileHash -LiteralPath $launcherSource -Algorithm SHA256).Hash -cne
        (Get-FileHash -LiteralPath $launcherDestination -Algorithm SHA256).Hash
}
if ($launcherCopyRequired) {
    Copy-Item -LiteralPath $launcherSource -Destination $launcherDestination -Force
}
$portableScripts = [ordered]@{
    'install-codex-hooks.ps1' = 'Install-CodexHooks.ps1'
    'set-codex-cli-status.ps1' = 'set-codex-cli-status.ps1'
    'run-codex-exec-with-status.ps1' = 'Run-CodexExecWithStatus.ps1'
    'codex-json-status.ps1' = 'codex-json-status.ps1'
    'test-v1-physical-input.ps1' = 'Test-V1PhysicalInput.ps1'
    'monitor-key-events.ps1' = 'monitor-key-events.ps1'
}
foreach ($entry in $portableScripts.GetEnumerator()) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $entry.Key) -Destination (Join-Path $portableDir $entry.Value) -Force
}
$legacyPortableLauncher = Join-Path $portableDir 'Launch-CodexCli.ps1'
if (Test-Path -LiteralPath $legacyPortableLauncher) {
    Remove-Item -LiteralPath $legacyPortableLauncher -Force
}
foreach ($fileName in @(
    'Test-V1TypelessIntegration.ps1', 'Test-V2DisabledInput.ps1',
    'Test-V2AppRouting.ps1', 'test-window-focus-helper.ps1')) {
    $obsoleteDiagnostic = Join-Path $portableDir $fileName
    if (Test-Path -LiteralPath $obsoleteDiagnostic) {
        Remove-Item -LiteralPath $obsoleteDiagnostic -Force
    }
}
Get-ChildItem -LiteralPath $portableDir -Filter '*.pdb' -File -Recurse | Remove-Item -Force

$required = @(
    'CodexKeyboardStudio.exe', 'CodexKeyboardStudio.dll', 'KeyboardDeviceBridge.exe',
    'CodexStatusHookClient.exe', 'Start-CodexCli.exe', 'hidapi.dll', 'coreclr.dll', 'hostfxr.dll',
    'PresentationFramework.dll', 'Install-CodexHooks.ps1', 'set-codex-cli-status.ps1',
    'Run-CodexExecWithStatus.ps1', 'codex-json-status.ps1',
    'Test-V1PhysicalInput.ps1', 'monitor-key-events.ps1',
    'LICENSE', 'THIRD_PARTY_NOTICES.md', 'DOTNET-LIBRARY-LICENSE.txt', 'DOTNET-MIT-LICENSE.txt',
    'DOTNET-THIRD-PARTY-NOTICES.txt', 'WPF-THIRD-PARTY-NOTICES.txt', 'WINDOWS-SDK-LICENSE.rtf'
)
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $portableDir $_)) })
if ($missing.Count -gt 0) {
    throw "Portable package is incomplete: $($missing -join ', ')"
}
if (-not (Test-Path -LiteralPath (Join-Path $root 'Start-CodexCli.exe'))) {
    throw 'Top-level native Codex launcher is missing.'
}

$portableFiles = @(Get-ChildItem -LiteralPath $portableDir -File -Recurse)
$size = ($portableFiles | Measure-Object Length -Sum).Sum
Write-Output "V1_PORTABLE_PASS path=$portableDir files=$($portableFiles.Count) bytes=$size"
