[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'install-codex-hooks.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "CodexHookInstaller-$([Guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $fixture = [ordered]@{
        description = 'preserve me'
        hooks = [ordered]@{
            UserPromptSubmit = @(@{ hooks = @(@{ type = 'command'; command = 'custom-user-hook.exe'; timeout = 9 }) })
            PreCompact = @(@{ hooks = @(@{ type = 'command'; command = 'custom-compact-hook.exe' }) })
        }
        customTopLevel = 'keep'
    }
    $fixture | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $testRoot 'hooks.json') -Encoding UTF8

    & $installer -CodexHome $testRoot | Out-Null
    & $installer -CodexHome $testRoot | Out-Null
    $installed = Get-Content -LiteralPath (Join-Path $testRoot 'hooks.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $installedBytes = [IO.File]::ReadAllBytes((Join-Path $testRoot 'hooks.json'))
    if ($installedBytes.Length -ge 3 -and $installedBytes[0] -eq 0xEF -and
        $installedBytes[1] -eq 0xBB -and $installedBytes[2] -eq 0xBF) {
        throw 'hooks_json_contains_utf8_bom'
    }
    $commands = @($installed.hooks.PSObject.Properties.Value | ForEach-Object { @($_) } | ForEach-Object { @($_.hooks) } | ForEach-Object { $_.command })
    if (@($commands | Where-Object { $_ -match 'CodexStatusHookClient\.exe' }).Count -ne 7) { throw 'hook_count_or_dedup_failed' }
    if ('custom-user-hook.exe' -notin $commands -or 'custom-compact-hook.exe' -notin $commands) { throw 'custom_hook_not_preserved' }
    if ($installed.customTopLevel -ne 'keep' -or $installed.description -ne 'preserve me') { throw 'custom_metadata_not_preserved' }
    if (-not (Test-Path -LiteralPath (Join-Path $testRoot 'CodexStatusHookClient.exe'))) { throw 'client_not_installed' }

    & $installer -CodexHome $testRoot -Uninstall | Out-Null
    $uninstalled = Get-Content -LiteralPath (Join-Path $testRoot 'hooks.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $remainingCommands = @($uninstalled.hooks.PSObject.Properties.Value | ForEach-Object { @($_) } | ForEach-Object { @($_.hooks) } | ForEach-Object { $_.command })
    if (@($remainingCommands | Where-Object { $_ -match 'CodexStatusHookClient\.exe' }).Count -ne 0) { throw 'hook_uninstall_failed' }
    if ('custom-user-hook.exe' -notin $remainingCommands -or 'custom-compact-hook.exe' -notin $remainingCommands) { throw 'custom_hook_removed_on_uninstall' }
    if (Test-Path -LiteralPath (Join-Path $testRoot 'CodexStatusHookClient.exe')) { throw 'client_not_removed' }

    Write-Output 'CODEX_HOOK_INSTALLER_TEST_PASS handlers=7 idempotent=True utf8Bom=False customHooksPreserved=True uninstallScoped=True defaultClient=True'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
