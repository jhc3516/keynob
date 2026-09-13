using System.Collections.ObjectModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Keynob.Models;
using Keynob.Services;
using Brush = System.Windows.Media.Brush;
using Color = System.Windows.Media.Color;
using SolidColorBrush = System.Windows.Media.SolidColorBrush;
using Button = System.Windows.Controls.Button;
using InputBinding = Keynob.Models.InputBinding;
using Key = System.Windows.Input.Key;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;

namespace Keynob;

public partial class MainWindow : Window
{
    private static readonly TimeSpan CodexCancellationGracePeriod = TimeSpan.FromMilliseconds(500);
    private static readonly TimeSpan CodexCompletionColorDuration = TimeSpan.FromSeconds(3);
    private static readonly Brush ConnectedBrush = new SolidColorBrush(Color.FromRgb(73, 227, 194));
    private static readonly Brush WarningBrush = new SolidColorBrush(Color.FromRgb(255, 203, 91));
    private static readonly Brush ErrorBrush = new SolidColorBrush(Color.FromRgb(240, 68, 68));
    private static readonly Brush SelectedColorBrush = new SolidColorBrush(Color.FromRgb(244, 250, 247));
    private static readonly IReadOnlyDictionary<string, Brush> LedBrushes = new Dictionary<string, Brush>(StringComparer.Ordinal)
    {
        ["blue"] = new SolidColorBrush(Color.FromRgb(22, 131, 255)),
        ["yellow"] = new SolidColorBrush(Color.FromRgb(255, 176, 0)),
        ["green"] = new SolidColorBrush(Color.FromRgb(32, 200, 120)),
        ["red"] = new SolidColorBrush(Color.FromRgb(240, 68, 68)),
        ["orange"] = new SolidColorBrush(Color.FromRgb(255, 128, 48)),
        ["cyan"] = new SolidColorBrush(Color.FromRgb(0, 216, 216)),
        ["purple"] = new SolidColorBrush(Color.FromRgb(155, 89, 229)),
        ["pink"] = new SolidColorBrush(Color.FromRgb(255, 102, 153))
    };
    private readonly DeviceBridgeClient _deviceBridge = new();
    private readonly SettingsStore _settingsStore = new();
    private readonly DeviceBackupStore _backupStore;
    private readonly DiagnosticLog _diagnosticLog = new();
    private readonly ForegroundAppDetector _foregroundDetector = new();
    private readonly InputActionDispatcher _inputDispatcher;
    private readonly KeyboardHookService _keyboardHook;
    private readonly LedStateCoordinator _ledCoordinator;
    private readonly CodexStatusAggregator _codexStatus = new();
    private readonly CodexStatusPipeServer _codexPipe;
    private readonly CodexLauncherLifetimeTracker _launcherLifetime;
    private readonly CodexStatusSourcePolicy _codexSourcePolicy;
    private readonly StartupRegistrationService _startupRegistration = new();
    private readonly CodexHookInstallationService _hookInstallation = new();
    private readonly BluetoothDeviceDetector _bluetoothDetector = new();
    private readonly UsbDeviceChangeMonitor _usbDeviceChangeMonitor = new();
    private readonly SemaphoreSlim _deviceRefreshGate = new(1, 1);
    private StudioSettings _settings = StudioSettingsCatalog.CreateDefault();
    private Dictionary<string, string> _draftKeyColors = new(
        StudioSettingsCatalog.CreateDefault().KeyColors,
        StringComparer.Ordinal);
    private IReadOnlyDictionary<int, string> _layerSlots = new Dictionary<int, string>();
    private int _selectedLayer = 1;
    private string _selectedInputId = "key01";
    private bool _editorReady;
    private bool _editorDirty;
    private bool _inputEngineRunning;
    private bool _deviceSettingsMismatch;
    private bool _deviceConnected;
    private bool _keyLedDirty;
    private bool _keyLedSaveInProgress;
    private bool _restorePolicyEditorReady;
    private bool _restorePolicyDirty;
    private bool _restorePolicySaveInProgress;
    private bool _settingsApplyInProgress;
    private string? _reportedDeviceSerial;
    private int _lastCodexActiveSessionCount;
    private string _lastCodexActiveSourceSummary = "none";
    private string _lastIgnoredCodexSource = "없음";
    private CancellationTokenSource? _usbRefreshCancellation;
    private CancellationTokenSource? _completionRestoreCancellation;
    private readonly ShortcutCaptureSession _shortcutCapture = new();
    private ShortcutDefinition? _recordedShortcut;

    private Dictionary<string, InputBinding> CurrentInputs => _settings.GetLayerInputs(_selectedLayer);

    public ObservableCollection<KeyTile> Keys { get; } =
    [
        new(1, "ChatGPT 이전 대화"),
        new(2, "작업 검색/전환"),
        new(3, "ChatGPT 다음 대화"),
        new(4, "Typeless 음성 입력 · Left Ctrl+Win+Alt"),
        new(5, "오류 진단"),
        new(6, "프로젝트 설명"),
        new(7, "문서 점검"),
        new(8, "Typeless 번역"),
        new(9, "Skills 열기"),
        new(10, "자동화 열기"),
        new(11, "설정 열기"),
        new(12, "ChatGPT Enter")
    ];

    public event Action<bool>? StartWithWindowsStateChanged;

    public MainWindow()
    {
        InitializeComponent();
        _backupStore = new DeviceBackupStore(_settingsStore.SettingsPath);
        ShortcutSupportGroupList.ItemsSource = ShortcutCatalog.GetSupportGuideSections();
        _inputDispatcher = new InputActionDispatcher(_foregroundDetector, _diagnosticLog);
        _keyboardHook = new KeyboardHookService(
            () => _settings,
            _foregroundDetector,
            _inputDispatcher,
            HandleCodexCancellationAsync,
            Dispatcher,
            _diagnosticLog);
        var noHardwareWrites = string.Equals(
            Environment.GetEnvironmentVariable("CODEX_KEYBOARD_TEST_NO_HARDWARE_WRITES"),
            "1",
            StringComparison.Ordinal);
        ILedDevice ledDevice = noHardwareWrites ? new NoWriteLedDevice() : _deviceBridge;
        _ledCoordinator = new LedStateCoordinator(ledDevice);
        _launcherLifetime = new CodexLauncherLifetimeTracker(
            HandleProducerExitFallbackAsync,
            _diagnosticLog);
        _codexSourcePolicy = new CodexStatusSourcePolicy(
            _launcherLifetime,
            allowManualTestSource: noHardwareWrites);
        var testPipeName = noHardwareWrites
            ? Environment.GetEnvironmentVariable("CODEX_KEYBOARD_TEST_STATUS_PIPE_NAME")
            : null;
        _codexPipe = new CodexStatusPipeServer(
            HandleCodexHookEventAsync,
            _diagnosticLog,
            testPipeName);
        DataContext = this;
        ScopeCombo.ItemsSource = StudioSettingsCatalog.Scopes;
        ActionKindCombo.ItemsSource = StudioSettingsCatalog.ActionKinds;
        RunningColorCombo.ItemsSource = StudioSettingsCatalog.LedColors;
        ApprovalColorCombo.ItemsSource = StudioSettingsCatalog.LedColors;
        CompletedColorCombo.ItemsSource = StudioSettingsCatalog.LedColors;
        ErrorColorCombo.ItemsSource = StudioSettingsCatalog.LedColors;
        PreviewKeyDown += MainWindow_PreviewKeyDown;
        PreviewKeyUp += MainWindow_PreviewKeyUp;
        Deactivated += (_, _) => CancelShortcutRecording("창이 비활성화되어 기록을 취소했습니다.");
        _usbDeviceChangeMonitor.ConnectionMayHaveChanged += HandleUsbConnectionMayHaveChanged;
        Loaded += MainWindow_Loaded;
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        _usbDeviceChangeMonitor.Start(this);
        await LoadSettingsAsync();
        _codexPipe.Start();
        _inputEngineRunning = _keyboardHook.Start();
        if (!_inputEngineRunning)
        {
            SettingsStatusText.Text = "키 입력 엔진을 시작하지 못했습니다 · 진단 로그를 확인하세요";
        }
        RefreshHookStatus();
        await RefreshDeviceAsync(reapplyLedPolicy: true);
        await ApplyCodexAggregateAsync(
            _codexStatus.EnsureCompleted(DateTimeOffset.UtcNow),
            isStartupOrUsbConnection: true);
    }

    public bool ToggleInputPause()
    {
        if (_keyboardHook.IsRunning)
        {
            _keyboardHook.Stop();
            _inputEngineRunning = false;
            SettingsStatusText.Text = "키 입력 엔진을 일시 정지했습니다";
            UpdateRuntimeStatus();
            return true;
        }

        var started = _keyboardHook.Start();
        _inputEngineRunning = started;
        SettingsStatusText.Text = started
            ? "키 입력 엔진을 다시 시작했습니다"
            : "키 입력 엔진을 시작하지 못했습니다 · 진단 로그를 확인하세요";
        UpdateRuntimeStatus();
        return !started;
    }

    public async Task ShutdownServicesAsync()
    {
        var usbRefreshCancellation = Interlocked.Exchange(ref _usbRefreshCancellation, null);
        usbRefreshCancellation?.Cancel();
        usbRefreshCancellation?.Dispose();
        CancelPendingCompletionRestore();
        _usbDeviceChangeMonitor.Dispose();
        _keyboardHook.Dispose();
        _launcherLifetime.Dispose();
        await _codexPipe.StopAsync();
    }

    public async Task<bool> ToggleStartWithWindowsAsync()
    {
        var executablePath = Environment.ProcessPath
            ?? throw new InvalidOperationException("executable_path_missing");
        var enabled = !_settings.StartWithWindows;
        _startupRegistration.SetEnabled(executablePath, enabled);
        var updated = new StudioSettings
        {
            SchemaVersion = _settings.SchemaVersion,
            Device = _settings.Device,
            Layers = _settings.Layers,
            StatusColors = _settings.StatusColors,
            KeyColors = _settings.KeyColors,
            RestoreKeyColorsAfterCodexCompletion = _settings.RestoreKeyColorsAfterCodexCompletion,
            StartWithWindows = enabled
        };
        try
        {
            await _settingsStore.SaveAsync(updated);
            _settings = updated;
            StartWithWindowsStateChanged?.Invoke(enabled);
            SettingsStatusText.Text = enabled
                ? "Windows 로그인 시 자동 시작을 켰습니다"
                : "Windows 로그인 시 자동 시작을 껐습니다";
            return enabled;
        }
        catch
        {
            _startupRegistration.SetEnabled(executablePath, !enabled);
            throw;
        }
    }

    public void OpenDiagnostics()
    {
        var directory = Path.GetDirectoryName(_diagnosticLog.LogPath)!;
        Directory.CreateDirectory(directory);
        System.Diagnostics.Process.Start(
            new System.Diagnostics.ProcessStartInfo(directory) { UseShellExecute = true });
    }

    public void ClearDiagnostics()
    {
        SettingsStatusText.Text = _diagnosticLog.Clear()
            ? "진단 로그를 초기화했습니다"
            : "진단 로그를 초기화하지 못했습니다 · 파일 사용 상태를 확인하세요";
    }

    private async Task LoadSettingsAsync()
    {
        var result = await _settingsStore.LoadAsync();
        _settings = result.Settings;
        _draftKeyColors = new Dictionary<string, string>(_settings.KeyColors, StringComparer.Ordinal);
        _restorePolicyEditorReady = false;
        RestoreKeyColorsCheckBox.IsChecked = _settings.RestoreKeyColorsAfterCodexCompletion;
        _restorePolicyEditorReady = true;
        _keyLedDirty = false;
        _restorePolicyDirty = false;
        UpdateRestorePolicySaveButtonState();
        LoadStatusColorEditors();
        StartWithWindowsStateChanged?.Invoke(_settings.StartWithWindows);
        ApplySettingsToKeyTiles();
        UpdateLayerSelectorVisuals();
        SelectInput("key01", "KEY 1");
        UpdateKeyLedEditorVisuals();

        SettingsStatusText.Text = result switch
        {
            { Ok: false } => $"설정 파일 오류로 기본값을 사용합니다 · {result.Error}",
            { IsDefault: true } => "기본 설정을 불러왔습니다 · 저장하면 사용자 설정 파일이 만들어집니다",
            { WasMigrated: true } => "기존 설정을 V3 형식의 Layer 1로 가져왔습니다. Layer 2·3은 사용 안 함으로 시작하며, 적용하면 새 형식으로 저장합니다.",
            _ => "저장된 PC 앱 설정을 불러왔습니다"
        };
    }

    private async void RefreshDevice_Click(object sender, RoutedEventArgs e)
    {
        await RefreshDeviceAsync();
    }

    private async Task RefreshDeviceAsync(bool reapplyLedPolicy = false)
    {
        await _deviceRefreshGate.WaitAsync();
        try
        {
            var requestedLayer = _selectedLayer;
            var wasConnected = _deviceConnected;
            var bluetooth = _bluetoothDetector.Detect();
            BluetoothStatusText.Text = bluetooth switch
            {
                { Available: true, Detected: true } => "Bluetooth 입력: MINI-KEYBOARD 감지됨 · 실제 연결은 키 입력으로 확인",
                { Available: true, Detected: false } => "Bluetooth 입력: MINI-KEYBOARD 감지 안 됨",
                _ => "Bluetooth 입력: 상태 확인 불가"
            };
            SetDeviceStatus("장치 확인 중", "지원 HID 구조와 단일 장치 여부를 확인합니다", WarningBrush);
            var result = await _deviceBridge.DiscoverAsync();

            if (!result.Ok)
            {
                _deviceConnected = false;
                _reportedDeviceSerial = null;
                SaveSettingsButton.IsEnabled = false;
                ApplyBlankConfigurationButton.IsEnabled = false;
                KeyLedEditorPanel.IsEnabled = false;
                UpdateKeyLedSaveButtonState();
                SetStatusPreviewEnabled(false);
                UpdateBackupRestoreButtonState();
                SetDeviceStatus("장치 확인 실패", result.Error ?? "장치 도우미 응답을 확인하세요", ErrorBrush);
                return;
            }

            if (!result.Connected)
            {
                _deviceConnected = false;
                _reportedDeviceSerial = null;
                SaveSettingsButton.IsEnabled = false;
                ApplyBlankConfigurationButton.IsEnabled = false;
                KeyLedEditorPanel.IsEnabled = false;
                UpdateKeyLedSaveButtonState();
                SetStatusPreviewEnabled(false);
                UpdateBackupRestoreButtonState();
                SetDeviceStatus("USB 키보드 연결 안 됨", "키 입력은 Bluetooth로 가능하지만 LED 설정에는 USB가 필요합니다", WarningBrush);
                return;
            }

            var layer = await _deviceBridge.ReadLayerAsync(requestedLayer);
            if (!layer.Ok)
            {
                _deviceConnected = false;
                _reportedDeviceSerial = null;
                SaveSettingsButton.IsEnabled = false;
                ApplyBlankConfigurationButton.IsEnabled = false;
                KeyLedEditorPanel.IsEnabled = false;
                UpdateKeyLedSaveButtonState();
                SetStatusPreviewEnabled(false);
                UpdateBackupRestoreButtonState();
                SetDeviceStatus(
                    "키보드는 연결됐지만 설정 읽기 실패",
                    layer.Error ?? $"레이어 {requestedLayer} 응답을 확인하세요",
                    ErrorBrush);
                return;
            }

            if (requestedLayer != _selectedLayer)
            {
                return;
            }

            _deviceConnected = true;
            _reportedDeviceSerial = result.Serial;
            _layerSlots = layer.Slots;
            var mismatches = FindDeviceMismatches(_settings, requestedLayer, _layerSlots);
            _deviceSettingsMismatch = mismatches.Count > 0;
            if (_deviceSettingsMismatch)
            {
                _diagnosticLog.Write(
                    "device_settings_mismatch",
                    $"layer={requestedLayer};inputs={string.Join(',', mismatches)}");
            }
            SaveSettingsButton.IsEnabled = true;
            ApplyBlankConfigurationButton.IsEnabled = true;
            SetStatusPreviewEnabled(true);
            KeyLedEditorPanel.IsEnabled = _selectedInputId.StartsWith("key", StringComparison.Ordinal);
            UpdateKeyLedSaveButtonState();
            UpdateBackupRestoreButtonState();
            SetDeviceStatus(
                "12키·2노브 키보드 연결됨",
                _deviceSettingsMismatch
                    ? "장치와 PC 설정이 다릅니다. 적용할 때 어느 값을 유지할지 선택합니다."
                    : $"레이어 {requestedLayer}의 입력 설정 {layer.SlotCount}개가 PC 설정과 일치합니다. · Serial {result.Serial ?? "없음"}",
                _deviceSettingsMismatch ? WarningBrush : ConnectedBrush);

            if (reapplyLedPolicy || !wasConnected)
            {
                await ApplyLedPolicyForUsbConnectionAsync();
            }
        }
        finally
        {
            _deviceRefreshGate.Release();
        }
    }

    private void HandleUsbConnectionMayHaveChanged()
    {
        var next = new CancellationTokenSource();
        var previous = Interlocked.Exchange(
            ref _usbRefreshCancellation,
            next);
        previous?.Cancel();
        previous?.Dispose();
        _ = RefreshAfterUsbChangeAsync(next);
    }

    private async Task RefreshAfterUsbChangeAsync(CancellationTokenSource cancellation)
    {
        try
        {
            await Task.Delay(TimeSpan.FromMilliseconds(700), cancellation.Token);
            _diagnosticLog.Write("usb_device_change_detected", "refresh=debounced");
            await RefreshDeviceAsync(reapplyLedPolicy: true);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            _diagnosticLog.Write("usb_device_refresh_failed", exception.GetType().Name);
        }
        finally
        {
            if (ReferenceEquals(
                Interlocked.CompareExchange(ref _usbRefreshCancellation, null, cancellation),
                cancellation))
            {
                cancellation.Dispose();
            }
        }
    }

    private void SetDeviceStatus(string title, string detail, Brush color)
    {
        DeviceTitleText.Text = title;
        DeviceDetailText.Text = detail;
        HeaderStatusText.Text = title;
        HeaderStatusDot.Fill = color;
    }

    private void SetStatusPreviewEnabled(bool enabled)
    {
        RunningPreviewButton.IsEnabled = enabled;
        ApprovalPreviewButton.IsEnabled = enabled;
        CompletedPreviewButton.IsEnabled = enabled;
        ErrorPreviewButton.IsEnabled = enabled;
    }

    private async void LayerButton_Click(object sender, RoutedEventArgs e)
    {
        if (_settingsApplyInProgress || sender is not Button { Tag: string layerText } ||
            !int.TryParse(layerText, out var layer) || layer == _selectedLayer ||
            !StudioSettingsCatalog.LayerIds.Contains(layer))
        {
            return;
        }

        if (_editorReady && _editorDirty)
        {
            var decision = System.Windows.MessageBox.Show(
                "선택한 입력의 변경 내용이 아직 적용되지 않았습니다.\n\n변경을 버리고 다른 레이어로 이동할까요?",
                "적용하지 않은 변경",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);
            if (decision != MessageBoxResult.Yes)
            {
                return;
            }
        }

        CancelShortcutRecording(null);
        _editorDirty = false;
        _selectedLayer = layer;
        _layerSlots = new Dictionary<int, string>();
        _deviceSettingsMismatch = false;
        UpdateLayerSelectorVisuals();
        ApplySettingsToKeyTiles();
        SelectInput(_selectedInputId, GetInputLabel(_selectedInputId));
        SettingsStatusText.Text = $"Layer {layer} 장치 설정을 확인하고 있습니다";
        await RefreshDeviceAsync();
        if (_selectedLayer != layer)
        {
            return;
        }

        SettingsStatusText.Text = !_deviceConnected
            ? $"Layer {layer} 장치 설정을 읽지 못했습니다 · 다시 확인을 눌러 주세요"
            : _deviceSettingsMismatch
                ? $"Layer {layer} 장치와 PC 설정이 다릅니다 · 적용할 값을 선택하세요"
                : $"Layer {layer} 장치 설정 확인 완료";
    }

    private void UpdateLayerSelectorVisuals()
    {
        var buttons = new[] { Layer1Button, Layer2Button, Layer3Button };
        for (var index = 0; index < buttons.Length; index++)
        {
            var selected = index + 1 == _selectedLayer;
            buttons[index].Background = new SolidColorBrush(selected
                ? Color.FromRgb(255, 203, 91)
                : Color.FromRgb(22, 37, 40));
            buttons[index].Foreground = new SolidColorBrush(selected
                ? Color.FromRgb(18, 29, 31)
                : Color.FromRgb(232, 243, 241));
            buttons[index].FontWeight = selected ? FontWeights.Bold : FontWeights.SemiBold;
        }
    }

    private void SetLayerSelectorEnabled(bool enabled)
    {
        Layer1Button.IsEnabled = enabled;
        Layer2Button.IsEnabled = enabled;
        Layer3Button.IsEnabled = enabled;
    }

    private void KeyButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { DataContext: KeyTile tile })
        {
            SelectInput($"key{tile.Number:00}", $"KEY {tile.Number}");
        }
    }

    private void KnobInput_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string inputId })
        {
            return;
        }

        var inputLabel = inputId switch
        {
            "knob1_ccw" => "KNOB 1 · 왼쪽 회전",
            "knob1_press" => "KNOB 1 · 누름",
            "knob1_cw" => "KNOB 1 · 오른쪽 회전",
            "knob2_ccw" => "KNOB 2 · 왼쪽 회전",
            "knob2_press" => "KNOB 2 · 누름",
            "knob2_cw" => "KNOB 2 · 오른쪽 회전",
            _ => null
        };
        if (inputLabel is not null)
        {
            SelectInput(inputId, inputLabel);
        }
    }

    private void SelectInput(string inputId, string inputLabel)
    {
        if (_editorReady && _editorDirty)
        {
            if (string.Equals(inputId, _selectedInputId, StringComparison.Ordinal))
            {
                return;
            }
            var decision = System.Windows.MessageBox.Show(
                "선택한 입력의 변경 내용이 아직 적용되지 않았습니다.\n\n변경을 버리고 다른 입력으로 이동할까요?",
                "적용되지 않은 변경",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);
            if (decision != MessageBoxResult.Yes)
            {
                return;
            }
        }
        CancelShortcutRecording(null);
        _selectedInputId = inputId;
        var isKey = inputId.StartsWith("key", StringComparison.Ordinal);
        KeyLedEditorPanel.IsEnabled = isKey && _deviceConnected;
        KeyLedContextText.Text = isKey
            ? $"선택한 물리 키 · {inputLabel} · 레이어 공통"
            : "노브에는 LED 슬롯이 없습니다";
        UpdateKeyLedEditorVisuals();
        var binding = CurrentInputs[inputId];
        SelectedInputText.Text = $"LAYER {_selectedLayer} · {inputLabel} · {StudioSettingsCatalog.GetActionLabel(binding)}";

        _editorReady = false;
        ScopeCombo.SelectedItem = StudioSettingsCatalog.Scopes.First(scope => scope.Id == binding.Scope);
        SetActionKindOptions(binding.Scope, binding.ActionKind);
        _recordedShortcut = binding.Shortcut;
        ShortcutTextBox.Text = binding.Shortcut is null ? "기록되지 않음" : ShortcutCatalog.Format(binding.Shortcut);
        ActionTextBox.Text = binding.Text ?? string.Empty;
        SetBuiltInOptions(binding.Scope, binding.BuiltInActionId);
        _editorReady = true;
        _editorDirty = false;
        UpdateBindingEditorVisibility();
    }

    private void BindingEditor_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_editorReady)
        {
            return;
        }
        if (sender == ScopeCombo && ScopeCombo.SelectedItem is ScopeOption scope)
        {
            var selectedKindId = (ActionKindCombo.SelectedItem as ActionKindOption)?.Id;
            _editorReady = false;
            SetActionKindOptions(scope.Id, selectedKindId);
            SetBuiltInOptions(scope.Id, null);
            _editorReady = true;
        }
        UpdateBindingEditorVisibility();
        MarkEditorDirty();
    }

    private void ActionTextBox_TextChanged(object sender, TextChangedEventArgs e) => MarkEditorDirty();

    private void BuiltInActionCombo_SelectionChanged(object sender, SelectionChangedEventArgs e) => MarkEditorDirty();

    private void MarkEditorDirty()
    {
        if (!_editorReady)
        {
            return;
        }
        _editorDirty = true;
        var kind = (ActionKindCombo.SelectedItem as ActionKindOption)?.Id;
        var scope = (ScopeCombo.SelectedItem as ScopeOption)?.Id;
        if (kind != ActionKinds.Text || scope is BindingScopes.ChatGpt or BindingScopes.CodexCli)
        {
            SettingsStatusText.Text = "적용되지 않은 변경이 있습니다 · 미리보기 또는 변경 내용 적용을 누르세요.";
        }
    }

    private void SetBuiltInOptions(string scope, string? selectedActionId)
    {
        var actions = StudioSettingsCatalog.BuiltInActions.Where(action => action.Scope == scope).ToArray();
        BuiltInActionCombo.ItemsSource = actions;
        BuiltInActionCombo.SelectedItem = actions.FirstOrDefault(action => action.Id == selectedActionId) ?? actions.FirstOrDefault();
    }

    private void SetActionKindOptions(string scope, string? selectedKindId)
    {
        var options = StudioSettingsCatalog.GetActionKinds(scope);
        ActionKindCombo.ItemsSource = options;
        ActionKindCombo.SelectedItem = options.FirstOrDefault(option => option.Id == selectedKindId) ?? options[0];
    }

    private void UpdateBindingEditorVisibility()
    {
        var kind = (ActionKindCombo.SelectedItem as ActionKindOption)?.Id;
        ShortcutEditorPanel.Visibility = kind == ActionKinds.Shortcut ? Visibility.Visible : Visibility.Collapsed;
        TextEditorPanel.Visibility = kind == ActionKinds.Text ? Visibility.Visible : Visibility.Collapsed;
        BuiltInEditorPanel.Visibility = kind == ActionKinds.BuiltIn ? Visibility.Visible : Visibility.Collapsed;
        var scope = (ScopeCombo.SelectedItem as ScopeOption)?.Id;
        ShortcutSupportGuideText.Text = ShortcutCatalog.GetScopeSupportGuide(scope ?? BindingScopes.Global);
        TextScopeHelpText.Text = scope == BindingScopes.CodexCli
            ? "Start-CodexCli.exe로 연 Codex CLI 창에서만 작동합니다. 텍스트는 평문으로 저장됩니다."
            : "평문으로 저장됩니다. 비밀번호나 비밀 정보는 넣지 마세요.";
        if (kind == ActionKinds.Text && scope is not (BindingScopes.ChatGpt or BindingScopes.CodexCli))
        {
            SettingsStatusText.Text = "텍스트 입력은 ChatGPT 또는 Codex CLI 범위에서만 사용할 수 있습니다.";
        }
    }

    private InputBinding ReadBindingFromEditor()
    {
        var scope = (ScopeCombo.SelectedItem as ScopeOption)?.Id
            ?? throw new InvalidDataException("scope_not_selected");
        var kind = (ActionKindCombo.SelectedItem as ActionKindOption)?.Id
            ?? throw new InvalidDataException("action_kind_not_selected");
        return kind switch
        {
            ActionKinds.Disabled => new InputBinding { Scope = scope, ActionKind = kind },
            ActionKinds.Shortcut => new InputBinding { Scope = scope, ActionKind = kind, Shortcut = _recordedShortcut },
            ActionKinds.Text => new InputBinding { Scope = scope, ActionKind = kind, Text = ActionTextBox.Text },
            ActionKinds.BuiltIn when BuiltInActionCombo.SelectedItem is BuiltInActionOption action =>
                new InputBinding { Scope = scope, ActionKind = kind, BuiltInActionId = action.Id },
            _ => throw new InvalidDataException("action_payload_not_selected")
        };
    }

    private void PreviewSettings_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var binding = ReadBindingFromEditor();
            var compiled = BindingCompiler.Compile(_selectedLayer, _selectedInputId, binding);
            var delivery = compiled.Delivery switch
            {
                BindingDelivery.Disabled => "장치에서 입력 없음",
                BindingDelivery.DeviceDirect => "키보드가 직접 단축키 전송",
                BindingDelivery.AppRouted => $"앱이 {binding.Scope} 범위를 확인한 뒤 실행",
                _ => compiled.Delivery.ToString()
            };
            SettingsStatusText.Text = $"미리보기 · {delivery} · 실제 입력이나 장치 변경은 실행하지 않았습니다.";
        }
        catch (InvalidDataException exception)
        {
            SettingsStatusText.Text = $"미리보기 실패 · {exception.Message}";
        }
    }

    private async void TestSettings_Click(object sender, RoutedEventArgs e)
    {
        InputBinding binding;
        try
        {
            binding = ReadBindingFromEditor();
            var compiled = BindingCompiler.Compile(_selectedLayer, _selectedInputId, binding);
            if (compiled.Delivery == BindingDelivery.Disabled)
            {
                SettingsStatusText.Text = "실제 시험할 동작이 없습니다 · 이 입력은 사용 안 함입니다.";
                return;
            }
        }
        catch (InvalidDataException exception)
        {
            SettingsStatusText.Text = $"실제 시험 실패 · {exception.Message}";
            return;
        }

        var decision = System.Windows.MessageBox.Show(
            "선택한 동작을 실제로 한 번 실행합니다.\n\n계속하면 2초 뒤 실행되므로 그 전에 대상 창으로 전환하세요.",
            "선택 동작 실제 시험",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);
        if (decision != MessageBoxResult.Yes)
        {
            SettingsStatusText.Text = "실제 시험을 취소했습니다.";
            return;
        }

        TestSettingsButton.IsEnabled = false;
        SettingsStatusText.Text = "2초 뒤 실행합니다 · 지금 대상 창으로 전환하세요.";
        await Task.Delay(TimeSpan.FromSeconds(2));
        try
        {
            var dispatched = await _inputDispatcher.DispatchManualTestAsync(
                _selectedLayer,
                _selectedInputId,
                binding);
            SettingsStatusText.Text = dispatched
                ? "실제 시험을 한 번 실행했습니다."
                : "실제 시험을 실행하지 못했습니다 · 대상 앱과 설정을 확인하세요.";
        }
        catch (InvalidDataException exception)
        {
            SettingsStatusText.Text = $"실제 시험 실패 · {exception.Message}";
        }
        finally
        {
            TestSettingsButton.IsEnabled = true;
        }
    }

    private void ClearSelectedInput_Click(object sender, RoutedEventArgs e)
    {
        CancelShortcutRecording(null);
        _editorReady = false;
        ActionKindCombo.SelectedItem = StudioSettingsCatalog.ActionKinds.First(option => option.Id == ActionKinds.Disabled);
        _recordedShortcut = null;
        ShortcutTextBox.Text = "기록되지 않음";
        ActionTextBox.Text = string.Empty;
        SetBuiltInOptions((ScopeCombo.SelectedItem as ScopeOption)?.Id ?? BindingScopes.Global, null);
        _editorReady = true;
        _editorDirty = true;
        UpdateBindingEditorVisibility();
        SettingsStatusText.Text = "선택 입력을 비웠습니다 · 변경 내용 적용 전에는 장치가 바뀌지 않습니다.";
    }

    private async void ApplyBlankConfiguration_Click(object sender, RoutedEventArgs e)
    {
        var decision = System.Windows.MessageBox.Show(
            $"Layer {_selectedLayer}의 키 12개와 노브 동작 6개를 모두 사용 안 함으로 바꿉니다.\n\n다른 레이어와 LED 설정은 유지되며, 실제 장치에 적용하기 전에 한 번 더 검증합니다.",
            $"Layer {_selectedLayer} 전체 비우기",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);
        if (decision != MessageBoxResult.Yes || !await ResolveDeviceMismatchAsync())
        {
            return;
        }

        var updated = StudioSettingsCatalog.CreateBlankLayerFrom(_settings, _selectedLayer);
        try
        {
            StudioSettingsCatalog.Validate(updated);
        }
        catch (InvalidDataException exception)
        {
            SettingsStatusText.Text = $"빈 구성을 만들지 못했습니다 · {exception.Message}";
            return;
        }
        await ApplySettingsAsync(updated);
    }

    private async void SaveSettings_Click(object sender, RoutedEventArgs e)
    {
        _diagnosticLog.Write(
            "settings_apply_requested",
            $"layer={_selectedLayer};input={_selectedInputId};mismatch={_deviceSettingsMismatch}");
        if (!await ResolveDeviceMismatchAsync()) return;

        InputBinding binding;
        try
        {
            binding = ReadBindingFromEditor();
            _ = BindingCompiler.Compile(_selectedLayer, _selectedInputId, binding);
        }
        catch (InvalidDataException exception)
        {
            SettingsStatusText.Text = $"설정을 확인하세요 · {DescribeSettingsError(exception.Message)}";
            return;
        }

        var inputs = new Dictionary<string, InputBinding>(CurrentInputs, StringComparer.Ordinal)
        {
            [_selectedInputId] = binding
        };
        var updated = new StudioSettings
        {
            SchemaVersion = _settings.SchemaVersion,
            Device = _settings.Device,
            Layers = StudioSettingsCatalog.ReplaceLayer(_settings, _selectedLayer, inputs).Layers,
            StatusColors = _settings.StatusColors,
            KeyColors = _settings.KeyColors,
            RestoreKeyColorsAfterCodexCompletion = _settings.RestoreKeyColorsAfterCodexCompletion,
            StartWithWindows = _settings.StartWithWindows
        };

        try
        {
            StudioSettingsCatalog.Validate(updated);
        }
        catch (InvalidDataException exception)
        {
            SettingsStatusText.Text = $"설정을 확인하세요 · {DescribeSettingsError(exception.Message)}";
            return;
        }

        await ApplySettingsAsync(updated);
    }

    private static string DescribeSettingsError(string error)
    {
        var parts = error.Split(':');
        if (parts is ["duplicate_shortcut", _, _, var firstInput, var secondInput])
        {
            return $"같은 적용 범위에서 {GetInputLabel(firstInput)}와 {GetInputLabel(secondInput)}에 같은 단축키를 사용할 수 없습니다.";
        }
        return error switch
        {
            "reserved_alias_shortcut" => "이 조합은 앱 범위 입력을 구분하는 내부 예약 단축키라 전역·Typeless 키로 사용할 수 없습니다.",
            "right_modifier_not_supported_by_device" => "키보드가 좌우 보조키를 구분하지 못하므로 전역·Typeless에는 왼쪽 Ctrl·Shift·Win·Alt를 사용하세요.",
            "empty_shortcut" or "invalid_shortcut_payload" => "단축키 기록을 먼저 완료하세요.",
            "invalid_text_binding" => "텍스트는 ChatGPT·Codex CLI 범위에서 1~2,000자로 입력하세요.",
            _ => error
        };
    }

    private async Task<bool> ResolveDeviceMismatchAsync()
    {
        if (!_deviceSettingsMismatch)
        {
            return true;
        }

        var decision = System.Windows.MessageBox.Show(
            $"Layer {_selectedLayer}의 장치 값과 PC 설정이 다릅니다.\n\n예: 화면의 PC 설정을 이 레이어에 적용\n아니요: 이 레이어의 장치 값을 PC 설정으로 가져오기\n취소: 아무것도 바꾸지 않음",
            $"Layer {_selectedLayer} 설정 불일치",
            MessageBoxButton.YesNoCancel,
            MessageBoxImage.Warning);
        if (decision == MessageBoxResult.No)
        {
            await ImportDeviceSettingsAsync();
        }
        return decision == MessageBoxResult.Yes;
    }

    private async Task ApplySettingsAsync(StudioSettings updated)
    {
        var layer = _selectedLayer;
        _settingsApplyInProgress = true;
        SetLayerSelectorEnabled(false);
        SaveSettingsButton.IsEnabled = false;
        ApplyBlankConfigurationButton.IsEnabled = false;
        if (_layerSlots.Count != 25)
        {
            SettingsStatusText.Text = "장치 원본 값이 없습니다 · 다시 확인을 눌러 주세요";
            SaveSettingsButton.IsEnabled = true;
            ApplyBlankConfigurationButton.IsEnabled = false;
            _settingsApplyInProgress = false;
            SetLayerSelectorEnabled(true);
            return;
        }

        SettingsStatusText.Text = $"Layer {layer}의 18개 입력을 비교하고 변경된 슬롯을 안전하게 적용하고 있습니다";
        try
        {
            var freshBefore = await _deviceBridge.ReadLayerAsync(layer);
            if (!freshBefore.Ok)
            {
                SettingsStatusText.Text = $"적용 직전 장치 재읽기 실패 · {freshBefore.Error}";
                return;
            }
            if (!LayerSnapshotsEqual(_layerSlots, freshBefore.Slots))
            {
                _layerSlots = freshBefore.Slots;
                _deviceSettingsMismatch = !DeviceMatchesSettings(_settings, layer, _layerSlots);
                SettingsStatusText.Text = "새로고침 뒤 장치 값이 바뀌었습니다. 내용을 다시 확인하고 적용하세요.";
                return;
            }

            var backupError = await SaveDeviceBackupAsync(layer, freshBefore.Slots);
            if (backupError is not null)
            {
                SettingsStatusText.Text = $"장치 백업 실패 · 적용을 중단했습니다 · {backupError}";
                return;
            }

            var deviceResult = await _deviceBridge.ApplyBindingsAsync(layer, updated, freshBefore.Slots);
            if (!deviceResult.Ok)
            {
                SettingsStatusText.Text = deviceResult.Error == "slot_changed_since_read"
                    ? "장치 값이 달라졌습니다. 다시 확인한 뒤 적용하세요."
                    : $"키보드 저장 실패 · {deviceResult.Error} · 되돌림 확인={deviceResult.RollbackVerified}";
                return;
            }

            var intendedSlots = new Dictionary<int, string>(freshBefore.Slots);
            foreach (var compiled in BindingCompiler.CompileLayer(updated, layer).Values)
            {
                if (InputAliasCatalog.TryGetByInputId(layer, compiled.InputId, out var alias))
                {
                    intendedSlots[alias.Slot] = DeviceReportEncoder.EncodeHex(compiled);
                }
            }
            var freshAfter = await _deviceBridge.ReadLayerAsync(layer);
            if (!freshAfter.Ok || !DeviceMatchesSettings(updated, layer, freshAfter.Slots))
            {
                var rollbackSource = freshAfter.Ok ? freshAfter.Slots : intendedSlots;
                var rollback = await _deviceBridge.RestoreSnapshotAsync(
                    layer,
                    freshBefore.Slots,
                    rollbackSource);
                SettingsStatusText.Text = rollback.Ok
                    ? "적용 후 전체 검증에 실패해 키보드를 이전 상태로 되돌렸습니다."
                    : "적용 후 전체 검증과 키보드 되돌림에 실패했습니다. 다시 확인이 필요합니다.";
                _deviceSettingsMismatch = true;
                return;
            }

            SettingsStatusText.Text = "키보드 검증 완료 · PC 앱 설정을 저장하고 있습니다";
            var persistence = await SettingsPersistenceCoordinator.SaveAsync(
                token => _settingsStore.SaveAsync(updated, token),
                token => _deviceBridge.RestoreSnapshotAsync(
                    layer,
                    freshBefore.Slots,
                    freshAfter.Slots,
                    token));
            if (!persistence.Saved)
            {
                SettingsStatusText.Text = persistence.RestoreVerified
                    ? $"PC 설정 저장 실패로 키보드를 이전 상태로 되돌렸습니다. · {persistence.Error}"
                    : $"PC 설정 저장과 키보드 되돌림에 실패했습니다. · {persistence.Error}";
                _deviceSettingsMismatch = !persistence.RestoreVerified ||
                    !DeviceMatchesSettings(_settings, layer, freshBefore.Slots);
                return;
            }
            _layerSlots = freshAfter.Slots;
            _deviceSettingsMismatch = false;
            _settings = updated;
            ApplySettingsToKeyTiles();
            _editorDirty = false;
            SelectInput(_selectedInputId, GetInputLabel(_selectedInputId));
            SettingsStatusText.Text = deviceResult.ChangedSlots.Count > 0
                ? $"Layer {layer} · 키보드 {deviceResult.ChangedSlots.Count}개 슬롯 검증과 PC 설정 저장 완료"
                : $"Layer {layer} · 키보드 값이 이미 같아 쓰지 않고 PC 설정만 저장했습니다";
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            SettingsStatusText.Text = $"설정 저장 실패 · {exception.Message}";
        }
        finally
        {
            _settingsApplyInProgress = false;
            SetLayerSelectorEnabled(true);
            SaveSettingsButton.IsEnabled = true;
            ApplyBlankConfigurationButton.IsEnabled = _layerSlots.Count == 25;
            UpdateBackupRestoreButtonState();
        }
    }

    private async Task<string?> SaveDeviceBackupAsync(
        int layer,
        IReadOnlyDictionary<int, string> slots)
    {
        var led = await _deviceBridge.ReadLedAsync();
        if (!led.Ok || led.Snapshot is null) return led.Error ?? "led_read_failed";
        try
        {
            await _backupStore.SaveAsync(layer, slots, led.Snapshot, _reportedDeviceSerial);
            UpdateBackupRestoreButtonState();
            return null;
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            return exception.Message;
        }
    }

    private void UpdateBackupRestoreButtonState()
    {
        RestoreLatestBackupButton.IsEnabled = _deviceConnected && !_settingsApplyInProgress &&
            File.Exists(_backupStore.BackupPath);
    }

    private async void RestoreLatestBackup_Click(object sender, RoutedEventArgs e)
    {
        if (!_deviceConnected || _settingsApplyInProgress) return;
        var loaded = await _backupStore.LoadAsync();
        if (!loaded.Ok || loaded.Backup is null)
        {
            SettingsStatusText.Text = $"최근 백업을 열 수 없습니다 · {loaded.Error}";
            return;
        }
        var backup = loaded.Backup;
        if (System.Windows.MessageBox.Show(
            $"{backup.CreatedUtc.LocalDateTime:G}에 저장한 Layer {backup.Layer}와 LED 상태로 복원합니다.",
            "최근 장치 백업 복원",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning) != MessageBoxResult.Yes) return;

        _settingsApplyInProgress = true;
        SetLayerSelectorEnabled(false);
        SaveSettingsButton.IsEnabled = false;
        ApplyBlankConfigurationButton.IsEnabled = false;
        UpdateBackupRestoreButtonState();
        try
        {
            var probe = await _deviceBridge.DiscoverAsync();
            if (!probe.Ok || !probe.Connected)
            {
                SettingsStatusText.Text = $"복원 대상 장치 호환성 확인 실패 · {probe.Error}";
                return;
            }
            var current = await _deviceBridge.ReadLayerAsync(backup.Layer);
            if (!current.Ok)
            {
                SettingsStatusText.Text = $"복원 전 Layer {backup.Layer} 읽기 실패 · {current.Error}";
                return;
            }
            var currentLed = await _deviceBridge.ReadLedAsync();
            if (!currentLed.Ok || currentLed.Snapshot is null)
            {
                SettingsStatusText.Text = $"복원 전 LED 읽기 실패 · {currentLed.Error}";
                return;
            }
            var controlledSlots = InputAliasCatalog.All
                .Where(alias => alias.Layer == backup.Layer)
                .Select(alias => alias.Slot)
                .ToHashSet();
            if (Enumerable.Range(1, 25).Any(slot => !controlledSlots.Contains(slot) &&
                !string.Equals(current.Slots[slot], backup.Slots[slot], StringComparison.OrdinalIgnoreCase)))
            {
                SettingsStatusText.Text = "백업 이후 예약 슬롯이 바뀌어 안전하게 복원할 수 없습니다.";
                return;
            }

            var keyRestore = await _deviceBridge.RestoreSnapshotAsync(
                backup.Layer, backup.Slots, current.Slots);
            if (!keyRestore.Ok)
            {
                SettingsStatusText.Text = $"키·노브 복원 실패 · {keyRestore.Error} · 되돌림 확인={keyRestore.RollbackVerified}";
                return;
            }
            var keyVerification = await _deviceBridge.ReadLayerAsync(backup.Layer);
            if (!keyVerification.Ok || !LayerSnapshotsEqual(backup.Slots, keyVerification.Slots))
            {
                var keyRollback = await _deviceBridge.RestoreSnapshotAsync(
                    backup.Layer,
                    current.Slots,
                    keyVerification.Ok ? keyVerification.Slots : backup.Slots);
                SettingsStatusText.Text = keyRollback.Ok
                    ? "키·노브 복원 후 검증에 실패해 시작 전 상태로 되돌렸습니다."
                    : "키·노브 복원 후 검증과 시작 전 상태 되돌림에 실패했습니다.";
                return;
            }

            var ledRestore = await _deviceBridge.RestoreLedAsync(backup.Led);
            if (!ledRestore.Ok)
            {
                var keyRollback = await _deviceBridge.RestoreSnapshotAsync(
                    backup.Layer, current.Slots, keyVerification.Slots);
                SettingsStatusText.Text = keyRollback.Ok && ledRestore.RestoreVerified
                    ? $"LED 복원 실패로 키·노브와 LED를 시작 전 상태로 되돌렸습니다. · {ledRestore.Error}"
                    : $"LED 복원 실패 후 시작 전 상태 되돌림을 확인하지 못했습니다. · {ledRestore.Error}";
                return;
            }
            var ledVerification = await _deviceBridge.ReadLedAsync();
            if (!ledVerification.Ok || ledVerification.Snapshot != backup.Led)
            {
                var ledRollback = await _deviceBridge.RestoreLedAsync(currentLed.Snapshot);
                var keyRollback = await _deviceBridge.RestoreSnapshotAsync(
                    backup.Layer, current.Slots, keyVerification.Slots);
                SettingsStatusText.Text = ledRollback.Ok && keyRollback.Ok
                    ? "LED 최종 검증 실패로 키·노브와 LED를 시작 전 상태로 되돌렸습니다."
                    : "LED 최종 검증 실패 후 시작 전 상태 되돌림을 확인하지 못했습니다.";
                return;
            }

            _ledCoordinator.Invalidate();
            if (_selectedLayer == backup.Layer)
            {
                _layerSlots = keyVerification.Slots;
                _deviceSettingsMismatch = !DeviceMatchesSettings(_settings, backup.Layer, _layerSlots);
            }
            SettingsStatusText.Text = $"최근 백업 복원 완료 · Layer {backup.Layer} 25슬롯과 LED 검증 완료";
        }
        finally
        {
            _settingsApplyInProgress = false;
            SetLayerSelectorEnabled(true);
            SaveSettingsButton.IsEnabled = _deviceConnected;
            ApplyBlankConfigurationButton.IsEnabled = _deviceConnected && _layerSlots.Count == 25;
            UpdateBackupRestoreButtonState();
        }
    }

    private static bool DeviceMatchesSettings(
        StudioSettings settings,
        int layer,
        IReadOnlyDictionary<int, string> slots)
        => FindDeviceMismatches(settings, layer, slots).Count == 0;

    private static IReadOnlyList<string> FindDeviceMismatches(
        StudioSettings settings,
        int layer,
        IReadOnlyDictionary<int, string> slots)
    {
        var mismatches = new List<string>();
        try
        {
            foreach (var compiled in BindingCompiler.CompileLayer(settings, layer).Values)
            {
                if (!InputAliasCatalog.TryGetByInputId(layer, compiled.InputId, out var alias) ||
                    !slots.TryGetValue(alias.Slot, out var actual) ||
                    !string.Equals(DeviceReportEncoder.EncodeHex(compiled), actual, StringComparison.OrdinalIgnoreCase))
                {
                    mismatches.Add(compiled.InputId);
                }
            }
            return mismatches;
        }
        catch (InvalidDataException)
        {
            return StudioSettingsCatalog.InputIds.ToArray();
        }
    }

    private static bool LayerSnapshotsEqual(
        IReadOnlyDictionary<int, string> first,
        IReadOnlyDictionary<int, string> second) =>
        first.Count == 25 && second.Count == 25 &&
        Enumerable.Range(1, 25).All(slot =>
            first.TryGetValue(slot, out var firstHex) && second.TryGetValue(slot, out var secondHex) &&
            string.Equals(firstHex, secondHex, StringComparison.OrdinalIgnoreCase));

    private async Task ImportDeviceSettingsAsync()
    {
        var layer = _selectedLayer;
        if (!DeviceSettingsImporter.TryImport(
            _settings,
            layer,
            _layerSlots,
            out var decodedInputs,
            out var importError))
        {
            SettingsStatusText.Text = importError?.StartsWith("unresolved_app_alias:", StringComparison.Ordinal) == true
                ? "장치의 앱 별칭만으로는 원래 동작을 알 수 없습니다. PC 프로필을 장치에 적용하거나 각 입력을 다시 설정하세요."
                : $"장치 값 가져오기 실패 · {importError}";
            return;
        }

        var imported = new StudioSettings
        {
            Device = _settings.Device,
            Layers = StudioSettingsCatalog.ReplaceLayer(_settings, layer, decodedInputs).Layers,
            StatusColors = _settings.StatusColors,
            KeyColors = _settings.KeyColors,
            RestoreKeyColorsAfterCodexCompletion = _settings.RestoreKeyColorsAfterCodexCompletion,
            StartWithWindows = _settings.StartWithWindows
        };
        _settingsApplyInProgress = true;
        SetLayerSelectorEnabled(false);
        try
        {
            await _settingsStore.SaveAsync(imported);
            _settings = imported;
            _deviceSettingsMismatch = false;
            ApplySettingsToKeyTiles();
            _editorDirty = false;
            SelectInput(_selectedInputId, GetInputLabel(_selectedInputId));
            SettingsStatusText.Text = $"Layer {layer}의 18개 입력 값을 PC 설정으로 가져왔습니다.";
            SetDeviceStatus(
                "12키·2노브 키보드 연결됨",
                $"Layer {layer} 장치 값을 PC 설정으로 가져왔습니다.",
                ConnectedBrush);
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            SettingsStatusText.Text = $"장치 값 가져오기 실패 · {exception.Message}";
        }
        finally
        {
            _settingsApplyInProgress = false;
            SetLayerSelectorEnabled(true);
        }
    }

    private void RecordShortcut_Click(object sender, RoutedEventArgs e)
    {
        if (_shortcutCapture.IsRecording)
        {
            CancelShortcutRecording("기록을 취소했습니다.");
            return;
        }
        _shortcutCapture.Begin();
        ShortcutTextBox.Text = "기록 중...";
        ShortcutHelpText.Text = "원하는 조합을 누른 뒤 모든 키를 놓으세요. 취소하려면 취소 버튼을 누르세요.";
        RecordShortcutButton.Content = "취소";
        Focus();
    }

    private void MainWindow_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (!_shortcutCapture.IsRecording) return;
        var key = ResolveCaptureKey(e.Key, e.SystemKey, e.ImeProcessedKey);
        e.Handled = true;
        var update = _shortcutCapture.KeyDown(GetCaptureName(key));
    }

    private void MainWindow_PreviewKeyUp(object sender, KeyEventArgs e)
    {
        if (!_shortcutCapture.IsRecording) return;
        var key = ResolveCaptureKey(e.Key, e.SystemKey, e.ImeProcessedKey);
        e.Handled = true;
        var update = _shortcutCapture.KeyUp(GetCaptureName(key));
        if (update.State is ShortcutCaptureState.Completed or ShortcutCaptureState.Invalid)
            FinishShortcutRecording(update);
    }

    private void FinishShortcutRecording(ShortcutCaptureUpdate update)
    {
        if (update.State == ShortcutCaptureState.Invalid || update.Shortcut is null)
        {
            ShortcutTextBox.Text = "기록되지 않음";
            ShortcutHelpText.Text = $"기록 실패: {update.Error}";
            RecordShortcutButton.Content = "기록";
            return;
        }
        _recordedShortcut = update.Shortcut;
        _editorDirty = true;
        ShortcutTextBox.Text = ShortcutCatalog.Format(update.Shortcut);
        ShortcutHelpText.Text = "단축키가 기록되었습니다. 변경 내용 적용을 눌러 저장하세요.";
        RecordShortcutButton.Content = "기록";
    }

    private void CancelShortcutRecording(string? message)
    {
        if (!_shortcutCapture.IsRecording) return;
        _shortcutCapture.Cancel();
        ShortcutTextBox.Text = _recordedShortcut is null ? "기록되지 않음" : ShortcutCatalog.Format(_recordedShortcut);
        if (message is not null) ShortcutHelpText.Text = message;
        RecordShortcutButton.Content = "기록";
    }

    private static string GetCaptureName(Key key) => key == Key.Escape
        ? "Escape"
        : ToShortcutName(key) ?? $"Unsupported:{key}";

    internal static Key ResolveCaptureKey(Key key, Key systemKey, Key imeProcessedKey) => key switch
    {
        Key.System => systemKey,
        Key.ImeProcessed => imeProcessedKey,
        _ => key
    };

    internal static string? ToShortcutName(Key key)
    {
        if (key is >= Key.A and <= Key.Z) return key.ToString();
        if (key is >= Key.D0 and <= Key.D9) return ((int)(key - Key.D0)).ToString();
        if (key is >= Key.F1 and <= Key.F24) return key.ToString();
        if (key is >= Key.NumPad0 and <= Key.NumPad9) return $"Numpad{key - Key.NumPad0}";
        return key switch
        {
            Key.LeftCtrl => "LeftCtrl",
            Key.RightCtrl => "RightCtrl",
            Key.LeftShift => "LeftShift",
            Key.RightShift => "RightShift",
            Key.LWin => "LeftWin",
            Key.RWin => "RightWin",
            Key.LeftAlt => "LeftAlt",
            Key.RightAlt => "RightAlt",
            Key.Return => "Enter",
            Key.Space => "Space",
            Key.Tab => "Tab",
            Key.Back => "Backspace",
            Key.Delete => "Delete",
            Key.Insert => "Insert",
            Key.Home => "Home",
            Key.End => "End",
            Key.PageUp => "PageUp",
            Key.PageDown => "PageDown",
            Key.Left => "Left",
            Key.Up => "Up",
            Key.Right => "Right",
            Key.Down => "Down",
            Key.Oem3 => "Grave",
            Key.OemMinus => "Minus",
            Key.OemPlus => "Equals",
            Key.Oem4 => "LeftBracket",
            Key.Oem6 => "RightBracket",
            Key.Oem5 => "Backslash",
            Key.Oem1 => "Semicolon",
            Key.Oem7 => "Apostrophe",
            Key.OemComma => "Comma",
            Key.OemPeriod => "Period",
            Key.Oem2 => "Slash",
            Key.CapsLock => "CapsLock",
            Key.PrintScreen => "PrintScreen",
            Key.Scroll => "ScrollLock",
            Key.Pause => "Pause",
            Key.Apps => "Menu",
            Key.NumLock => "NumLock",
            Key.Divide => "NumpadDivide",
            Key.Multiply => "NumpadMultiply",
            Key.Subtract => "NumpadSubtract",
            Key.Add => "NumpadAdd",
            Key.Decimal => "NumpadDecimal",
            _ => null
        };
    }

    private void ApplySettingsToKeyTiles()
    {
        var inputs = CurrentInputs;
        for (var number = 1; number <= 12; number++)
        {
            var binding = inputs[$"key{number:00}"];
            Keys[number - 1] = new KeyTile(number, StudioSettingsCatalog.GetActionLabel(binding));
        }
        Knob1CcwButton.Content = $"↶ {StudioSettingsCatalog.GetActionLabel(inputs["knob1_ccw"])}";
        Knob1PressActionText.Text = StudioSettingsCatalog.GetActionLabel(inputs["knob1_press"]);
        Knob1CwButton.Content = $"{StudioSettingsCatalog.GetActionLabel(inputs["knob1_cw"])} ↷";
        Knob2CcwButton.Content = $"↶ {StudioSettingsCatalog.GetActionLabel(inputs["knob2_ccw"])}";
        Knob2PressActionText.Text = StudioSettingsCatalog.GetActionLabel(inputs["knob2_press"]);
        Knob2CwButton.Content = $"{StudioSettingsCatalog.GetActionLabel(inputs["knob2_cw"])} ↷";
    }

    private static string GetInputLabel(string inputId)
    {
        if (inputId.StartsWith("key", StringComparison.Ordinal) &&
            int.TryParse(inputId.AsSpan(3), out var number))
        {
            return $"KEY {number}";
        }
        return inputId switch
        {
            "knob1_ccw" => "KNOB 1 · 왼쪽 회전",
            "knob1_press" => "KNOB 1 · 누름",
            "knob1_cw" => "KNOB 1 · 오른쪽 회전",
            "knob2_ccw" => "KNOB 2 · 왼쪽 회전",
            "knob2_press" => "KNOB 2 · 누름",
            "knob2_cw" => "KNOB 2 · 오른쪽 회전",
            _ => inputId
        };
    }

    private async void StatusLedPreview_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string status })
        {
            return;
        }
        var color = status switch
        {
            "running" => _settings.StatusColors.Running,
            "approval" => _settings.StatusColors.Approval,
            "completed" => _settings.StatusColors.Completed,
            "error" => _settings.StatusColors.Error,
            _ => null
        };
        if (color is null)
        {
            return;
        }
        LedPreviewStatusText.Text = "LED 색상을 전송하고 있습니다";
        var result = await _ledCoordinator.ApplyColorAsync(color);
        if (!result.Ok)
        {
            LedPreviewStatusText.Text = $"LED 전송 실패 · {result.Error}";
            return;
        }

        LedPreviewStatusText.Text = result.Written
            ? $"{GetStatusLabel(status)} · {GetLedColorLabel(color)} 미리보기 적용 완료"
            : "같은 색이라 키보드에 다시 기록하지 않았습니다";
    }

    private async void SaveStatusColors_Click(object sender, RoutedEventArgs e)
    {
        if (RunningColorCombo.SelectedItem is not LedColorOption running ||
            ApprovalColorCombo.SelectedItem is not LedColorOption approval ||
            CompletedColorCombo.SelectedItem is not LedColorOption completed ||
            ErrorColorCombo.SelectedItem is not LedColorOption error)
        {
            StatusColorStatusText.Text = "네 상태의 색상을 모두 선택하세요";
            return;
        }

        var updated = new StudioSettings
        {
            SchemaVersion = _settings.SchemaVersion,
            Device = _settings.Device,
            Layers = _settings.Layers,
            StatusColors = new StatusColorSettings
            {
                Running = running.Id,
                Approval = approval.Id,
                Completed = completed.Id,
                Error = error.Id
            },
            KeyColors = _settings.KeyColors,
            RestoreKeyColorsAfterCodexCompletion = _settings.RestoreKeyColorsAfterCodexCompletion,
            StartWithWindows = _settings.StartWithWindows
        };
        SaveStatusColorsButton.IsEnabled = false;
        try
        {
            await _settingsStore.SaveAsync(updated);
            _settings = updated;
            UpdateStatusPreviewButtons();
            StatusColorStatusText.Text = "Codex 상태별 색상을 PC 설정에 저장했습니다";
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            StatusColorStatusText.Text = $"상태색 저장 실패 · {exception.Message}";
        }
        finally
        {
            SaveStatusColorsButton.IsEnabled = true;
        }
    }

    private void LoadStatusColorEditors()
    {
        RunningColorCombo.SelectedItem = StudioSettingsCatalog.LedColors.First(color => color.Id == _settings.StatusColors.Running);
        ApprovalColorCombo.SelectedItem = StudioSettingsCatalog.LedColors.First(color => color.Id == _settings.StatusColors.Approval);
        CompletedColorCombo.SelectedItem = StudioSettingsCatalog.LedColors.First(color => color.Id == _settings.StatusColors.Completed);
        ErrorColorCombo.SelectedItem = StudioSettingsCatalog.LedColors.First(color => color.Id == _settings.StatusColors.Error);
        UpdateStatusPreviewButtons();
    }

    private void UpdateStatusPreviewButtons()
    {
        RunningPreviewButton.Background = LedBrushes[_settings.StatusColors.Running];
        ApprovalPreviewButton.Background = LedBrushes[_settings.StatusColors.Approval];
        CompletedPreviewButton.Background = LedBrushes[_settings.StatusColors.Completed];
        ErrorPreviewButton.Background = LedBrushes[_settings.StatusColors.Error];
    }

    private void RefreshHookStatus()
    {
        var inspection = _hookInstallation.Inspect();
        HookStatusText.Text = $"{inspection.Message} · 핸들러 {inspection.HandlerCount}/7";
        UpdateRuntimeStatus(inspection.Valid);
    }

    private void InspectHooks_Click(object sender, RoutedEventArgs e) => RefreshHookStatus();

    private async void InstallHooks_Click(object sender, RoutedEventArgs e)
    {
        SetHookButtonsEnabled(false);
        HookStatusText.Text = "Codex 훅을 설치하고 검사하고 있습니다";
        try
        {
            var result = await _hookInstallation.ApplyAsync(uninstall: false);
            if (result.Ok)
            {
                RefreshHookStatus();
            }
            else
            {
                HookStatusText.Text = result.Message;
                UpdateRuntimeStatus(false);
            }
        }
        finally
        {
            SetHookButtonsEnabled(true);
        }
    }

    private async void RemoveHooks_Click(object sender, RoutedEventArgs e)
    {
        var answer = System.Windows.MessageBox.Show(
            "Keynob가 추가한 훅 7개만 제거합니다. 계속할까요?",
            "Codex 훅 제거",
            MessageBoxButton.YesNo,
            MessageBoxImage.Question);
        if (answer != MessageBoxResult.Yes)
        {
            return;
        }

        SetHookButtonsEnabled(false);
        HookStatusText.Text = "이 앱의 Codex 훅을 제거하고 있습니다";
        try
        {
            var result = await _hookInstallation.ApplyAsync(uninstall: true);
            if (result.Ok)
            {
                HookStatusText.Text = $"{result.Message} · 핸들러 0/7";
                UpdateRuntimeStatus(false);
            }
            else
            {
                HookStatusText.Text = result.Message;
                UpdateRuntimeStatus(false);
            }
        }
        finally
        {
            SetHookButtonsEnabled(true);
        }
    }

    private void SetHookButtonsEnabled(bool enabled)
    {
        InstallHooksButton.IsEnabled = enabled;
        InspectHooksButton.IsEnabled = enabled;
        RemoveHooksButton.IsEnabled = enabled;
    }

    private void UpdateRuntimeStatus(bool? hookValid = null)
    {
        var valid = hookValid ?? _hookInstallation.Inspect().Valid;
        RuntimeStatusText.Text = $"입력 엔진: {(_inputEngineRunning ? "실행" : "일시 정지/오류")} · Codex pipe: 실행 · 훅: {(valid ? "정상" : "확인 필요")}";
    }

    private void KeyLedColor_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string color } ||
            !_selectedInputId.StartsWith("key", StringComparison.Ordinal))
        {
            return;
        }

        _draftKeyColors[_selectedInputId] = color;
        _keyLedDirty = HasKeyLedDraftChanges();
        UpdateKeyLedEditorVisuals();
        UpdateKeyLedSaveButtonState();
        KeyLedStatusText.Text = _keyLedDirty
            ? $"{GetInputLabel(_selectedInputId)} · {GetLedColorLabel(color)} 선택됨 · 저장 및 적용을 누르세요"
            : "저장된 기본 색상과 같습니다";
    }

    private void RestoreKeyColorsCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        if (!_restorePolicyEditorReady)
        {
            return;
        }
        _restorePolicyDirty =
            (RestoreKeyColorsCheckBox.IsChecked == true) !=
            _settings.RestoreKeyColorsAfterCodexCompletion;
        UpdateRestorePolicySaveButtonState();
        RestorePolicyStatusText.Text = _restorePolicyDirty
            ? "키 전체 복원 설정이 변경되었습니다 · 별도로 저장해 주세요"
            : "저장된 키 전체 복원 설정과 같습니다";
    }

    private async void SaveRestorePolicy_Click(object sender, RoutedEventArgs e)
    {
        if (!_restorePolicyDirty)
        {
            return;
        }

        var restoreAfterCompletion = RestoreKeyColorsCheckBox.IsChecked == true;
        var updated = new StudioSettings
        {
            SchemaVersion = _settings.SchemaVersion,
            Device = _settings.Device,
            Layers = _settings.Layers,
            StatusColors = _settings.StatusColors,
            KeyColors = _settings.KeyColors,
            RestoreKeyColorsAfterCodexCompletion = restoreAfterCompletion,
            StartWithWindows = _settings.StartWithWindows
        };
        _restorePolicySaveInProgress = true;
        UpdateRestorePolicySaveButtonState();
        RestorePolicyStatusText.Text = "키 전체 복원 설정을 저장하고 있습니다";
        try
        {
            await _settingsStore.SaveAsync(updated);
            _settings = updated;
            _restorePolicyDirty = false;
            if (!restoreAfterCompletion)
            {
                CancelPendingCompletionRestore();
            }
            RestorePolicyStatusText.Text = restoreAfterCompletion
                ? "저장됨 · 다음 Codex 완료 3초 후 키 전체 기본 색상으로 복원합니다"
                : "저장됨 · Codex 완료색을 유지합니다";
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            RestorePolicyStatusText.Text = $"복원 설정 저장 실패 · {exception.Message}";
        }
        finally
        {
            _restorePolicySaveInProgress = false;
            UpdateRestorePolicySaveButtonState();
        }
    }

    private async void SaveKeyColors_Click(object sender, RoutedEventArgs e)
    {
        if (!_deviceConnected || !_keyLedDirty)
        {
            return;
        }

        var updatedColors = new Dictionary<string, string>(_draftKeyColors, StringComparer.Ordinal);
        var layout = BuildKeyColorLayout(updatedColors);
        var previousDeviceLayout = _ledCoordinator.LastSuccessfulColors?.ToArray();
        var statusHasPriority = IsCodexStatusOverridingBase();
        var deviceApplied = false;
        _keyLedSaveInProgress = true;
        UpdateKeyLedSaveButtonState();
        KeyLedStatusText.Text = statusHasPriority
            ? "현재 Codex 상태를 유지하면서 PC 기본 색상을 저장하고 있습니다"
            : "12키 기본 색상을 저장하고 적용하고 있습니다";

        try
        {
            CancelPendingCompletionRestore();
            LedApplyResult? deviceResult = null;
            if (!statusHasPriority)
            {
                var layer = await _deviceBridge.ReadLayerAsync(_selectedLayer);
                if (!layer.Ok)
                {
                    KeyLedStatusText.Text = $"장치 백업 전 레이어 읽기 실패 · {layer.Error}";
                    return;
                }
                var backupError = await SaveDeviceBackupAsync(_selectedLayer, layer.Slots);
                if (backupError is not null)
                {
                    KeyLedStatusText.Text = $"장치 백업 실패 · LED 적용을 중단했습니다 · {backupError}";
                    return;
                }
                deviceResult = await _ledCoordinator.ApplyLayoutAsync(layout);
                if (!deviceResult.Ok)
                {
                    KeyLedStatusText.Text = $"기본 색상 전송 실패 · {deviceResult.Error}";
                    return;
                }
                deviceApplied = true;
            }

            var updated = new StudioSettings
            {
                SchemaVersion = _settings.SchemaVersion,
                Device = _settings.Device,
                Layers = _settings.Layers,
                StatusColors = _settings.StatusColors,
                KeyColors = updatedColors,
                RestoreKeyColorsAfterCodexCompletion = _settings.RestoreKeyColorsAfterCodexCompletion,
                StartWithWindows = _settings.StartWithWindows
            };
            try
            {
                await _settingsStore.SaveAsync(updated);
            }
            catch
            {
                if (deviceApplied && previousDeviceLayout is not null)
                {
                    _ = await _ledCoordinator.ApplyLayoutAsync(previousDeviceLayout);
                }
                throw;
            }

            _settings = updated;
            _draftKeyColors = new Dictionary<string, string>(updatedColors, StringComparer.Ordinal);
            _keyLedDirty = false;
            UpdateKeyLedEditorVisuals();
            KeyLedStatusText.Text = statusHasPriority
                ? "기본 색상을 저장했습니다 · 현재 Codex 상태가 장치 표시를 유지합니다"
                : deviceResult?.Written == true
                    ? "12키 기본 색상을 장치와 PC 설정에 저장했습니다"
                    : "장치 값이 같아 다시 쓰지 않고 기본 설정만 확인했습니다";
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            KeyLedStatusText.Text = $"기본 색상 저장 실패 · {exception.Message}";
        }
        finally
        {
            _keyLedSaveInProgress = false;
            KeyLedEditorPanel.IsEnabled = _deviceConnected &&
                _selectedInputId.StartsWith("key", StringComparison.Ordinal);
            UpdateKeyLedSaveButtonState();
        }
    }

    private void UpdateKeyLedEditorVisuals()
    {
        if (!_selectedInputId.StartsWith("key", StringComparison.Ordinal) ||
            !_draftKeyColors.TryGetValue(_selectedInputId, out var selectedColor))
        {
            KeyLedSelectedColorText.Text = "노브에는 기본 LED 색상이 없습니다";
            return;
        }

        foreach (var button in KeyLedPalette.Children.OfType<Button>())
        {
            var selected = button.Tag is string color &&
                string.Equals(color, selectedColor, StringComparison.Ordinal);
            button.BorderBrush = SelectedColorBrush;
            button.BorderThickness = selected ? new Thickness(3) : new Thickness(0);
            button.Opacity = selected ? 1 : 0.72;
        }
        KeyLedSelectedColorText.Text = $"선택된 기본 색상 · {GetLedColorLabel(selectedColor)}";
    }

    private bool HasKeyLedDraftChanges() =>
        _draftKeyColors.Count != _settings.KeyColors.Count ||
        _draftKeyColors.Any(pair => !_settings.KeyColors.TryGetValue(pair.Key, out var saved) ||
            !string.Equals(pair.Value, saved, StringComparison.Ordinal));

    private void UpdateKeyLedSaveButtonState()
    {
        SaveKeyColorsButton.IsEnabled = _deviceConnected && _keyLedDirty && !_keyLedSaveInProgress;
    }

    private void UpdateRestorePolicySaveButtonState()
    {
        SaveRestorePolicyButton.IsEnabled = _restorePolicyDirty && !_restorePolicySaveInProgress;
    }

    private static string[] BuildKeyColorLayout(IReadOnlyDictionary<string, string> colors) =>
        Enumerable.Range(1, 12).Select(number => colors[$"key{number:00}"]).ToArray();

    private async Task HandleCodexHookEventAsync(CodexHookEvent hookEvent)
    {
        var sourceDecision = _codexSourcePolicy.Evaluate(hookEvent);
        if (!sourceDecision.Accepted)
        {
            _lastIgnoredCodexSource = $"{GetCodexSourceLabel(hookEvent.SourceKind)} ({sourceDecision.Reason})";
            _diagnosticLog.Write(
                "codex_source_ignored",
                $"source={hookEvent.SourceKind};event={hookEvent.EventName};reason={sourceDecision.Reason}");
            _ = Dispatcher.BeginInvoke(UpdateCodexSourceStatusText);
            return;
        }
        if (string.Equals(hookEvent.EventName, "InstanceEnd", StringComparison.Ordinal))
        {
            _launcherLifetime.Complete(hookEvent.SourceKind, hookEvent.InstanceId);
        }
        var aggregate = _codexStatus.Apply(hookEvent, DateTimeOffset.UtcNow);
        await ApplyCodexAggregateAsync(aggregate);
    }

    private async Task HandleProducerExitFallbackAsync(string sourceKind, string instanceId)
    {
        var aggregate = _codexStatus.Apply(new CodexHookEvent(
            "InstanceEnd",
            null,
            null,
            instanceId,
            IsError: false,
            SourceKind: sourceKind), DateTimeOffset.UtcNow);
        await ApplyCodexAggregateAsync(aggregate);
    }

    private async Task HandleCodexCancellationAsync(CodexCancellationRequest request)
    {
        var candidate = _codexStatus.BeginCancellation(request.InstanceId, DateTimeOffset.UtcNow);
        if (candidate is null)
        {
            _diagnosticLog.Write(
                "codex_cancel_ignored",
                $"gesture={request.Gesture};instance={request.InstanceId};reason=no_active_turn");
            return;
        }
        _diagnosticLog.Write(
            "codex_cancel_pending",
            $"gesture={request.Gesture};instance={request.InstanceId};session={candidate.SessionId};turn={candidate.TurnId}");

        await Task.Delay(CodexCancellationGracePeriod);
        var aggregate = _codexStatus.CompleteCancellation(candidate, DateTimeOffset.UtcNow);
        if (aggregate.ActivityChanged)
        {
            _diagnosticLog.Write(
                "codex_cancel_applied",
                $"instance={candidate.InstanceId};session={candidate.SessionId};turn={candidate.TurnId};activeSessions={aggregate.ActiveSessionCount}");
        }
        await ApplyCodexAggregateAsync(aggregate);
    }

    private async Task ApplyCodexAggregateAsync(
        CodexAggregateResult aggregate,
        bool isStartupOrUsbConnection = false)
    {
        if (!aggregate.ActivityChanged || aggregate.Status is null)
        {
            return;
        }
        CancelPendingCompletionRestore();
        _lastCodexActiveSessionCount = aggregate.ActiveSessionCount;
        _lastCodexActiveSourceSummary = aggregate.ActiveSourceSummary;
        _diagnosticLog.Write(
            "codex_status_changed",
            $"status={aggregate.Status};activeSessions={aggregate.ActiveSessionCount};sources={aggregate.ActiveSourceSummary}");

        var color = GetCodexStatusColor(aggregate.Status);
        if (color is null)
        {
            return;
        }

        var plan = LedDisplayPolicy.Decide(
            aggregate.Status,
            aggregate.ActiveSessionCount,
            _settings.RestoreKeyColorsAfterCodexCompletion,
            isStartupOrUsbConnection);
        LedApplyResult? led = null;
        if (aggregate.Changed)
        {
            if (plan.ImmediateTarget == LedDisplayTarget.BaseLayout)
            {
                led = await ApplyBaseKeyColorsAsync("startup_or_usb");
            }
            else
            {
                led = await _ledCoordinator.ApplyColorAsync(color);
                _diagnosticLog.Write(
                    led.Ok ? "codex_led_applied" : "codex_led_failed",
                    $"status={aggregate.Status};written={led.Written}");
            }
        }
        if (plan.RestoreBaseAfterDelay && (led is null || led.Ok))
        {
            ScheduleBaseRestoreAfterCompletion();
        }

        _ = Dispatcher.BeginInvoke(() =>
        {
            if (led is null || led.Ok)
            {
                LedPreviewStatusText.Text = plan.ImmediateTarget == LedDisplayTarget.BaseLayout
                    ? "Codex 활성 없음 · KEY별 기본 색상 표시"
                    : $"Codex {GetStatusLabel(aggregate.Status)} · {GetLedColorLabel(color)} · 활성 {aggregate.ActiveSessionCount}개 · {GetCodexSourceSummaryLabel(aggregate.ActiveSourceSummary)}";
            }
            else
            {
                LedPreviewStatusText.Text = $"Codex 상태 LED 실패 · {led.Error}";
            }
            UpdateCodexSourceStatusText();
        });
    }

    private async Task ApplyLedPolicyForUsbConnectionAsync()
    {
        CancelPendingCompletionRestore();
        var status = _codexStatus.CurrentStatus;
        var plan = LedDisplayPolicy.Decide(
            status,
            _lastCodexActiveSessionCount,
            _settings.RestoreKeyColorsAfterCodexCompletion,
            isStartupOrUsbConnection: true);
        if (plan.ImmediateTarget == LedDisplayTarget.BaseLayout || status is null)
        {
            _ = await ApplyBaseKeyColorsAsync("usb_connected");
            return;
        }

        var color = GetCodexStatusColor(status);
        if (color is null)
        {
            return;
        }
        var led = await _ledCoordinator.ApplyColorAsync(color);
        _diagnosticLog.Write(
            led.Ok ? "codex_led_reapplied" : "codex_led_failed",
            $"status={status};trigger=usb_connected;written={led.Written}");
    }

    private async Task<LedApplyResult> ApplyBaseKeyColorsAsync(
        string trigger,
        CancellationToken cancellationToken = default)
    {
        var led = await _ledCoordinator.ApplyLayoutAsync(
            BuildKeyColorLayout(_settings.KeyColors),
            cancellationToken);
        _diagnosticLog.Write(
            led.Ok ? "codex_led_base_restored" : "codex_led_base_restore_failed",
            $"trigger={trigger};written={led.Written}");
        _ = Dispatcher.BeginInvoke(() =>
        {
            LedPreviewStatusText.Text = led.Ok
                ? "KEY별 기본 색상 표시"
                : $"기본 색상 적용 실패 · {led.Error}";
        });
        return led;
    }

    private void ScheduleBaseRestoreAfterCompletion()
    {
        var cancellation = new CancellationTokenSource();
        var previous = Interlocked.Exchange(ref _completionRestoreCancellation, cancellation);
        previous?.Cancel();
        previous?.Dispose();
        _ = RestoreBaseAfterCompletionAsync(cancellation);
    }

    private async Task RestoreBaseAfterCompletionAsync(CancellationTokenSource cancellation)
    {
        try
        {
            await Task.Delay(CodexCompletionColorDuration, cancellation.Token);
            if (cancellation.IsCancellationRequested ||
                !_settings.RestoreKeyColorsAfterCodexCompletion ||
                _lastCodexActiveSessionCount != 0 ||
                !string.Equals(_codexStatus.CurrentStatus, "completed", StringComparison.Ordinal) ||
                !_deviceConnected)
            {
                return;
            }
            var led = await ApplyBaseKeyColorsAsync("completion_delay", cancellation.Token);
            _ = Dispatcher.BeginInvoke(() =>
            {
                if (led.Ok)
                {
                    LedPreviewStatusText.Text = "Codex 완료 · KEY별 기본 색상으로 복원됨";
                }
            });
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        finally
        {
            if (ReferenceEquals(
                Interlocked.CompareExchange(ref _completionRestoreCancellation, null, cancellation),
                cancellation))
            {
                cancellation.Dispose();
            }
        }
    }

    private void CancelPendingCompletionRestore()
    {
        var cancellation = Interlocked.Exchange(ref _completionRestoreCancellation, null);
        cancellation?.Cancel();
        cancellation?.Dispose();
    }

    private bool IsCodexStatusOverridingBase() =>
        _lastCodexActiveSessionCount > 0 ||
        _codexStatus.CurrentStatus is "running" or "approval" or "error";

    private string? GetCodexStatusColor(string status) => status switch
    {
        "running" => _settings.StatusColors.Running,
        "approval" => _settings.StatusColors.Approval,
        "completed" => _settings.StatusColors.Completed,
        "error" => _settings.StatusColors.Error,
        _ => null
    };

    private void UpdateCodexSourceStatusText()
    {
        var active = _lastCodexActiveSessionCount == 0
            ? "활성 없음"
            : $"활성 {_lastCodexActiveSessionCount}개 · {GetCodexSourceSummaryLabel(_lastCodexActiveSourceSummary)}";
        CodexSourceStatusText.Text = $"LED 범위: 전용 CLI·JSON 실행만 · 현재 {active} · 최근 제외 {_lastIgnoredCodexSource}";
    }

    private static string GetCodexSourceSummaryLabel(string summary) => summary == "none"
        ? "없음"
        : string.Join(" · ", summary.Split(',', StringSplitOptions.RemoveEmptyEntries).Select(entry =>
        {
            var parts = entry.Split(':', 2);
            return parts.Length == 2
                ? $"{GetCodexSourceLabel(parts[0])} {parts[1]}개"
                : GetCodexSourceLabel(entry);
        }));

    private static string GetCodexSourceLabel(string sourceKind) => sourceKind switch
    {
        CodexStatusSourceKinds.DedicatedCli => "전용 CLI",
        CodexStatusSourceKinds.JsonExec => "JSON 실행",
        CodexStatusSourceKinds.ManualTest => "수동 시험",
        CodexStatusSourceKinds.Unscoped => "출처 미확인",
        _ => "지원하지 않는 출처"
    };

    private static string GetStatusLabel(string status) => status switch
    {
        "running" => "실행 중",
        "approval" => "승인 대기",
        "completed" => "완료",
        "error" => "오류",
        _ => status
    };

    private static string GetLedColorLabel(string color) => color switch
    {
        "blue" => "파란색",
        "yellow" => "노란색",
        "green" => "초록색",
        "red" => "빨간색",
        "orange" => "주황색",
        "cyan" => "청록색",
        "purple" => "보라색",
        "pink" => "분홍색",
        _ => color
    };

}

public sealed record KeyTile(int Number, string ActionLabel)
{
    public string NumberLabel => $"KEY {Number:00}";
}
