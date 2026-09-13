[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dotnet = 'C:\Program Files\dotnet\dotnet.exe'
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$appProject = Join-Path $root 'src\Keynob\Keynob.csproj'
$nugetConfig = Join-Path $root 'NuGet.Config'
$bridgeSource = Join-Path $root 'src\KeyboardDeviceBridge\KeyboardDeviceBridge.cpp'
$hookClientSource = Join-Path $root 'src\CodexStatusHookClient\CodexStatusHookClient.cpp'
$launcherSource = Join-Path $root 'src\CodexCliLauncher\CodexCliLauncher.cpp'
$artifactDir = Join-Path $root 'artifacts\app'
$nativeBuildDir = Join-Path $root 'build\v1-native'
$hidapiPrepare = Join-Path $PSScriptRoot 'prepare-hidapi.ps1'
$hidapiDll = Join-Path $root '.runtime\dependencies\hidapi\0.15.0\x86\hidapi.dll'
$dotnetAppData = Join-Path $root '.runtime\dotnet-appdata'
$nugetPackages = Join-Path $root '.runtime\nuget-packages'

foreach ($required in @($dotnet, $vswhere, $appProject, $nugetConfig, $bridgeSource, $hookClientSource, $launcherSource, $hidapiPrepare)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required build input is missing: $required"
    }
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hidapiPrepare
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $hidapiDll)) {
    throw 'Official HIDAPI dependency preparation failed.'
}

New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
New-Item -ItemType Directory -Path $nativeBuildDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $dotnetAppData 'NuGet') -Force | Out-Null
New-Item -ItemType Directory -Path $nugetPackages -Force | Out-Null

$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:APPDATA = $dotnetAppData
$env:NUGET_PACKAGES = $nugetPackages
& $dotnet publish $appProject -c Release -r win-x64 --self-contained false -p:RestoreConfigFile=$nugetConfig -o $artifactDir
if ($LASTEXITCODE -ne 0) {
    throw "WPF publish failed with exit code $LASTEXITCODE"
}

$installationPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $installationPath) {
    throw 'Visual C++ x86 build tools were not found.'
}
$vcvars = Join-Path $installationPath 'VC\Auxiliary\Build\vcvarsall.bat'
$bridgeOutput = Join-Path $artifactDir 'KeyboardDeviceBridge.exe'
$bridgeObject = Join-Path $nativeBuildDir 'KeyboardDeviceBridge.obj'
$compileCommand = "call `"$vcvars`" x86 >nul && cl.exe /nologo /O2 /Brepro /EHsc /std:c++17 /utf-8 /Fo:`"$bridgeObject`" /Fe:`"$bridgeOutput`" `"$bridgeSource`" /link /Brepro"
& cmd.exe /d /c $compileCommand
if ($LASTEXITCODE -ne 0) {
    throw "Device bridge build failed with exit code $LASTEXITCODE"
}

$hookClientOutput = Join-Path $artifactDir 'CodexStatusHookClient.exe'
$hookClientObject = Join-Path $nativeBuildDir 'CodexStatusHookClient.obj'
$hookCompileCommand = "call `"$vcvars`" x64 >nul && cl.exe /nologo /O2 /Brepro /EHsc /std:c++17 /utf-8 /W4 /WX /Fo:`"$hookClientObject`" /Fe:`"$hookClientOutput`" `"$hookClientSource`" /link /Brepro"
& cmd.exe /d /c $hookCompileCommand
if ($LASTEXITCODE -ne 0) {
    throw "Codex status hook client build failed with exit code $LASTEXITCODE"
}

$launcherOutput = Join-Path $artifactDir 'Start-CodexCli.exe'
$launcherObject = Join-Path $nativeBuildDir 'CodexCliLauncher.obj'
$launcherCompileCommand = "call `"$vcvars`" x64 >nul && cl.exe /nologo /O2 /Brepro /MT /W4 /WX /permissive- /EHsc /std:c++20 /utf-8 /DUNICODE /D_UNICODE /Fo:`"$launcherObject`" /Fe:`"$launcherOutput`" `"$launcherSource`" /link /Brepro /DYNAMICBASE /NXCOMPAT /HIGHENTROPYVA /CETCOMPAT ole32.lib shell32.lib uuid.lib"
& cmd.exe /d /c $launcherCompileCommand
if ($LASTEXITCODE -ne 0) {
    throw "Native Codex launcher build failed with exit code $LASTEXITCODE"
}

Copy-Item -LiteralPath $hidapiDll -Destination (Join-Path $artifactDir 'hidapi.dll') -Force
Copy-Item -LiteralPath (Join-Path $root 'assets\keynob.ico') -Destination (Join-Path $artifactDir 'keynob.ico') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'install-codex-hooks.ps1') -Destination (Join-Path $artifactDir 'Install-CodexHooks.ps1') -Force

Write-Output "V1_BUILD_PASS app=$artifactDir"
