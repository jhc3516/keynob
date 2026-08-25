[CmdletBinding()]
param(
    [string]$Version = 'v1.0.0-beta.1',
    [string]$PortablePath = 'artifacts\portable',
    [string]$SourcePath = 'artifacts\public-source',
    [string]$OutputPath = 'artifacts\release'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Resolve-RepositoryPath([string]$path) {
    if ([IO.Path]::IsPathRooted($path)) { return [IO.Path]::GetFullPath($path) }
    return [IO.Path]::GetFullPath((Join-Path $root $path))
}
$portable = Resolve-RepositoryPath $PortablePath
$source = Resolve-RepositoryPath $SourcePath
$output = Resolve-RepositoryPath $OutputPath
$allowedRoots = @(
    [IO.Path]::GetFullPath((Join-Path $root 'artifacts')),
    [IO.Path]::GetFullPath((Join-Path $root '.runtime'))
)
if (-not ($allowedRoots | Where-Object { $output.StartsWith($_ + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) })) {
    throw 'Release output must be inside this repository artifacts or .runtime directory.'
}
foreach ($required in @(
    'CodexKeyboardStudio.exe', 'KeyboardDeviceBridge.exe', 'hidapi.dll', 'LICENSE', 'THIRD_PARTY_NOTICES.md',
    'DOTNET-LIBRARY-LICENSE.txt', 'DOTNET-MIT-LICENSE.txt', 'DOTNET-THIRD-PARTY-NOTICES.txt',
    'WPF-THIRD-PARTY-NOTICES.txt', 'WINDOWS-SDK-LICENSE.rtf')) {
    if (-not (Test-Path -LiteralPath (Join-Path $portable $required) -PathType Leaf)) { throw "Portable input is incomplete: $required" }
}
if (-not (Test-Path -LiteralPath (Join-Path $source 'README.md') -PathType Leaf)) { throw 'Public source input is incomplete.' }
if (Get-ChildItem -LiteralPath $portable -Filter '*.pdb' -File -Recurse | Select-Object -First 1) {
    throw 'Portable input contains debug symbols.'
}

if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force }
New-Item -ItemType Directory -Path $output -Force | Out-Null
$packageName = "MacroPadStudio-$Version-win-x64"
$zipPath = Join-Path $output ($packageName + '.zip')
Add-Type -AssemblyName System.IO.Compression
$stream = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
$archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in Get-ChildItem -LiteralPath $portable -File -Recurse | Sort-Object FullName) {
        $relative = $file.FullName.Substring($portable.Length + 1).Replace('\', '/')
        $entry = $archive.CreateEntry("$packageName/$relative", [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]::new(2026, 8, 17, 0, 0, 0, [TimeSpan]::Zero)
        $input = $file.OpenRead()
        $destination = $entry.Open()
        try { $input.CopyTo($destination) }
        finally { $destination.Dispose(); $input.Dispose() }
    }
}
finally {
    $archive.Dispose()
    $stream.Dispose()
}

$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($zipPath + '.sha256', "$zipHash  $([IO.Path]::GetFileName($zipPath))`n", $utf8)

$sourceFiles = @(Get-ChildItem -LiteralPath $source -File -Recurse | Where-Object {
    $relative = $_.FullName.Substring($source.Length + 1)
    $relative -notmatch '(^|[\\/])(artifacts|build|bin|obj|\.runtime)[\\/]' -and
    $relative -ne 'Start-CodexCli.exe'
})
$sourceLines = $sourceFiles | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($source.Length + 1).Replace('\', '/')
    "{0}  {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $relative
}
$sourceBytes = [Text.Encoding]::UTF8.GetBytes(($sourceLines -join "`n") + "`n")
$sha256 = [Security.Cryptography.SHA256]::Create()
try { $sourceHash = ([BitConverter]::ToString($sha256.ComputeHash($sourceBytes))).Replace('-', '').ToLowerInvariant() }
finally { $sha256.Dispose() }
[IO.File]::WriteAllText((Join-Path $output "MacroPadStudio-$Version-source.sha256"), "$sourceHash  public-source`n", $utf8)
Copy-Item -LiteralPath (Join-Path $source 'docs\release-notes-v1.0.0-beta.1.md') -Destination (Join-Path $output 'RELEASE_NOTES.md') -Force

Write-Output "PUBLIC_RELEASE_PASS zip=$zipPath sha256=$zipHash sourceSha256=$sourceHash files=$(@(Get-ChildItem -LiteralPath $portable -File -Recurse).Count)"
