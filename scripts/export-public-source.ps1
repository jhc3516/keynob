[CmdletBinding()]
param(
    [string]$OutputPath = 'artifacts\public-source'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$output = if ([IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $root $OutputPath }
$output = [IO.Path]::GetFullPath($output)
$allowedRoots = @(
    [IO.Path]::GetFullPath((Join-Path $root 'artifacts')),
    [IO.Path]::GetFullPath((Join-Path $root '.runtime'))
)
if (-not ($allowedRoots | Where-Object { $output.StartsWith($_ + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) })) {
    throw 'Public source output must be inside this repository artifacts or .runtime directory.'
}
if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force }
New-Item -ItemType Directory -Path $output -Force | Out-Null

function Copy-PublicFile([string]$sourceRelative, [string]$destinationRelative = $sourceRelative) {
    $source = Join-Path $root $sourceRelative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing public source input: $sourceRelative" }
    $destination = Join-Path $output $destinationRelative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

foreach ($file in @(
    '.gitattributes', '.gitignore', 'Keynob.sln', 'NuGet.Config', 'NuGet.Portable.Config',
    'LICENSE', 'THIRD_PARTY_NOTICES.md', 'DOTNET-LIBRARY-LICENSE.txt', 'DOTNET-MIT-LICENSE.txt',
    'DOTNET-THIRD-PARTY-NOTICES.txt', 'WPF-THIRD-PARTY-NOTICES.txt', 'WINDOWS-SDK-LICENSE.rtf')) {
    Copy-PublicFile $file
}
Copy-PublicFile 'README.md'
Copy-PublicFile 'docs\device-protocol.md'
Copy-PublicFile 'docs\release-notes-v1.0.0-beta.1.md' 'docs\release-notes-v1.0.0-beta.1.md'
foreach ($file in @(
    'assets\keynob.ico', 'assets\keynob.jpg',
    'config\codex-keymap.json')) {
    Copy-PublicFile $file
}

foreach ($directory in @('src', 'tests', 'macos', 'docs', '.github')) {
    Get-ChildItem -LiteralPath (Join-Path $root $directory) -File -Recurse |
        Where-Object { $_.FullName -notmatch '[\\/](bin|obj|\.build)[\\/]' } |
        ForEach-Object {
            $relative = $_.FullName.Substring($root.Length + 1)
            Copy-PublicFile $relative
        }
}

$publicScripts = @(
    'prepare-hidapi.ps1', 'build-v1-app.ps1', 'build-v1-portable.ps1',
    'build-macos-app.sh', 'test-macos.sh', 'test-macos-hook.sh',
    'export-public-source.ps1', 'build-public-release.ps1', 'check-readiness.ps1',
    'start-background.ps1', 'stop-background.ps1', 'toggle-background.ps1',
    'install-codex-hooks.ps1', 'codex-status-hook.ps1', 'set-codex-cli-status.ps1',
    'run-codex-exec-with-status.ps1', 'codex-json-status.ps1', 'monitor-key-events.ps1',
    'test-v1-settings.ps1', 'test-v1-foundation.ps1', 'test-v1-runtime.ps1', 'test-v3-layer-read.ps1',
    'test-v1-physical-input.ps1', 'test-v1-typeless-integration.ps1',
    'test-v1-nontarget-integration.ps1', 'test-v1-codex-cli-integration.ps1',
    'test-window-focus-helper.ps1',
    'test-v2-disabled-input.ps1', 'test-v2-app-routing.ps1',
    'test-codex-hook-installer.ps1', 'test-codex-json-status.ps1', 'test-codex-exec-wrapper.ps1',
    'test-codex-launcher-working-directory.ps1', 'test-native-launcher-resources.ps1',
    'test-codex-hook-instance-routing.ps1', 'test-codex-cancellation-routing.ps1',
    'test-codex-launcher-lifetime-fallback.ps1', 'test-codex-status-lifetime.ps1'
)
foreach ($script in $publicScripts) { Copy-PublicFile ("scripts\" + $script) }

$publicFiles = @(Get-ChildItem -LiteralPath $output -File -Recurse)
$forbiddenPaths = @('.codex-work', 'AGENTS.md', 'development-history', 'rgb-capture', 'vendor')
foreach ($fragment in $forbiddenPaths) {
    if ($publicFiles.FullName -match [Regex]::Escape($fragment)) { throw "Forbidden public path found: $fragment" }
}
$textFiles = $publicFiles | Where-Object Extension -in @('.cs', '.cpp', '.h', '.xaml', '.ps1', '.cmd', '.json', '.md', '.sln', '.config', '.csproj')
$sensitivePatterns = @($root, [Environment]::GetFolderPath('UserProfile')) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_; $_.Replace('\', '\\') } |
    Select-Object -Unique
foreach ($pattern in $sensitivePatterns) {
    foreach ($file in $textFiles) {
        if (Select-String -LiteralPath $file.FullName -Pattern $pattern -SimpleMatch -Quiet) {
            throw "Sensitive or internal content found: $pattern"
        }
    }
}
foreach ($file in $textFiles) {
    if (Select-String -LiteralPath $file.FullName -Pattern '(?i)(?<![0-9a-fx])(?=[0-9a-f]{16}(?![0-9a-f]))(?=[0-9a-f]*[a-f])(?=[0-9a-f]*\d)[0-9a-f]{16}' -Quiet) {
        throw "Possible device serial found: $($file.FullName)"
    }
}
foreach ($required in @(
    '.gitattributes', 'README.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'DOTNET-LIBRARY-LICENSE.txt',
    'DOTNET-MIT-LICENSE.txt', 'DOTNET-THIRD-PARTY-NOTICES.txt', 'WPF-THIRD-PARTY-NOTICES.txt',
    'WINDOWS-SDK-LICENSE.rtf', 'assets\keynob.jpg', 'scripts\prepare-hidapi.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $output $required))) { throw "Public source is incomplete: $required" }
}

$manifestLines = $publicFiles | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($output.Length + 1).Replace('\', '/')
    "{0}  {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $relative
}
$manifestBytes = [Text.Encoding]::UTF8.GetBytes(($manifestLines -join "`n") + "`n")
$sha256 = [Security.Cryptography.SHA256]::Create()
try { $sourceHash = ([BitConverter]::ToString($sha256.ComputeHash($manifestBytes))).Replace('-', '').ToLowerInvariant() }
finally { $sha256.Dispose() }
Write-Output "PUBLIC_SOURCE_PASS path=$output files=$($publicFiles.Count) sha256=$sourceHash"
