[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('running', 'approval', 'completed', 'error')]
    [string]$Status,
    [string]$Message = '',
    [string]$SessionId,
    [string]$InstanceId,
    [ValidateSet('unscoped', 'json_exec', 'manual_test')]
    [string]$SourceKind = 'unscoped',
    [int]$ProducerProcessId,
    [switch]$InstanceEnd,
    [switch]$Force
)

$ErrorActionPreference = 'SilentlyContinue'
$safeIdPattern = '^[A-Za-z0-9_.-]{1,128}$'
if ($InstanceEnd) {
    if ([string]::IsNullOrWhiteSpace($InstanceId) -or $InstanceId -cnotmatch $safeIdPattern) {
        throw 'InstanceEnd requires a safe InstanceId.'
    }
    $eventName = 'InstanceEnd'
    $payload = [ordered]@{
        hook_event_name = $eventName
        session_id = $null
        turn_id = $null
        instance_id = $InstanceId
        success = $Status -ne 'error'
    } | ConvertTo-Json -Compress
} else {
    if ([string]::IsNullOrWhiteSpace($SessionId) -or $SessionId -cnotmatch $safeIdPattern) {
        throw 'A safe SessionId is required for a synthetic status event.'
    }
    if (-not [string]::IsNullOrWhiteSpace($InstanceId) -and $InstanceId -cnotmatch $safeIdPattern) {
        throw 'InstanceId contains unsupported characters.'
    }
    if ($SourceKind -in @('json_exec', 'manual_test') -and
        ([string]::IsNullOrWhiteSpace($InstanceId) -or $ProducerProcessId -le 0)) {
        throw 'Managed status sources require an InstanceId and ProducerProcessId.'
    }
    $eventName = switch ($Status) {
        'running' { 'UserPromptSubmit' }
        'approval' { 'PermissionRequest' }
        'completed' { 'Stop' }
        'error' { 'Stop' }
    }
    $payload = [ordered]@{
        hook_event_name = $eventName
        session_id = $SessionId
        turn_id = $SessionId
        instance_id = if ([string]::IsNullOrWhiteSpace($InstanceId)) { $null } else { $InstanceId }
        source_kind = $SourceKind
        producer_process_id = if ($ProducerProcessId -gt 0) { $ProducerProcessId } else { $null }
        success = $Status -ne 'error'
    } | ConvertTo-Json -Compress
}

$hook = Join-Path $PSScriptRoot 'codex-status-hook.ps1'
& $hook -RawPayload $payload
Write-Output ([ordered]@{
    status = $Status
    delivered = $true
    sessionId = if ($InstanceEnd) { $null } else { $SessionId }
    instanceId = if ([string]::IsNullOrWhiteSpace($InstanceId)) { $null } else { $InstanceId }
    sourceKind = $SourceKind
    producerProcessId = if ($ProducerProcessId -gt 0) { $ProducerProcessId } else { $null }
    instanceEnd = [bool]$InstanceEnd
} | ConvertTo-Json -Compress)
exit 0
