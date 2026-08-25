function Get-CodexJsonEventStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Event
    )

    $type = [string]$Event.type
    if ($type -match 'approval|permission') {
        return 'approval'
    }
    if ($type -in @('error', 'turn.failed')) {
        return 'error'
    }
    if ($type -eq 'item.completed' -and [string]$Event.item.type -eq 'error') {
        return 'error'
    }
    if ($type -eq 'item.completed' -and
        [string]$Event.item.type -eq 'command_execution' -and
        $null -ne $Event.item.exit_code -and
        [int]$Event.item.exit_code -ne 0) {
        return 'error'
    }
    if ($type -eq 'turn.completed') {
        return 'completed'
    }
    return $null
}
