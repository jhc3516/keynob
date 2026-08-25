[CmdletBinding()]
param(
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$ClientPath,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ClientPath)) {
    $packagedClient = Join-Path $PSScriptRoot 'CodexStatusHookClient.exe'
    $repositoryPortableClient = Join-Path $projectRoot 'artifacts\portable\CodexStatusHookClient.exe'
    $frameworkClient = Join-Path $projectRoot 'artifacts\app\CodexStatusHookClient.exe'
    $ClientPath = if (Test-Path -LiteralPath $packagedClient) {
        $packagedClient
    } elseif (Test-Path -LiteralPath $repositoryPortableClient) {
        $repositoryPortableClient
    } else {
        $frameworkClient
    }
}
$hooksPath = Join-Path $CodexHome 'hooks.json'
$destination = Join-Path $CodexHome 'CodexStatusHookClient.exe'
$events = @('SessionStart', 'UserPromptSubmit', 'PermissionRequest', 'PreToolUse', 'PostToolUse', 'Stop', 'SessionEnd')

New-Item -ItemType Directory -Path $CodexHome -Force | Out-Null
if (Test-Path -LiteralPath $hooksPath) {
    $config = Get-Content -LiteralPath $hooksPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    $config = [pscustomobject]@{ description = 'Codex user hooks'; hooks = [pscustomobject]@{} }
}
if ($null -eq $config.hooks) {
    $config | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
}

foreach ($eventName in $events) {
    $groups = @($config.hooks.PSObject.Properties[$eventName].Value)
    $preservedGroups = [Collections.Generic.List[object]]::new()
    foreach ($group in $groups) {
        if ($null -eq $group) { continue }
        $preservedHandlers = @($group.hooks | Where-Object {
            $command = [string]$_.command
            $command -notmatch '(?i)CodexStatusHookClient\.exe|codex-status-hook\.ps1'
        })
        if ($preservedHandlers.Count -gt 0) {
            $group.hooks = $preservedHandlers
            $preservedGroups.Add($group)
        }
    }

    if (-not $Uninstall) {
        $preservedGroups.Add([pscustomobject]@{
            hooks = @([pscustomobject]@{
                type = 'command'
                command = $destination
                timeout = 1
            })
        })
    }

    if ($preservedGroups.Count -gt 0) {
        $config.hooks | Add-Member -NotePropertyName $eventName -NotePropertyValue $preservedGroups.ToArray() -Force
    } elseif ($config.hooks.PSObject.Properties[$eventName]) {
        $config.hooks.PSObject.Properties.Remove($eventName)
    }
}

if (-not $Uninstall) {
    if (-not (Test-Path -LiteralPath $ClientPath)) {
        throw "Hook client is missing: $ClientPath"
    }
    Copy-Item -LiteralPath $ClientPath -Destination $destination -Force
}

$temporaryPath = "$hooksPath.tmp"
try {
    $json = $config | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $hooksPath) {
        $replaceBackup = "$hooksPath.replace-backup"
        [IO.File]::Replace($temporaryPath, $hooksPath, $replaceBackup)
        Remove-Item -LiteralPath $replaceBackup -Force
    } else {
        [IO.File]::Move($temporaryPath, $hooksPath)
    }
} finally {
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
}

if ($Uninstall -and (Test-Path -LiteralPath $destination)) {
    Remove-Item -LiteralPath $destination -Force
}

$ourHandlers = @(
    $config.hooks.PSObject.Properties.Value |
        ForEach-Object { @($_) } |
        ForEach-Object { @($_.hooks) } |
        Where-Object { ([string]$_.command) -match '(?i)CodexStatusHookClient\.exe' }
)
Write-Output "CODEX_HOOKS_OK installed=$(-not $Uninstall) handlers=$($ourHandlers.Count) path=$hooksPath"
if (-not $Uninstall) {
    Write-Output 'CODEX_HOOKS_NEXT_ACTION Open a new interactive Codex CLI, enter /hooks, review the seven MacroPad Studio hooks, and trust them.'
}
