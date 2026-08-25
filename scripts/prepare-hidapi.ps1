[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$version = '0.15.0'
$downloadUrl = 'https://github.com/libusb/hidapi/releases/download/hidapi-0.15.0/hidapi-win.zip'
$archiveHash = 'D18C43EC9506A2F6D7FAA9C7E0A342C4B64FBAE521B71B5D4AC0777FD24DDA93'
$dllHash = 'D4C8E5F799FC5F57038D492F13A687471D5D353447EAD7E6CAE70E957FB55AE1'
$cache = Join-Path $root ".runtime\dependencies\hidapi\$version"
$archive = Join-Path $cache 'hidapi-win.zip'
$dll = Join-Path $cache 'x86\hidapi.dll'

New-Item -ItemType Directory -Path (Split-Path -Parent $dll) -Force | Out-Null
if (-not (Test-Path -LiteralPath $archive) -or
    (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $archiveHash) {
    $partial = $archive + '.partial'
    Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $partial
    if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -cne $archiveHash) {
        Remove-Item -LiteralPath $partial -Force
        throw 'Downloaded HIDAPI archive checksum mismatch.'
    }
    Move-Item -LiteralPath $partial -Destination $archive -Force
}

if (-not (Test-Path -LiteralPath $dll) -or
    (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -cne $dllHash) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $temporaryDll = $dll + '.partial'
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $entry = $zip.Entries | Where-Object FullName -eq 'x86/hidapi.dll' | Select-Object -First 1
        if ($null -eq $entry) { throw 'The HIDAPI archive does not contain x86/hidapi.dll.' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $temporaryDll, $true)
    }
    finally {
        $zip.Dispose()
    }
    if ((Get-FileHash -LiteralPath $temporaryDll -Algorithm SHA256).Hash -cne $dllHash) {
        Remove-Item -LiteralPath $temporaryDll -Force
        throw 'Extracted HIDAPI DLL checksum mismatch.'
    }
    Move-Item -LiteralPath $temporaryDll -Destination $dll -Force
}

Write-Output "HIDAPI_READY version=$version architecture=x86 sha256=$dllHash path=$dll"
