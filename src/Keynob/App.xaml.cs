using System.ComponentModel;
using System.Drawing;
using System.Windows;
using Keynob.Services;
using Forms = System.Windows.Forms;

namespace Keynob;

public partial class App : System.Windows.Application
{
    private readonly DiagnosticLog _diagnosticLog = new();
    private SingleInstanceService? _singleInstance;
    private Forms.NotifyIcon? _trayIcon;
    private Forms.ToolStripMenuItem? _pauseMenuItem;
    private Forms.ToolStripMenuItem? _startupMenuItem;
    private MainWindow? _mainWindow;
    private bool _isExiting;

    public App()
    {
        _diagnosticLog.Write("app_constructed", "ok");
        DispatcherUnhandledException += (_, args) =>
        {
            _diagnosticLog.Write("app_dispatcher_error", args.Exception.ToString());
        };
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            _diagnosticLog.Write("app_domain_error", args.ExceptionObject?.ToString() ?? "unknown");
        };
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        _diagnosticLog.Write("app_starting", $"background={e.Args.Contains("--background", StringComparer.OrdinalIgnoreCase)}");
        base.OnStartup(e);
        _singleInstance = new SingleInstanceService();
        _diagnosticLog.Write("app_instance_checked", $"primary={_singleInstance.IsPrimary}");
        if (!_singleInstance.IsPrimary)
        {
            if (e.Args.Contains("--exit", StringComparer.OrdinalIgnoreCase))
            {
                _singleInstance.SignalExit();
            }
            else if (!e.Args.Contains("--background", StringComparer.OrdinalIgnoreCase))
            {
                _singleInstance.SignalPrimary();
            }
            _singleInstance.Dispose();
            _singleInstance = null;
            Shutdown();
            return;
        }
        if (e.Args.Contains("--exit", StringComparer.OrdinalIgnoreCase))
        {
            _singleInstance.Dispose();
            _singleInstance = null;
            Shutdown();
            return;
        }

        _mainWindow = new MainWindow();
        _diagnosticLog.Write("app_window_created", "ok");
        _mainWindow.StartWithWindowsStateChanged += enabled =>
        {
            if (_startupMenuItem is not null)
            {
                _startupMenuItem.Checked = enabled;
            }
        };
        _mainWindow.Closing += MainWindow_Closing;
        CreateTrayIcon();
        _diagnosticLog.Write("app_tray_created", "ok");
        _singleInstance.Listen(Dispatcher, ShowMainWindow, ExitApplication);
        if (e.Args.Contains("--background", StringComparer.OrdinalIgnoreCase))
        {
            _mainWindow.Loaded += (_, _) => _mainWindow.Hide();
        }
        _mainWindow.Show();
        _diagnosticLog.Write("app_window_shown", "ok");
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _trayIcon?.Dispose();
        _singleInstance?.Dispose();
        base.OnExit(e);
    }

    private void MainWindow_Closing(object? sender, CancelEventArgs e)
    {
        if (_isExiting)
        {
            return;
        }
        e.Cancel = true;
        _mainWindow?.Hide();
        _trayIcon?.ShowBalloonTip(
            1200,
            "Keynob",
            "키보드 제어는 알림 영역에서 계속 실행됩니다.",
            Forms.ToolTipIcon.Info);
    }

    private void CreateTrayIcon()
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("설정 열기", null, (_, _) => Dispatcher.Invoke(ShowMainWindow));
        _pauseMenuItem = new Forms.ToolStripMenuItem("키 입력 일시 정지");
        _pauseMenuItem.Click += (_, _) => Dispatcher.Invoke(ToggleInputPause);
        menu.Items.Add(_pauseMenuItem);
        _startupMenuItem = new Forms.ToolStripMenuItem("Windows 로그인 시 자동 시작");
        _startupMenuItem.Click += async (_, _) => await Dispatcher.InvokeAsync(ToggleStartupAsync);
        menu.Items.Add(_startupMenuItem);
        menu.Items.Add("진단 폴더 열기", null, (_, _) => Dispatcher.Invoke(() => _mainWindow?.OpenDiagnostics()));
        menu.Items.Add("진단 로그 초기화", null, (_, _) => Dispatcher.Invoke(() => _mainWindow?.ClearDiagnostics()));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("종료", null, (_, _) => Dispatcher.Invoke(ExitApplication));

        _trayIcon = new Forms.NotifyIcon
        {
            Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath ?? string.Empty) ?? SystemIcons.Application,
            Text = "Keynob",
            ContextMenuStrip = menu,
            Visible = true
        };
        _trayIcon.DoubleClick += (_, _) => Dispatcher.Invoke(ShowMainWindow);
    }

    private void ShowMainWindow()
    {
        if (_mainWindow is null)
        {
            return;
        }
        _mainWindow.Show();
        if (_mainWindow.WindowState == WindowState.Minimized)
        {
            _mainWindow.WindowState = WindowState.Normal;
        }
        _mainWindow.Activate();
        _mainWindow.Topmost = true;
        _mainWindow.Topmost = false;
        _mainWindow.Focus();
    }

    private void ToggleInputPause()
    {
        if (_mainWindow is null || _pauseMenuItem is null)
        {
            return;
        }
        var paused = _mainWindow.ToggleInputPause();
        _pauseMenuItem.Checked = paused;
        _pauseMenuItem.Text = paused ? "키 입력 다시 시작" : "키 입력 일시 정지";
        _trayIcon!.Text = paused ? "Keynob (일시 정지)" : "Keynob";
    }

    private async void ExitApplication()
    {
        if (_isExiting)
        {
            return;
        }
        _isExiting = true;
        if (_mainWindow is not null)
        {
            await _mainWindow.ShutdownServicesAsync();
        }
        _mainWindow?.Close();
        Shutdown();
    }

    private async Task ToggleStartupAsync()
    {
        if (_mainWindow is null || _startupMenuItem is null)
        {
            return;
        }
        try
        {
            _startupMenuItem.Checked = await _mainWindow.ToggleStartWithWindowsAsync();
        }
        catch (Exception exception)
        {
            System.Windows.MessageBox.Show(
                $"자동 시작 설정에 실패했습니다.\n{exception.Message}",
                "Keynob",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }
}
