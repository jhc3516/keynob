[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $root '.runtime\wrapper-test'
$wrapper = Join-Path $testRoot 'run-codex-exec-with-status.ps1'
$statusHelper = Join-Path $testRoot 'set-codex-cli-status.ps1'
$fakeCodex = Join-Path $testRoot 'codex.cmd'
$statusLog = Join-Path $testRoot 'statuses.log'

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'run-codex-exec-with-status.ps1') -Destination $wrapper -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'codex-json-status.ps1') -Destination (Join-Path $testRoot 'codex-json-status.ps1') -Force
[IO.File]::WriteAllText($statusHelper, @'
param(
    [string]$Status,
    [string]$Message,
    [string]$SessionId,
    [string]$InstanceId,
    [string]$SourceKind,
    [int]$ProducerProcessId
)
Add-Content -LiteralPath $env:CODEX_WRAPPER_STATUS_LOG -Value "$Status|$SessionId|$InstanceId|$SourceKind|$ProducerProcessId" -Encoding UTF8
'@, [Text.UTF8Encoding]::new($false))

$originalPath = $env:PATH
$env:PATH = "$testRoot;$originalPath"
$env:CODEX_WRAPPER_STATUS_LOG = $statusLog
try {
    $caseSessionIds = New-Object System.Collections.Generic.List[string]
    $cases = @(
        @{
            Name = 'command-failure'
            Body = @'
@echo off
echo {"type":"turn.started"}
echo {"type":"item.completed","item":{"type":"command_execution","exit_code":7}}
echo {"type":"turn.completed"}
exit /b 0
'@
            Expected = 'error'
        },
        @{
            Name = 'transport-error'
            Body = @'
@echo off
echo {"type":"error","message":"offline"}
echo {"type":"turn.failed","error":{"message":"offline"}}
exit /b 1
'@
            Expected = 'error'
        },
        @{
            Name = 'success'
            Body = @'
@echo off
echo {"type":"turn.started"}
echo {"type":"item.completed","item":{"type":"agent_message"}}
echo {"type":"turn.completed"}
exit /b 0
'@
            Expected = 'completed'
        }
    )

    foreach ($case in $cases) {
        [IO.File]::WriteAllText($fakeCodex, $case.Body, [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText($statusLog, '', [Text.UTF8Encoding]::new($false))
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'test' -WorkingDirectory $root | Out-Null
        $records = @(Get-Content -LiteralPath $statusLog -Encoding UTF8 | Where-Object { $_ })
        $parsedRecords = @($records | ForEach-Object { ,($_ -split '\|', 5) })
        $statuses = @($parsedRecords | ForEach-Object { $_[0] })
        $sessionIds = @($parsedRecords | ForEach-Object { $_[1] } | Select-Object -Unique)
        if ($statuses.Count -eq 0 -or $statuses[-1] -ne $case.Expected) {
            throw "Wrapper case $($case.Name) ended with '$($statuses -join ',')'."
        }
        if ($case.Expected -eq 'error' -and $statuses[-1] -eq 'completed') {
            throw "Wrapper case $($case.Name) incorrectly ended as completed."
        }
        if ($sessionIds.Count -ne 1 -or $sessionIds[0] -cnotmatch '^exec-[0-9a-f]{32}$') {
            throw "Wrapper case $($case.Name) did not use one safe run ID: $($sessionIds -join ',')"
        }
        if (@($parsedRecords | Where-Object {
            $_[2] -cne $sessionIds[0] -or $_[3] -cne 'json_exec' -or [int]$_[4] -le 0
        }).Count -ne 0) {
            throw "Wrapper case $($case.Name) did not preserve managed source identity."
        }
        $caseSessionIds.Add($sessionIds[0])
    }
    if (($caseSessionIds | Select-Object -Unique).Count -ne $cases.Count) {
        throw "Exec wrapper reused a run ID: $($caseSessionIds -join ',')"
    }
} finally {
    $env:PATH = $originalPath
    Remove-Item Env:CODEX_WRAPPER_STATUS_LOG -ErrorAction SilentlyContinue
}

Write-Output 'CODEX_EXEC_WRAPPER_TEST_PASS commandFailure=True transportError=True success=True uniqueRunIds=True sourceKind=json_exec producerPid=True'
