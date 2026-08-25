[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$startScript = Join-Path $PSScriptRoot 'start-background.ps1'
$stopScript = Join-Path $PSScriptRoot 'stop-background.ps1'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'test-window-focus-helper.ps1')
$physicalTest = Join-Path $root 'artifacts\portable\Test-V1PhysicalInput.ps1'
$form = $null
$originalNoHardwareWrites = $env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES

if (@(Get-Process CodexKeyboardStudio -ErrorAction SilentlyContinue).Count -ne 0) {
    throw 'Stop Codex Keyboard Studio before this no-write integration test.'
}
$env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES = '1'

try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startScript | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Background app failed to start.' }

    Add-Type -AssemblyName System.Windows.Forms
    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'V1 non-target input probe'
    $form.Width = 480
    $form.Height = 180
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()

    $testInfo = [Diagnostics.ProcessStartInfo]::new()
    $testInfo.FileName = 'powershell.exe'
    $testInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$physicalTest`" -InputId key01 -ExpectedOutcome blocked -TimeoutSeconds 10"
    $testInfo.UseShellExecute = $false
    $testInfo.RedirectStandardOutput = $true
    $testInfo.RedirectStandardError = $true
    $testInfo.CreateNoWindow = $true
    $test = [Diagnostics.Process]::Start($testInfo)

    Start-Sleep -Milliseconds 700
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class V1ForegroundProbe {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr window);
}
'@
    Set-CodexKeyboardTestForeground -Handle $form.Handle -Form $form
    Start-Sleep -Milliseconds 300
    [System.Windows.Forms.SendKeys]::SendWait('^+%{F1}')

    if (-not $test.WaitForExit(12000)) {
        $test.Kill()
        throw 'Physical input observer timed out.'
    }
    $stdout = $test.StandardOutput.ReadToEnd().Trim()
    $stderr = $test.StandardError.ReadToEnd().Trim()
    if ($test.ExitCode -ne 0) {
        throw "Physical input observer failed: $stderr"
    }
    Write-Output $stdout
    Write-Output 'V1_NONTARGET_INTEGRATION_PASS app=powershell_test_window input=key01 blocked=True'
} finally {
    if ($form) {
        $form.Close()
        $form.Dispose()
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stopScript | Out-Host
    if ($null -eq $originalNoHardwareWrites) {
        Remove-Item Env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES = $originalNoHardwareWrites
    }
}
