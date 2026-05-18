using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Vibestick.Core;
using Application = System.Windows.Application;
using Button = System.Windows.Controls.Button;
using Brushes = System.Windows.Media.Brushes;
using Color = System.Windows.Media.Color;
using ColorConverter = System.Windows.Media.ColorConverter;
using Drawing = System.Drawing;
using FontFamily = System.Windows.Media.FontFamily;
using Forms = System.Windows.Forms;
using ListBox = System.Windows.Controls.ListBox;
using MessageBox = System.Windows.MessageBox;
using Panel = System.Windows.Controls.Panel;
using TextBox = System.Windows.Controls.TextBox;

namespace Vibestick.Gui;

public sealed class App : Application
{
    private readonly string[] _args;
    private GuiServices? _services;
    private GuiRuntimeState? _runtimeState;
    private PetWindow? _petWindow;
    private MainWindow? _mainWindow;
    private Forms.NotifyIcon? _notifyIcon;
    private string? _placementPath;

    public App(string[] args)
    {
        _args = args;
    }

    [STAThread]
    public static int Main(string[] args)
    {
        var app = new App(args);
        return app.Run();
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        var statusDirectory = GetOption(_args, "--status-dir") ??
            Environment.GetEnvironmentVariable("VIBESTICK_CODER_STATUS_DIR");
        _placementPath = GetOption(_args, "--placement-path");
        _services = GuiServiceFactory.Create(statusDirectory);
        _runtimeState = new GuiRuntimeState();

        CreateTrayIcon();

        if (HasFlag(_args, "--panel"))
        {
            ShowControlPanel();
        }
        else
        {
            ShowPet();
        }

        if (HasFlag(_args, "--smoke"))
        {
            var smokeTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
            smokeTimer.Tick += (_, _) =>
            {
                smokeTimer.Stop();
                Shutdown(0);
            };
            smokeTimer.Start();
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _notifyIcon?.Dispose();
        base.OnExit(e);
    }

    private void ShowPet()
    {
        if (_services is null || _runtimeState is null)
        {
            return;
        }

        if (_petWindow is { IsVisible: true })
        {
            _petWindow.Activate();
            return;
        }

        _petWindow = new PetWindow(
            _services,
            _runtimeState,
            ShowControlPanel,
            () => Shutdown(0),
            new PetWindowStateStore(_placementPath));
        _petWindow.Show();
    }

    private void ShowControlPanel()
    {
        if (_services is null || _runtimeState is null)
        {
            return;
        }

        if (_mainWindow is { IsVisible: true })
        {
            _mainWindow.Activate();
            return;
        }

        _mainWindow = new MainWindow(_services, _runtimeState);
        _mainWindow.Closed += (_, _) => _mainWindow = null;
        _mainWindow.Show();
    }

    private void CreateTrayIcon()
    {
        _notifyIcon = new Forms.NotifyIcon
        {
            Icon = Drawing.SystemIcons.Application,
            Text = "Vibestick",
            Visible = true,
            ContextMenuStrip = new Forms.ContextMenuStrip()
        };

        _notifyIcon.ContextMenuStrip.Items.Add("Open Control Panel", null, (_, _) => Dispatcher.Invoke(ShowControlPanel));
        _notifyIcon.ContextMenuStrip.Items.Add("Show Pet", null, (_, _) => Dispatcher.Invoke(ShowPet));
        _notifyIcon.ContextMenuStrip.Items.Add("Exit Vibestick", null, (_, _) => Dispatcher.Invoke(() => Shutdown(0)));
        _notifyIcon.DoubleClick += (_, _) => Dispatcher.Invoke(ShowControlPanel);
    }

    private static bool HasFlag(string[] args, string flag)
    {
        return args.Any(arg => string.Equals(arg, flag, StringComparison.OrdinalIgnoreCase));
    }

    private static string? GetOption(string[] args, string option)
    {
        for (var index = 0; index < args.Length - 1; index++)
        {
            if (string.Equals(args[index], option, StringComparison.OrdinalIgnoreCase))
            {
                return args[index + 1];
            }
        }

        return null;
    }
}

public sealed class MainWindow : Window
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };

    private readonly GuiServices _services;
    private readonly GuiRuntimeState _runtimeState;
    private readonly DispatcherTimer _hyperTimer;
    private IDisposable? _sleepBlock;

    private readonly TextBlock _modeText = new();
    private readonly TextBlock _restoreText = new();
    private readonly TextBlock _lidText = new();
    private readonly TextBlock _batteryText = new();
    private readonly TextBlock _schemeText = new();
    private readonly TextBlock _tasksText = new();
    private readonly TextBlock _guardText = new();
    private readonly TextBox _outputBox = new();
    private readonly ListBox _diagnosticsList = new();
    private readonly Button _refreshButton = new();
    private readonly Button _doctorButton = new();
    private readonly Button _onButton = new();
    private readonly Button _hyperButton = new();
    private readonly Button _stopHyperButton = new();
    private readonly Button _revertButton = new();

    public MainWindow(GuiServices services, GuiRuntimeState runtimeState)
    {
        _services = services;
        _runtimeState = runtimeState;
        _hyperTimer = new DispatcherTimer
        {
            Interval = _services.Options.HyperGuardInterval
        };
        _hyperTimer.Tick += async (_, _) => await CheckHyperGuardAsync().ConfigureAwait(true);

        Title = "Vibestick";
        Width = 980;
        Height = 720;
        MinWidth = 760;
        MinHeight = 560;
        Background = Brush("#f7f8fb");
        FontFamily = new FontFamily("Segoe UI");

        Content = BuildLayout();
        Loaded += async (_, _) => await RefreshStatusAsync("Ready.").ConfigureAwait(true);
        Closed += async (_, _) => await ReleaseHyperGuardAsync(updateState: false).ConfigureAwait(true);
    }

    private UIElement BuildLayout()
    {
        var root = new Grid
        {
            Margin = new Thickness(24)
        };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var title = new TextBlock
        {
            Text = "Vibestick",
            FontSize = 28,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brush("#172033")
        };
        root.Children.Add(title);

        var subtitle = new TextBlock
        {
            Text = "Windows sleep-policy control panel",
            Margin = new Thickness(0, 36, 0, 0),
            Foreground = Brush("#5f687a"),
            FontSize = 13
        };
        root.Children.Add(subtitle);

        var summary = new Grid
        {
            Margin = new Thickness(0, 28, 0, 0)
        };
        summary.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        summary.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        summary.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        summary.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        summary.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(summary, 1);
        root.Children.Add(summary);

        AddMetric(summary, 0, 0, "Mode", _modeText);
        AddMetric(summary, 0, 1, "Lid Close", _lidText);
        AddMetric(summary, 1, 0, "Battery", _batteryText);
        AddMetric(summary, 1, 1, "Power Scheme", _schemeText);
        AddMetric(summary, 2, 0, "Restore Pending", _restoreText);
        AddMetric(summary, 2, 1, "HYPER Guard", _guardText);

        var tasksBand = new Border
        {
            Margin = new Thickness(0, 16, 0, 0),
            Padding = new Thickness(14),
            Background = Brushes.White,
            BorderBrush = Brush("#e1e5ee"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Child = Stack("Running Tasks", _tasksText)
        };
        Grid.SetRow(tasksBand, 2);
        root.Children.Add(tasksBand);

        var body = new Grid
        {
            Margin = new Thickness(0, 18, 0, 0)
        };
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(250) });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(body, 3);
        root.Children.Add(body);

        var controls = new StackPanel();
        AddActionButton(controls, _refreshButton, "Refresh Status", async () => await RefreshStatusAsync("Status refreshed.").ConfigureAwait(true));
        AddActionButton(controls, _doctorButton, "Run Doctor", RunDoctorAsync);
        AddActionButton(controls, _onButton, "Mode ON", async () => await ApplyModeAsync(VibestickMode.On, startGuard: false).ConfigureAwait(true));
        AddActionButton(controls, _hyperButton, "Mode HYPER", async () => await ApplyModeAsync(VibestickMode.Hyper, startGuard: true).ConfigureAwait(true), isPrimary: true);
        AddActionButton(controls, _stopHyperButton, "Stop HYPER Guard", async () => await ReleaseHyperGuardAsync(updateState: true).ConfigureAwait(true));
        AddActionButton(controls, _revertButton, "OFF / Revert", RevertAsync);

        var controlsPanel = new Border
        {
            Padding = new Thickness(14),
            Background = Brushes.White,
            BorderBrush = Brush("#e1e5ee"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Child = controls
        };
        body.Children.Add(controlsPanel);

        var outputGrid = new Grid();
        outputGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(170) });
        outputGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(14) });
        outputGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(outputGrid, 2);
        body.Children.Add(outputGrid);

        _diagnosticsList.Background = Brushes.White;
        _diagnosticsList.BorderBrush = Brush("#e1e5ee");
        _diagnosticsList.BorderThickness = new Thickness(1);
        _diagnosticsList.Padding = new Thickness(8);
        outputGrid.Children.Add(_diagnosticsList);

        _outputBox.FontFamily = new FontFamily("Consolas");
        _outputBox.FontSize = 12;
        _outputBox.IsReadOnly = true;
        _outputBox.AcceptsReturn = true;
        _outputBox.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        _outputBox.HorizontalScrollBarVisibility = ScrollBarVisibility.Auto;
        _outputBox.TextWrapping = TextWrapping.NoWrap;
        _outputBox.Background = Brush("#111827");
        _outputBox.Foreground = Brush("#e5e7eb");
        _outputBox.BorderBrush = Brush("#111827");
        _outputBox.Padding = new Thickness(12);
        Grid.SetRow(_outputBox, 2);
        outputGrid.Children.Add(_outputBox);

        SetGuardUi();
        return root;
    }

    private static void AddMetric(Grid grid, int row, int column, string label, TextBlock value)
    {
        var panel = Stack(label, value);
        panel.Margin = new Thickness(column == 0 ? 0 : 10, row == 0 ? 0 : 10, column == 0 ? 10 : 0, 0);
        Grid.SetRow(panel, row);
        Grid.SetColumn(panel, column);
        grid.Children.Add(panel);
    }

    private static Border Stack(string label, TextBlock value)
    {
        value.FontSize = 16;
        value.FontWeight = FontWeights.SemiBold;
        value.Foreground = Brush("#172033");
        value.TextWrapping = TextWrapping.Wrap;

        var labelBlock = new TextBlock
        {
            Text = label,
            FontSize = 12,
            Foreground = Brush("#697386"),
            Margin = new Thickness(0, 0, 0, 4)
        };

        return new Border
        {
            Padding = new Thickness(14),
            Background = Brushes.White,
            BorderBrush = Brush("#e1e5ee"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Child = new StackPanel
            {
                Children =
                {
                    labelBlock,
                    value
                }
            }
        };
    }

    private static void AddActionButton(
        Panel panel,
        Button button,
        string text,
        Func<Task> action,
        bool isPrimary = false)
    {
        button.Content = text;
        button.Height = 38;
        button.Margin = new Thickness(0, 0, 0, 10);
        button.FontWeight = FontWeights.SemiBold;
        button.Background = isPrimary ? Brush("#6d5dfc") : Brush("#eef2ff");
        button.Foreground = isPrimary ? Brushes.White : Brush("#29324a");
        button.BorderBrush = isPrimary ? Brush("#6d5dfc") : Brush("#cdd6f6");
        button.BorderThickness = new Thickness(1);
        button.Cursor = System.Windows.Input.Cursors.Hand;
        button.Click += async (_, _) => await action().ConfigureAwait(true);
        panel.Children.Add(button);
    }

    private async Task RefreshStatusAsync(string? message = null)
    {
        await RunBusyAsync(async () =>
        {
            var status = await _services.Engine.GetStatusAsync().ConfigureAwait(true);
            RenderStatus(status);
            if (message is not null)
            {
                WriteOutput(message, status);
            }
        }).ConfigureAwait(true);
    }

    private async Task RunDoctorAsync()
    {
        await RunBusyAsync(async () =>
        {
            var report = await _services.Doctor.RunAsync().ConfigureAwait(true);
            _diagnosticsList.Items.Clear();
            foreach (var check in report.Checks)
            {
                _diagnosticsList.Items.Add($"{(check.Passed ? "OK " : "ERR")} {check.Name}: {check.Message}");
            }

            WriteOutput(report.IsHealthy ? "Doctor passed." : "Doctor found issues.", report);
            await RefreshStatusAsync().ConfigureAwait(true);
        }).ConfigureAwait(true);
    }

    private async Task ApplyModeAsync(VibestickMode mode, bool startGuard)
    {
        await RunBusyAsync(async () =>
        {
            var result = await _services.Engine.ApplyModeAsync(mode).ConfigureAwait(true);
            WriteOutput(result.Message, result);

            if (startGuard && result.AppliedMode == VibestickMode.Hyper)
            {
                StartHyperGuard();
            }
            else if (result.AppliedMode != VibestickMode.Hyper)
            {
                StopHyperGuardOnly();
            }

            await RefreshStatusAsync().ConfigureAwait(true);
        }).ConfigureAwait(true);
    }

    private async Task RevertAsync()
    {
        await RunBusyAsync(async () =>
        {
            StopHyperGuardOnly();
            var result = await _services.Engine.RevertAsync().ConfigureAwait(true);
            WriteOutput(result.Message, result);
            await RefreshStatusAsync().ConfigureAwait(true);
        }).ConfigureAwait(true);
    }

    private void StartHyperGuard()
    {
        StopHyperGuardOnly();
        _sleepBlock = _services.SleepBlocker.BlockSystemSleep();
        _runtimeState.IsHyperGuardRunning = true;
        _hyperTimer.Start();
        SetGuardUi();
        AppendLog("HYPER guard started. Idle system sleep is blocked while this window stays open.");
    }

    private async Task ReleaseHyperGuardAsync(bool updateState)
    {
        StopHyperGuardOnly();
        if (updateState)
        {
            var result = await _services.Engine.ApplyModeAsync(VibestickMode.On).ConfigureAwait(true);
            WriteOutput("HYPER guard stopped. Mode state downgraded to ON.", result);
            await RefreshStatusAsync().ConfigureAwait(true);
        }
    }

    private void StopHyperGuardOnly()
    {
        _hyperTimer.Stop();
        _sleepBlock?.Dispose();
        _sleepBlock = null;
        _runtimeState.IsHyperGuardRunning = false;
        SetGuardUi();
    }

    private async Task CheckHyperGuardAsync()
    {
        if (_sleepBlock is null)
        {
            return;
        }

        var decision = new BatterySafetyPolicy(_services.Options).Evaluate(_services.BatteryMonitor.GetBatteryInfo());
        if (decision.Action == SafetyAction.RestoreNormalSleep)
        {
            AppendLog(decision.Message);
            StopHyperGuardOnly();
            await _services.Engine.RevertAsync().ConfigureAwait(true);
            await RefreshStatusAsync("Critical battery action applied.").ConfigureAwait(true);
            return;
        }

        if (decision.Action == SafetyAction.DowngradeToOn)
        {
            AppendLog(decision.Message);
            StopHyperGuardOnly();
            await _services.Engine.ApplyModeAsync(VibestickMode.On).ConfigureAwait(true);
            await RefreshStatusAsync("Battery safety downgraded HYPER to ON.").ConfigureAwait(true);
            return;
        }

        if (decision.Action == SafetyAction.Warn)
        {
            AppendLog(decision.Message);
        }

        await RefreshStatusAsync().ConfigureAwait(true);
    }

    private void RenderStatus(VibestickStatus status)
    {
        _modeText.Text = status.ActiveMode.ToString();
        _restoreText.Text = status.RestorePending ? "Yes" : "No";
        _lidText.Text = FormatPolicy(status.CurrentPolicy);
        _batteryText.Text = FormatBattery(status.Battery);
        _schemeText.Text = status.CurrentSchemeGuid ?? "-";
        _tasksText.Text = status.LongTasks.Count == 0
            ? "No whitelisted long-running tasks detected."
            : string.Join(", ", status.LongTasks.Select(static task => task.ProcessId.HasValue ? $"{task.Name} ({task.ProcessId})" : task.Name));

        if (status.Warnings.Count > 0)
        {
            _diagnosticsList.Items.Clear();
            foreach (var warning in status.Warnings)
            {
                _diagnosticsList.Items.Add($"WARN {warning}");
            }
        }

        SetGuardUi();
    }

    private async Task RunBusyAsync(Func<Task> action)
    {
        SetButtonsEnabled(false);
        try
        {
            await action().ConfigureAwait(true);
        }
        catch (Exception exception)
        {
            AppendLog($"Error: {exception.Message}");
            MessageBox.Show(this, exception.Message, "Vibestick", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            SetButtonsEnabled(true);
            SetGuardUi();
        }
    }

    private void SetButtonsEnabled(bool enabled)
    {
        foreach (var button in new[] { _refreshButton, _doctorButton, _onButton, _hyperButton, _revertButton })
        {
            button.IsEnabled = enabled;
        }
    }

    private void SetGuardUi()
    {
        var running = _sleepBlock is not null;
        _guardText.Text = running ? "Running" : "Stopped";
        _stopHyperButton.IsEnabled = running;
    }

    private void WriteOutput<T>(string message, T value)
    {
        _outputBox.Text = $"{DateTime.Now:HH:mm:ss} {message}{Environment.NewLine}{JsonSerializer.Serialize(value, JsonOptions)}";
    }

    private void AppendLog(string message)
    {
        var line = $"{DateTime.Now:HH:mm:ss} {message}";
        _outputBox.Text = string.IsNullOrWhiteSpace(_outputBox.Text)
            ? line
            : $"{line}{Environment.NewLine}{_outputBox.Text}";
    }

    private static string FormatPolicy(PowerPolicySnapshot? policy)
    {
        return policy is null
            ? "-"
            : $"AC {FormatLidAction(policy.AcLidAction)} / DC {FormatLidAction(policy.DcLidAction)}";
    }

    private static string FormatLidAction(int value)
    {
        return value switch
        {
            0 => "Do Nothing",
            1 => "Sleep",
            2 => "Hibernate",
            3 => "Shut Down",
            _ => $"Unknown {value}"
        };
    }

    private static string FormatBattery(BatteryInfo battery)
    {
        if (!battery.IsAvailable)
        {
            return "Unavailable";
        }

        var percent = battery.Percentage.HasValue ? $"{battery.Percentage.Value}%" : "Unknown";
        return battery.IsAcConnected ? $"{percent}, AC" : $"{percent}, battery";
    }

    private static SolidColorBrush Brush(string color)
    {
        return new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));
    }
}
