[CmdletBinding()]
param(
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'test-window-focus-helper.ps1')
$app = Join-Path $root 'artifacts\portable\Keynob.exe'
$runtimeRoot = Join-Path $root '.runtime'
$testRoot = Join-Path $runtimeRoot ('v2-app-routing-' + [Guid]::NewGuid().ToString('N'))
$settingsRoot = Join-Path $testRoot 'settings'
$settingsPath = Join-Path $settingsRoot 'settings.json'
$probeExe = Join-Path $testRoot 'ChatGPT.exe'
$probeOutput = Join-Path $testRoot 'chatgpt-output.txt'
$chatGptMarker = 'V2_CHATGPT_ROUTE_PASS'
$codexMarker = 'V2_CODEX_ROUTE_PASS'
$layer2Marker = 'V3_LAYER2_ROUTE_PASS'
$layer3Marker = 'V3_LAYER3_ROUTE_PASS'
$previousDataRoot = $env:CODEX_KEYBOARD_STUDIO_DATA_DIR
$previousNoHardwareWrites = $env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES
$existingApp = @(Get-Process Keynob -ErrorAction SilentlyContinue | Select-Object -First 1)
$existingAppPath = if ($existingApp.Count -eq 1) { $existingApp[0].Path } else { $null }
$chatGptProbe = $null
$form = $null

if ($ValidateOnly) {
    if (-not (Test-Path -LiteralPath $app)) { throw 'Portable app is missing.' }
    Write-Output 'V2_APP_ROUTING_READY scopes=chatgpt,codex_cli,non_target isolatedSettings=True deviceWrites=False'
    exit 0
}
if ($existingApp.Count -ne 0) {
    throw 'Stop Codex Keyboard Studio before this no-write integration test.'
}

function New-DisabledBinding {
    [ordered]@{
        scope = 'global'
        actionKind = 'disabled'
        shortcut = $null
        text = $null
        builtInActionId = $null
    }
}

function Send-Alias([byte]$VirtualKey) {
    [V2AliasSender]::Send($VirtualKey)
    Start-Sleep -Milliseconds 350
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-ProbeForeground([IntPtr]$Handle, $Form = $null) {
    Set-CodexKeyboardTestForeground -Handle $Handle -Form $Form
    Start-Sleep -Milliseconds 250
}

function Wait-ForFileValue([string]$Path, [string]$Expected, [int]$TimeoutMilliseconds = 4000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        Start-Sleep -Milliseconds 50
        if ((Test-Path -LiteralPath $Path) -and (Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue) -eq $Expected) {
            return $true
        }
    } until ([DateTime]::UtcNow -ge $deadline)
    return $false
}

try {
    if (-not (Test-Path -LiteralPath $app)) { throw 'Portable app is missing.' }
    if ($existingApp.Count -gt 1) { throw "Expected at most one Studio process, found $($existingApp.Count)." }
    if ($existingApp.Count -eq 1) {
        & $app --exit | Out-Null
        Start-Sleep -Milliseconds 700
    }

    New-Item -ItemType Directory -Path $settingsRoot -Force | Out-Null
    $inputIds = @(
        1..12 | ForEach-Object { 'key{0:00}' -f $_ }
    ) + @('knob1_ccw', 'knob1_press', 'knob1_cw', 'knob2_ccw', 'knob2_press', 'knob2_cw')
    $inputs = [ordered]@{}
    foreach ($inputId in $inputIds) { $inputs[$inputId] = New-DisabledBinding }
    $inputs.key01 = [ordered]@{
        scope = 'chatgpt'; actionKind = 'text'; shortcut = $null
        text = $chatGptMarker; builtInActionId = $null
    }
    $inputs.key02 = [ordered]@{
        scope = 'codex_cli'; actionKind = 'text'; shortcut = $null
        text = $codexMarker; builtInActionId = $null
    }
    $layer2Inputs = [ordered]@{}
    $layer3Inputs = [ordered]@{}
    foreach ($inputId in $inputIds) {
        $layer2Inputs[$inputId] = New-DisabledBinding
        $layer3Inputs[$inputId] = New-DisabledBinding
    }
    $layer2Inputs.key01 = [ordered]@{
        scope = 'codex_cli'; actionKind = 'text'; shortcut = $null
        text = $layer2Marker; builtInActionId = $null
    }
    $layer3Inputs.key01 = [ordered]@{
        scope = 'codex_cli'; actionKind = 'text'; shortcut = $null
        text = $layer3Marker; builtInActionId = $null
    }
    $keyColors = [ordered]@{}
    1..12 | ForEach-Object { $keyColors['key{0:00}' -f $_] = 'blue' }
    $settings = [ordered]@{
        schemaVersion = 3
        device = [ordered]@{
            vendorId = '514C'; productId = '8850'; serial = 'TEST_SERIAL'; layout = '12-key-2-knob'
        }
        layers = [ordered]@{ '1' = $inputs; '2' = $layer2Inputs; '3' = $layer3Inputs }
        statusColors = [ordered]@{ running = 'blue'; approval = 'yellow'; completed = 'green'; error = 'red' }
        keyColors = $keyColors
        restoreKeyColorsAfterCodexCompletion = $true
        startWithWindows = $false
    }
    $settings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $settingsPath -Encoding utf8

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class V2AliasSender {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);

    public static void Send(byte virtualKey) {
        const uint KeyUp = 0x0002;
        keybd_event(0x11, 0, 0, UIntPtr.Zero);
        keybd_event(0x10, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(virtualKey, 0, 0, UIntPtr.Zero);
        keybd_event(virtualKey, 0, KeyUp, UIntPtr.Zero);
        keybd_event(0x12, 0, KeyUp, UIntPtr.Zero);
        keybd_event(0x10, 0, KeyUp, UIntPtr.Zero);
        keybd_event(0x11, 0, KeyUp, UIntPtr.Zero);
    }
}
'@
    $probeSource = @'
using System;
using System.IO;
using System.Windows.Forms;
public static class ChatGptProbeProgram {
    [STAThread]
    public static void Main(string[] args) {
        Application.EnableVisualStyles();
        var form = new Form { Text = "ChatGPT V2 integration probe", Width = 520, Height = 180 };
        var input = new TextBox { Dock = DockStyle.Fill, Multiline = true };
        if (args.Length == 1) input.TextChanged += (sender, eventArgs) => File.WriteAllText(args[0], input.Text);
        form.Controls.Add(input);
        form.Shown += (sender, eventArgs) => input.Focus();
        Application.Run(form);
    }
}
'@
    Add-Type -TypeDefinition $probeSource -Language CSharp -ReferencedAssemblies @(
        'System.Windows.Forms.dll', 'System.Drawing.dll'
    ) -OutputAssembly $probeExe -OutputType WindowsApplication

    $logPath = Join-Path $env:LOCALAPPDATA 'CodexKeyboardStudio\diagnostic.log'
    $baseline = if (Test-Path -LiteralPath $logPath) { @(Get-Content -LiteralPath $logPath -Encoding utf8).Count } else { 0 }
    $env:CODEX_KEYBOARD_STUDIO_DATA_DIR = $settingsRoot
    $env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES = '1'
    Start-Process -FilePath $app -ArgumentList '--background' -WorkingDirectory (Split-Path -Parent $app) -WindowStyle Hidden
    Start-Sleep -Seconds 2
    if (@(Get-Process Keynob -ErrorAction SilentlyContinue).Count -ne 1) {
        throw 'Studio did not start with isolated settings.'
    }

    $chatGptProbe = Start-Process -FilePath $probeExe -ArgumentList ('"' + $probeOutput + '"') -PassThru
    $chatGptProbe.WaitForInputIdle(5000) | Out-Null
    Start-Sleep -Milliseconds 300
    $chatGptProbe.Refresh()
    if ($chatGptProbe.MainWindowHandle -eq [IntPtr]::Zero) { throw 'ChatGPT probe window was not found.' }
    Set-ProbeForeground $chatGptProbe.MainWindowHandle
    Send-Alias 0x70
    if (-not (Wait-ForFileValue $probeOutput $chatGptMarker)) { throw 'ChatGPT scoped text was not dispatched.' }
    $chatGptProbe.CloseMainWindow() | Out-Null
    if (-not $chatGptProbe.WaitForExit(3000)) { $chatGptProbe.Kill(); $chatGptProbe.WaitForExit() }
    $chatGptProbe = $null

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'V2 non-target integration probe'
    $form.Width = 520
    $form.Height = 180
    $textBox = [System.Windows.Forms.TextBox]::new()
    $textBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $form.Controls.Add($textBox)
    Set-ProbeForeground $form.Handle $form
    $textBox.Focus() | Out-Null
    [System.Windows.Forms.Application]::DoEvents()
    Send-Alias 0x70
    if ($textBox.Text.Length -ne 0) { throw 'ChatGPT scoped input leaked into a non-target window.' }

    $form.Text = 'Codex CLI - Keynob - V2 integration probe'
    $textBox.Clear()
    Set-ProbeForeground $form.Handle $form
    $textBox.Focus() | Out-Null
    [System.Windows.Forms.Application]::DoEvents()
    Send-Alias 0x71
    if ($textBox.Text -ne $codexMarker) { throw 'Codex CLI scoped text was not dispatched.' }
    $textBox.Clear()
    Send-Alias 0x7C
    if ($textBox.Text -ne $layer2Marker) { throw 'Layer 2 scoped text was not dispatched.' }
    $textBox.Clear()
    Send-Alias 0x41
    if ($textBox.Text -ne $layer3Marker) { throw 'Layer 3 scoped text was not dispatched.' }

    $newLog = if (Test-Path -LiteralPath $logPath) {
        @(Get-Content -LiteralPath $logPath -Encoding utf8 | Select-Object -Skip $baseline)
    } else { @() }
    if (@($newLog | Where-Object { $_ -match "\tinput_blocked\tlayer=1;input=key01;scope=chatgpt" }).Count -ne 1) {
        throw 'Non-target block was not recorded exactly once.'
    }
    if (@($newLog | Where-Object {
        $_ -match [regex]::Escape($chatGptMarker) -or
        $_ -match [regex]::Escape($codexMarker) -or
        $_ -match [regex]::Escape($layer2Marker) -or
        $_ -match [regex]::Escape($layer3Marker)
    }).Count -ne 0) {
        throw 'Sensitive text was written to the diagnostic log.'
    }
    Write-Output 'V2_APP_ROUTING_PASS chatgptAllowed=True codexCliAllowed=True layer2Allowed=True layer3Allowed=True nonTargetBlocked=True sensitiveTextLogged=False deviceWrites=False'
}
finally {
    if ($form) { $form.Close(); $form.Dispose() }
    if ($chatGptProbe -and -not $chatGptProbe.HasExited) { $chatGptProbe.Kill(); $chatGptProbe.WaitForExit() }
    if (Test-Path -LiteralPath $app) { & $app --exit | Out-Null; Start-Sleep -Milliseconds 700 }
    $env:CODEX_KEYBOARD_STUDIO_DATA_DIR = $previousDataRoot
    if ($null -eq $previousNoHardwareWrites) {
        Remove-Item Env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES = $previousNoHardwareWrites
    }
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedRuntime = (Resolve-Path -LiteralPath $runtimeRoot).Path.TrimEnd('\') + '\'
        $resolvedTest = (Resolve-Path -LiteralPath $testRoot).Path
        if (-not $resolvedTest.StartsWith($resolvedRuntime, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe test cleanup path: $resolvedTest"
        }
        [IO.Directory]::Delete($resolvedTest, $true)
    }
    if ($existingAppPath -and (Test-Path -LiteralPath $existingAppPath)) {
        Start-Process -FilePath $existingAppPath -ArgumentList '--background' -WorkingDirectory (Split-Path -Parent $existingAppPath) -WindowStyle Hidden
    }
}
