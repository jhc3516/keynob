[CmdletBinding()]
param([string]$RawPayload)

$ErrorActionPreference = 'SilentlyContinue'
$raw = if ($PSBoundParameters.ContainsKey('RawPayload')) {
    $RawPayload
} else {
    [Console]::In.ReadToEnd()
}

try {
    $payload = $raw | ConvertFrom-Json
    $eventName = [string]$payload.hook_event_name
    $sessionId = if ($null -ne $payload.session_id) { [string]$payload.session_id } else { $null }
    $turnId = if ($null -ne $payload.turn_id) { [string]$payload.turn_id } else { $null }
    $instanceId = if ($null -ne $payload.instance_id) {
        [string]$payload.instance_id
    } else { $null }
    $sourceKind = if ($null -ne $payload.source_kind) { [string]$payload.source_kind } else { 'unscoped' }
    $producerProcessId = if ($null -ne $payload.producer_process_id) {
        [int]$payload.producer_process_id
    } else { $null }
    $supported = @(
        'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse',
        'PermissionRequest', 'Stop', 'SessionEnd', 'InstanceEnd'
    )
    $safeIdPattern = '^[A-Za-z0-9_.-]{1,128}$'
    $validInstance = -not [string]::IsNullOrWhiteSpace($instanceId) -and $instanceId -cmatch $safeIdPattern
    $validSession = -not [string]::IsNullOrWhiteSpace($sessionId) -and $sessionId -cmatch $safeIdPattern
    $managedSource = $sourceKind -in @('json_exec', 'manual_test')
    if ($eventName -notin $supported -or
        $eventName -eq 'InstanceEnd' -or
        ($eventName -ne 'InstanceEnd' -and (-not $validSession -or
            ($null -ne $turnId -and $turnId -cnotmatch $safeIdPattern) -or
            ($managedSource -and (-not $validInstance -or $producerProcessId -le 0))))) {
        return
    }
    if (-not $managedSource) {
        $sourceKind = 'unscoped'
        $instanceId = $null
        $producerProcessId = $null
        $validInstance = $false
    }

    # Only a boolean error signal is retained. Prompt, tool input, output, paths,
    # and error text are never copied into the IPC message or diagnostics.
    $isError = $null -ne $payload.error -or
        $payload.failed -eq $true -or
        $payload.success -eq $false
    $message = [ordered]@{
        eventName = $eventName
        sessionId = $sessionId
        turnId = $turnId
        instanceId = if ($validInstance) { $instanceId } else { $null }
        launcherProcessId = $null
        sourceKind = $sourceKind
        producerProcessId = $producerProcessId
        isError = $isError
    } | ConvertTo-Json -Compress

    $pipeName = 'CodexKeyboardStudio.Status.v1'
    $testPipeName = [string]$env:CODEX_KEYBOARD_TEST_STATUS_PIPE_NAME
    if ($testPipeName.Length -le 128 -and
        $testPipeName -cmatch '^CodexKeyboardStudio\.Status\.v1\.Test\.[A-Za-z0-9_.-]+$') {
        $pipeName = $testPipeName
    }

    $pipe = [IO.Pipes.NamedPipeClientStream]::new(
        '.',
        $pipeName,
        [IO.Pipes.PipeDirection]::Out,
        [IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $pipe.Connect(150)
        $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 1024, $true)
        try {
            $writer.WriteLine($message)
            $writer.Flush()
        } finally {
            $writer.Dispose()
        }
    } finally {
        $pipe.Dispose()
    }
} catch {
    # A missing app, malformed event, or pipe failure must never block Codex.
    if ($env:CODEX_KEYBOARD_TEST_HOOK_DIAGNOSTICS -eq '1') {
        [Console]::Error.WriteLine("CODEX_STATUS_HOOK_FAIL type=$($_.Exception.GetType().Name)")
    }
}
return
