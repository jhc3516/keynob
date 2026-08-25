[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'codex-json-status.ps1')

function Assert-Status {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Json,
        [AllowNull()]
        [object]$Expected
    )

    $event = $Json | ConvertFrom-Json
    $actual = Get-CodexJsonEventStatus -Event $event
    if ($actual -ne $Expected) {
        throw "Unexpected status. expected=$Expected actual=$actual json=$Json"
    }
}

Assert-Status '{"type":"item.completed","item":{"type":"command_execution","exit_code":7,"status":"failed"}}' 'error'
Assert-Status '{"type":"item.completed","item":{"type":"command_execution","exit_code":0,"status":"completed"}}' $null
Assert-Status '{"type":"item.started","item":{"type":"command_execution","exit_code":null,"status":"in_progress"}}' $null
Assert-Status '{"type":"item.completed","item":{"type":"error","message":"failure"}}' 'error'
Assert-Status '{"type":"error","message":"transport failed"}' 'error'
Assert-Status '{"type":"turn.failed","error":{"message":"turn failed"}}' 'error'
Assert-Status '{"type":"turn.completed","usage":{}}' 'completed'
Assert-Status '{"type":"permission.requested"}' 'approval'
Assert-Status '{"type":"turn.started"}' $null

Write-Output 'CODEX_JSON_STATUS_TEST_PASS commandExit=True topLevelError=True turnFailure=True completion=True approval=True'
