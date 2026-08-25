[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$startScript = Join-Path $PSScriptRoot 'start-background.ps1'
$stopScript = Join-Path $PSScriptRoot 'stop-background.ps1'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'test-window-focus-helper.ps1')
$physicalTest = Join-Path $root 'artifacts\portable\Test-V1PhysicalInput.ps1'
$settingsPath = Join-Path $env:LOCALAPPDATA 'CodexKeyboardStudio\settings.json'
$form = $null
$textBox = $null
$originalNoHardwareWrites = $env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES

if (@(Get-Process CodexKeyboardStudio -ErrorAction SilentlyContinue).Count -ne 0) {
    throw 'Stop Codex Keyboard Studio before this no-write integration test.'
}
$env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES = '1'
$settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$key05 = $settings.inputs.key05
if ($key05.scope -cne 'codex_cli' -or $key05.actionKind -cne 'text' -or
    [string]::IsNullOrEmpty([string]$key05.text)) {
    throw 'KEY 5 must currently be a Codex CLI text binding for this integration test.'
}
$expectedPrompt = [string]$key05.text

try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startScript | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Background app failed to start.' }

    Add-Type -AssemblyName System.Windows.Forms
    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'Codex CLI - MacroPad Studio - V1 integration probe'
    $form.Width = 480
    $form.Height = 180
    $textBox = [System.Windows.Forms.TextBox]::new()
    $textBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $form.Controls.Add($textBox)
    $form.Show()
    $textBox.Focus() | Out-Null
    [System.Windows.Forms.Application]::DoEvents()

    $testInfo = [Diagnostics.ProcessStartInfo]::new()
    $testInfo.FileName = 'powershell.exe'
    $testInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$physicalTest`" -InputId key05 -ExpectedOutcome accepted-with-duplicate -TimeoutSeconds 10"
    $testInfo.UseShellExecute = $false
    $testInfo.RedirectStandardOutput = $true
    $testInfo.RedirectStandardError = $true
    $testInfo.CreateNoWindow = $true
    $test = [Diagnostics.Process]::Start($testInfo)

    Start-Sleep -Milliseconds 700
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class V1CodexForegroundProbe {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);

    public static void SendDuplicateAlias(byte virtualKey) {
        const uint KeyUp = 0x0002;
        keybd_event(0x11, 0, 0, UIntPtr.Zero);
        keybd_event(0x10, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(virtualKey, 0, 0, UIntPtr.Zero);
        keybd_event(virtualKey, 0, KeyUp, UIntPtr.Zero);
        System.Threading.Thread.Sleep(5);
        keybd_event(virtualKey, 0, 0, UIntPtr.Zero);
        keybd_event(virtualKey, 0, KeyUp, UIntPtr.Zero);
        keybd_event(0x12, 0, KeyUp, UIntPtr.Zero);
        keybd_event(0x10, 0, KeyUp, UIntPtr.Zero);
        keybd_event(0x11, 0, KeyUp, UIntPtr.Zero);
    }
}
'@
    Set-CodexKeyboardTestForeground -Handle $form.Handle -Form $form
    $textBox.Focus() | Out-Null
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 300
    [V1CodexForegroundProbe]::SendDuplicateAlias(0x74)

    if (-not $test.WaitForExit(12000)) {
        $test.Kill()
        throw 'Physical input observer timed out.'
    }
    $stdout = $test.StandardOutput.ReadToEnd().Trim()
    $stderr = $test.StandardError.ReadToEnd().Trim()
    if ($test.ExitCode -ne 0) {
        throw "Physical input observer failed: $stderr"
    }
    Start-Sleep -Milliseconds 150
    [System.Windows.Forms.Application]::DoEvents()
    if ($textBox.Text -ne $expectedPrompt) {
        throw "Codex prompt text did not reach the foreground input control. expectedLength=$($expectedPrompt.Length) actualLength=$($textBox.Text.Length)"
    }
    Write-Output $stdout
    Write-Output 'V1_CODEX_CLI_INTEGRATION_PASS input=key05 dispatched=True duplicateBlocked=True promptMatched=True'
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
