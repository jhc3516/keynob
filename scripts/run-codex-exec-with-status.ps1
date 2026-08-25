[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Prompt,
    [string]$Model,
    [ValidateSet('read-only', 'workspace-write', 'danger-full-access')]
    [string]$Sandbox = 'workspace-write',
    [string]$WorkingDirectory = (Get-Location).Path,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$statusScript = Join-Path $PSScriptRoot 'set-codex-cli-status.ps1'
$jsonStatusScript = Join-Path $PSScriptRoot 'codex-json-status.ps1'
$codex = Get-Command codex.cmd -ErrorAction Stop
$resolvedWorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $resolvedWorkingDirectory -PathType Container)) {
    throw "Codex working directory is not a folder: $resolvedWorkingDirectory"
}
if (-not (Test-Path -LiteralPath $statusScript)) {
    throw "Status helper is missing: $statusScript"
}
if (-not (Test-Path -LiteralPath $jsonStatusScript)) {
    throw "Codex JSON status parser is missing: $jsonStatusScript"
}
. $jsonStatusScript
if ($ValidateOnly) {
    Write-Output "CODEX_EXEC_WRAPPER_READY workingDirectory=$resolvedWorkingDirectory codex=$($codex.Source) parser=True"
    exit 0
}

$statusId = 'exec-' + [Guid]::NewGuid().ToString('N')
& $statusScript -Status running -Message 'Codex CLI running' -SessionId $statusId `
    -InstanceId $statusId -SourceKind json_exec -ProducerProcessId $PID | Out-Null

$args = @('exec', '--json', '-C', $resolvedWorkingDirectory, '--sandbox', $Sandbox)
if ($Model) { $args += @('--model', $Model) }
$args += $Prompt

$sawCompletion = $false
$sawError = $false
$exitCode = 1
try {
    & $codex.Source @args 2>&1 | ForEach-Object {
        $line = [string]$_
        Write-Output $line
        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
            $type = [string]$event.type
            $status = Get-CodexJsonEventStatus -Event $event
            if ($status -eq 'approval') {
                & $statusScript -Status approval -Message $type -SessionId $statusId `
                    -InstanceId $statusId -SourceKind json_exec -ProducerProcessId $PID | Out-Null
            } elseif ($status -eq 'completed') {
                $sawCompletion = $true
            } elseif ($status -eq 'error') {
                $sawError = $true
                & $statusScript -Status error -Message $type -SessionId $statusId `
                    -InstanceId $statusId -SourceKind json_exec -ProducerProcessId $PID | Out-Null
            }
        } catch {
            # Preserve human-readable output without treating it as JSON.
        }
    }
    $exitCode = $LASTEXITCODE
} finally {
    if ($exitCode -eq 0 -and $sawCompletion -and -not $sawError) {
        & $statusScript -Status completed -Message 'Codex CLI completed' -SessionId $statusId `
            -InstanceId $statusId -SourceKind json_exec -ProducerProcessId $PID | Out-Null
    } elseif ($exitCode -ne 0 -or $sawError) {
        & $statusScript -Status error -Message "Codex CLI exit code $exitCode" -SessionId $statusId `
            -InstanceId $statusId -SourceKind json_exec -ProducerProcessId $PID | Out-Null
    } else {
        & $statusScript -Status error -Message 'Codex CLI ended without a completion event' -SessionId $statusId `
            -InstanceId $statusId -SourceKind json_exec -ProducerProcessId $PID | Out-Null
    }
}
exit $exitCode
