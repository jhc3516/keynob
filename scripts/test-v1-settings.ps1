[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dotnet = 'C:\Program Files\dotnet\dotnet.exe'
$project = Join-Path $root 'tests\Keynob.SettingsTests\Keynob.SettingsTests.csproj'
$nugetConfig = Join-Path $root 'NuGet.Config'
$dotnetAppData = Join-Path $root '.runtime\dotnet-appdata'
$nugetPackages = Join-Path $root '.runtime\nuget-packages'

$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:APPDATA = $dotnetAppData
$env:NUGET_PACKAGES = $nugetPackages

& $dotnet run --project $project -c Release -p:RestoreConfigFile=$nugetConfig
if ($LASTEXITCODE -ne 0) {
    throw "Settings tests failed with exit code $LASTEXITCODE"
}
