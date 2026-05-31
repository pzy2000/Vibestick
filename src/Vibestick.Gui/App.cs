using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using Vibestick.Core;
using Application = System.Windows.Application;
using Button = System.Windows.Controls.Button;
using Brushes = System.Windows.Media.Brushes;
using Color = System.Windows.Media.Color;
using ColorConverter = System.Windows.Media.ColorConverter;
using Drawing = System.Drawing;
using FontFamily = System.Windows.Media.FontFamily;
using Forms = System.Windows.Forms;
using Image = System.Windows.Controls.Image;
using MessageBox = System.Windows.MessageBox;
using Panel = System.Windows.Controls.Panel;
using ComboBox = System.Windows.Controls.ComboBox;
using TextBox = System.Windows.Controls.TextBox;
using OpenFileDialog = Microsoft.Win32.OpenFileDialog;
using Orientation = System.Windows.Controls.Orientation;
using SaveFileDialog = Microsoft.Win32.SaveFileDialog;

namespace Vibestick.Gui;

public sealed class App : Application
{
    private readonly string[] _args;
    private GuiServices? _services;
    private GuiRuntimeState? _runtimeState;
    private PetWindow? _petWindow;
    private MainWindow? _mainWindow;
    private Forms.NotifyIcon? _notifyIcon;
    private Forms.ToolStripMenuItem? _openTrayMenuItem;
    private Forms.ToolStripMenuItem? _petToggleTrayMenuItem;
    private Forms.ToolStripMenuItem? _importPetTrayMenuItem;
    private Forms.ToolStripMenuItem? _exportPetTrayMenuItem;
    private Forms.ToolStripMenuItem? _exitTrayMenuItem;
    private string? _placementPath;
    private PetWindowStateStore? _petWindowStateStore;
    private string? _panelLayoutSnapshotPath;
    private GuiLanguagePreference _languagePreference = GuiLanguagePreference.System;
    private GuiText Text => GuiText.For(_languagePreference.Resolve());
    private Window? DialogOwner => _mainWindow is not null ? _mainWindow : _petWindow;

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
        var codexSessionsRoot = GetOption(_args, "--codex-sessions-dir") ??
            Environment.GetEnvironmentVariable("VIBESTICK_CODEX_SESSIONS_DIR");
        _placementPath = GetOption(_args, "--placement-path");
        _petWindowStateStore = new PetWindowStateStore(_placementPath);
        _languagePreference = _petWindowStateStore.LoadLanguagePreference();
        _panelLayoutSnapshotPath = GetOption(_args, "--panel-layout-snapshot");
        _services = GuiServiceFactory.Create(
            statusDirectory,
            enableCodexMonitor: !HasFlag(_args, "--no-codex-monitor"),
            codexSessionsRoot);
        _services.CodexStatusBridge?.Start();
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
        _services?.CodexStatusBridge?.Dispose();
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
            UpdateTrayPetToggleText();
            return;
        }

        _petWindow = new PetWindow(
            _services,
            _runtimeState,
            ShowControlPanel,
            HidePet,
            ImportPetFromDialog,
            ExportCurrentPetFromDialog,
            () => Shutdown(0),
            _petWindowStateStore);
        _petWindow.Closed += (_, _) =>
        {
            _petWindow = null;
            UpdateTrayPetToggleText();
        };
        _petWindow.Show();
        UpdateTrayPetToggleText();
    }

    private void HidePet()
    {
        var petWindow = _petWindow;
        if (petWindow is null)
        {
            return;
        }

        _petWindow = null;
        petWindow.Close();
        UpdateTrayPetToggleText();
    }

    private void TogglePet()
    {
        if (_petWindow is { IsVisible: true })
        {
            HidePet();
            return;
        }

        ShowPet();
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

        _mainWindow = new MainWindow(
            _services,
            _runtimeState,
            OnPetLibraryChanged,
            _panelLayoutSnapshotPath,
            _petWindowStateStore,
            OnPetActionFrequencyChanged,
            OnLanguagePreferenceChanged);
        _mainWindow.Closed += (_, _) => _mainWindow = null;
        _mainWindow.Show();
    }

    private void OnPetActionFrequencyChanged(PetActionFrequencySettings settings)
    {
        _petWindow?.SetActionFrequencySettings(settings);
    }

    private void OnLanguagePreferenceChanged(GuiLanguagePreference preference)
    {
        _languagePreference = preference;
        UpdateTrayText();
        _petWindow?.RefreshLanguageText();
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

        _openTrayMenuItem = new Forms.ToolStripMenuItem(Text.OpenControlPanel, null, (_, _) => Dispatcher.Invoke(ShowControlPanel));
        _notifyIcon.ContextMenuStrip.Items.Add(_openTrayMenuItem);
        _petToggleTrayMenuItem = new Forms.ToolStripMenuItem(Text.HidePet, null, (_, _) => Dispatcher.Invoke(TogglePet));
        _notifyIcon.ContextMenuStrip.Items.Add(_petToggleTrayMenuItem);
        _importPetTrayMenuItem = new Forms.ToolStripMenuItem(Text.ImportPetMenu, null, (_, _) => Dispatcher.Invoke(ImportPetFromDialog));
        _notifyIcon.ContextMenuStrip.Items.Add(_importPetTrayMenuItem);
        _exportPetTrayMenuItem = new Forms.ToolStripMenuItem(Text.ExportPetMenu, null, (_, _) => Dispatcher.Invoke(ExportCurrentPetFromDialog));
        _notifyIcon.ContextMenuStrip.Items.Add(_exportPetTrayMenuItem);
        UpdateTrayPetToggleText();
        _exitTrayMenuItem = new Forms.ToolStripMenuItem(Text.ExitVibestick, null, (_, _) => Dispatcher.Invoke(() => Shutdown(0)));
        _notifyIcon.ContextMenuStrip.Items.Add(_exitTrayMenuItem);
        _notifyIcon.DoubleClick += (_, _) => Dispatcher.Invoke(ShowControlPanel);
    }

    private void UpdateTrayText()
    {
        if (_notifyIcon is null)
        {
            return;
        }

        _openTrayMenuItem!.Text = Text.OpenControlPanel;
        _importPetTrayMenuItem!.Text = Text.ImportPetMenu;
        _exportPetTrayMenuItem!.Text = Text.ExportPetMenu;
        _exitTrayMenuItem!.Text = Text.ExitVibestick;
        UpdateTrayPetToggleText();
    }

    private void OnPetLibraryChanged()
    {
        _mainWindow?.RefreshPetLibraryUi();
        _petWindow?.ReloadPetSprite();
    }

    private void ImportPetFromDialog()
    {
        if (_services is null)
        {
            return;
        }

        var dialog = new OpenFileDialog
        {
            Title = Text.ImportPetDialogTitle,
            Filter = Text.ImportPetFilter,
            Multiselect = false
        };
        if (dialog.ShowDialog() != true)
        {
            return;
        }

        ImportPetFile(dialog.FileName, replace: false, metadata: null);
    }

    private void ImportPetFile(string path, bool replace, PetImportMetadata? metadata)
    {
        if (_services is null)
        {
            return;
        }

        try
        {
            var extension = Path.GetExtension(path);
            PetDefinition imported;
            if (extension.Equals(".png", StringComparison.OrdinalIgnoreCase) ||
                extension.Equals(".webp", StringComparison.OrdinalIgnoreCase))
            {
                metadata ??= PetMetadataDialog.Prompt(DialogOwner, Path.GetFileNameWithoutExtension(path), Text);
                if (metadata is null)
                {
                    return;
                }
                imported = _services.PetLibrary.ImportRawAtlas(path, metadata, replace);
            }
            else
            {
                imported = _services.PetLibrary.ImportPackage(path, replace);
            }

            OnPetLibraryChanged();
            MessageBox.Show(
                DialogOwner,
                Text.ImportedAndSwitched(imported.DisplayName),
                "Vibestick",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }
        catch (PetLibraryDuplicateException duplicate)
        {
            var answer = MessageBox.Show(
                DialogOwner,
                Text.PetExistsReplace(duplicate.PetId),
                "Vibestick",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question);
            if (answer == MessageBoxResult.Yes)
            {
                ImportPetFile(path, replace: true, metadata);
            }
        }
        catch (PetLibraryException exception)
        {
            MessageBox.Show(
                DialogOwner,
                exception.Message,
                "Vibestick",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }

    private void ExportCurrentPetFromDialog()
    {
        if (_services is null)
        {
            return;
        }

        var current = _services.PetLibrary.GetCurrentPet();
        var dialog = new SaveFileDialog
        {
            Title = Text.ExportPetDialogTitle,
            FileName = $"{current.Id}.vibestick-pet.zip",
            Filter = Text.ExportPetFilter
        };
        if (dialog.ShowDialog() != true)
        {
            return;
        }

        try
        {
            _services.PetLibrary.ExportPet(current.Id, dialog.FileName);
            MessageBox.Show(
                DialogOwner,
                Text.Exported(current.DisplayName),
                "Vibestick",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }
        catch (PetLibraryException exception)
        {
            MessageBox.Show(
                DialogOwner,
                exception.Message,
                "Vibestick",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }

    private void UpdateTrayPetToggleText()
    {
        if (_petToggleTrayMenuItem is null)
        {
            return;
        }

        _petToggleTrayMenuItem.Text = _petWindow is { IsVisible: true } ? Text.HidePet : Text.ShowPet;
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
    private readonly Action _petLibraryChanged;
    private readonly Action<PetActionFrequencySettings> _petActionFrequencyChanged;
    private readonly Action<GuiLanguagePreference> _languagePreferenceChanged;
    private readonly PetWindowStateStore _petWindowStateStore;
    private readonly DispatcherTimer _hyperTimer;
    private IDisposable? _sleepBlock;

    private readonly TextBlock _modeText = new();
    private readonly TextBlock _restoreText = new();
    private readonly TextBlock _lidText = new();
    private readonly TextBlock _batteryText = new();
    private readonly TextBlock _schemeText = new();
    private readonly TextBlock _tasksText = new();
    private readonly TextBlock _guardText = new();
    private readonly TextBlock _protectionText = new();
    private readonly TextBlock _batterySafetyText = new();
    private readonly TextBlock _timingText = new();
    private readonly TextBlock _doctorSummaryText = new();
    private readonly TextBox _outputBox = new();
    private readonly Button _refreshButton = new();
    private readonly Button _doctorButton = new();
    private readonly Button _onButton = new();
    private readonly Button _hyperButton = new();
    private readonly Button _stopHyperButton = new();
    private readonly Button _revertButton = new();
    private readonly ComboBox _petSelector = new();
    private readonly TextBlock _petLibraryText = new();
    private readonly Image _petPreview = new();
    private readonly Button _importPetButton = new();
    private readonly Button _exportPetButton = new();
    private readonly Button _deletePetButton = new();
    private readonly ComboBox _languageSelector = new();
    private readonly Slider _randomActionFrequencySlider = new();
    private readonly Slider _walkSpeedMultiplierSlider = new();
    private readonly Slider _wanderFrequencySlider = new();
    private readonly TextBlock _randomActionFrequencyValue = new();
    private readonly TextBlock _walkSpeedMultiplierValue = new();
    private readonly TextBlock _wanderFrequencyValue = new();
    private readonly DispatcherTimer _watchTimer;
    private VibestickStatus? _lastStatus;
    private DoctorReport? _lastDoctorReport;
    private DateTimeOffset? _guardStartedAt;
    private DateTimeOffset? _lastRefreshAt;
    private DateTimeOffset? _lastSafetyCheckAt;
    private readonly string? _panelLayoutSnapshotPath;
    private bool _isRefreshingPetLibraryUi;
    private bool _isRefreshingActionFrequencyUi;
    private bool _isRefreshingLanguageUi;
    private PetActionFrequencySettings _petActionFrequencySettings = PetActionFrequencySettings.Default;
    private GuiLanguagePreference _languagePreference = GuiLanguagePreference.System;
    private GuiText L => GuiText.For(_languagePreference.Resolve());

    public MainWindow(
        GuiServices services,
        GuiRuntimeState runtimeState,
        Action? petLibraryChanged = null,
        string? panelLayoutSnapshotPath = null,
        PetWindowStateStore? petWindowStateStore = null,
        Action<PetActionFrequencySettings>? petActionFrequencyChanged = null,
        Action<GuiLanguagePreference>? languagePreferenceChanged = null)
    {
        _services = services;
        _runtimeState = runtimeState;
        _petLibraryChanged = petLibraryChanged ?? (() => { });
        _petWindowStateStore = petWindowStateStore ?? new PetWindowStateStore();
        _petActionFrequencyChanged = petActionFrequencyChanged ?? (_ => { });
        _languagePreferenceChanged = languagePreferenceChanged ?? (_ => { });
        _petActionFrequencySettings = _petWindowStateStore.LoadActionFrequencySettings();
        _languagePreference = _petWindowStateStore.LoadLanguagePreference();
        _panelLayoutSnapshotPath = panelLayoutSnapshotPath;
        _hyperTimer = new DispatcherTimer
        {
            Interval = _services.Options.HyperGuardInterval
        };
        _hyperTimer.Tick += async (_, _) => await CheckHyperGuardAsync().ConfigureAwait(true);
        _watchTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(1)
        };
        _watchTimer.Tick += (_, _) => UpdateHyperWatch();

        Title = "Vibestick";
        Width = 980;
        Height = 900;
        MinWidth = 760;
        MinHeight = 560;
        Background = Brush("#f7f8fb");
        FontFamily = new FontFamily("Segoe UI");

        Content = BuildLayout();
        Loaded += async (_, _) =>
        {
            _watchTimer.Start();
            await RefreshStatusAsync(L.Ready).ConfigureAwait(true);
            RefreshPetLibraryUi();
            RefreshActionFrequencyUi();
            RefreshLanguageUi();
            await WritePanelLayoutSnapshotAsync().ConfigureAwait(true);
        };
        Closed += async (_, _) =>
        {
            _watchTimer.Stop();
            await ReleaseHyperGuardAsync(updateState: false).ConfigureAwait(true);
        };
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
            Text = L.Title,
            FontSize = 28,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brush("#172033")
        };

        var subtitle = new TextBlock
        {
            Text = L.Subtitle,
            Margin = new Thickness(0, 36, 0, 0),
            Foreground = Brush("#5f687a"),
            FontSize = 13
        };
        var titleStack = new Grid();
        titleStack.Children.Add(title);
        titleStack.Children.Add(subtitle);

        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(titleStack);
        var languagePanel = BuildLanguagePanel();
        Grid.SetColumn(languagePanel, 1);
        header.Children.Add(languagePanel);
        root.Children.Add(header);

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

        AddMetric(summary, 0, 0, L.Mode, _modeText);
        AddMetric(summary, 0, 1, L.LidClose, _lidText);
        AddMetric(summary, 1, 0, L.Battery, _batteryText);
        AddMetric(summary, 1, 1, L.PowerScheme, _schemeText);
        AddMetric(summary, 2, 0, L.RestorePending, _restoreText);
        AddMetric(summary, 2, 1, L.HyperGuard, _guardText);

        var tasksBand = new Border
        {
            Margin = new Thickness(0, 16, 0, 0),
            Padding = new Thickness(14),
            Background = Brushes.White,
            BorderBrush = Brush("#e1e5ee"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Child = Stack(L.RunningTasks, _tasksText)
        };
        Grid.SetRow(tasksBand, 2);
        root.Children.Add(tasksBand);

        var body = new Grid
        {
            Margin = new Thickness(0, 18, 0, 0)
        };
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(650) });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(body, 3);
        root.Children.Add(body);

        var controls = new UniformGrid
        {
            Columns = 2,
            Rows = 3
        };
        AddActionButton(controls, _refreshButton, L.RefreshStatus, async () => await RefreshStatusAsync(L.StatusRefreshed).ConfigureAwait(true));
        AddActionButton(controls, _doctorButton, L.RunDoctor, RunDoctorAsync);
        AddActionButton(controls, _onButton, L.ModeOn, async () => await ApplyModeAsync(VibestickMode.On, startGuard: false).ConfigureAwait(true));
        AddActionButton(controls, _hyperButton, L.ModeHyper, async () => await ApplyModeAsync(VibestickMode.Hyper, startGuard: true).ConfigureAwait(true), isPrimary: true);
        AddActionButton(controls, _stopHyperButton, L.StopHyperGuard, async () => await ReleaseHyperGuardAsync(updateState: true).ConfigureAwait(true));
        AddActionButton(controls, _revertButton, L.OffRevert, RevertAsync);

        var controlsPanel = new Border
        {
            Padding = new Thickness(14),
            Background = Brushes.White,
            BorderBrush = Brush("#e1e5ee"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Child = controls
        };
        var leftPanel = new Grid();
        leftPanel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(300) });
        leftPanel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        leftPanel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var controlsColumn = new StackPanel();
        controlsColumn.Children.Add(controlsPanel);
        controlsColumn.Children.Add(new Border
        {
            Margin = new Thickness(0, 6, 0, 0),
            Padding = new Thickness(4),
            Background = Brushes.White,
            BorderBrush = Brush("#e1e5ee"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Child = BuildPetActionFrequencyPanel()
        });
        leftPanel.Children.Add(controlsColumn);
        var petLibraryPanel = BuildPetLibraryPanel();
        Grid.SetColumn(petLibraryPanel, 2);
        leftPanel.Children.Add(petLibraryPanel);
        body.Children.Add(leftPanel);

        var outputGrid = new Grid();
        outputGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(170) });
        outputGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(14) });
        outputGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(outputGrid, 2);
        body.Children.Add(outputGrid);

        outputGrid.Children.Add(BuildHyperWatchPanel());

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

    private UIElement BuildLanguagePanel()
    {
        var root = new StackPanel
        {
            MinWidth = 190,
            Margin = new Thickness(18, 0, 0, 0)
        };
        root.Children.Add(new TextBlock
        {
            Text = L.LanguageLabel,
            FontSize = 12,
            Foreground = Brush("#697386"),
            Margin = new Thickness(0, 0, 0, 4)
        });
        _languageSelector.DisplayMemberPath = nameof(LanguageSelectorItem.Label);
        _languageSelector.SelectedValuePath = nameof(LanguageSelectorItem.Preference);
        _languageSelector.SelectionChanged += (_, _) => HandleLanguageSelectionChanged();
        root.Children.Add(_languageSelector);
        RefreshLanguageUi();
        return root;
    }

    private void RefreshLanguageUi()
    {
        _isRefreshingLanguageUi = true;
        try
        {
            _languageSelector.ItemsSource = new[]
            {
                new LanguageSelectorItem(GuiLanguagePreference.System, L.LanguageSystem),
                new LanguageSelectorItem(GuiLanguagePreference.Zh, L.LanguageChinese),
                new LanguageSelectorItem(GuiLanguagePreference.En, L.LanguageEnglish)
            };
            _languageSelector.SelectedValue = _languagePreference;
        }
        finally
        {
            _isRefreshingLanguageUi = false;
        }
    }

    private void HandleLanguageSelectionChanged()
    {
        if (_isRefreshingLanguageUi ||
            _languageSelector.SelectedItem is not LanguageSelectorItem item ||
            item.Preference == _languagePreference)
        {
            return;
        }

        _languagePreference = item.Preference;
        _petWindowStateStore.SaveLanguagePreference(_languagePreference);
        ApplyLocalizedText();
        _languagePreferenceChanged(_languagePreference);
    }

    private void ApplyLocalizedText()
    {
        Title = L.Title;
        _refreshButton.Content = L.RefreshStatus;
        _doctorButton.Content = L.RunDoctor;
        _onButton.Content = L.ModeOn;
        _hyperButton.Content = L.ModeHyper;
        _stopHyperButton.Content = L.StopHyperGuard;
        _revertButton.Content = L.OffRevert;
        _importPetButton.Content = L.ImportPet;
        _exportPetButton.Content = L.ExportCurrent;
        _deletePetButton.Content = L.DeleteCustomPet;
        RefreshLanguageUi();
        RefreshPetLibraryUi();
        if (_lastStatus is not null)
        {
            RenderStatus(_lastStatus);
        }
        else
        {
            UpdateHyperWatch();
        }
    }

    private UIElement BuildPetLibraryPanel()
    {
        var root = new StackPanel();

        var title = new TextBlock
        {
            Text = L.PetLibrary,
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brush("#172033"),
            Margin = new Thickness(0, 0, 0, 10)
        };
        root.Children.Add(title);

        var current = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        _petPreview.Width = 54;
        _petPreview.Height = 58;
        _petPreview.Stretch = Stretch.Uniform;
        _petPreview.Margin = new Thickness(0, 0, 10, 0);
        DockPanel.SetDock(_petPreview, Dock.Left);
        current.Children.Add(_petPreview);

        _petLibraryText.FontSize = 12;
        _petLibraryText.Foreground = Brush("#172033");
        _petLibraryText.TextWrapping = TextWrapping.Wrap;
        current.Children.Add(_petLibraryText);
        root.Children.Add(current);

        _petSelector.Margin = new Thickness(0, 0, 0, 10);
        _petSelector.DisplayMemberPath = nameof(PetSelectorItem.Label);
        _petSelector.SelectionChanged += (_, _) =>
        {
            if (_isRefreshingPetLibraryUi || _petSelector.SelectedItem is not PetSelectorItem item)
            {
                return;
            }

            try
            {
                _services.PetLibrary.SelectPet(item.Id);
                RefreshPetLibraryUi();
                _petLibraryChanged();
            }
            catch (PetLibraryException exception)
            {
                MessageBox.Show(this, exception.Message, "Vibestick", MessageBoxButton.OK, MessageBoxImage.Error);
                RefreshPetLibraryUi();
            }
        };
        root.Children.Add(_petSelector);

        var actions = new UniformGrid
        {
            Columns = 2,
            Rows = 2
        };
        AddActionButton(actions, _importPetButton, L.ImportPet, ImportPetAsync);
        AddActionButton(actions, _exportPetButton, L.ExportCurrent, ExportCurrentPetAsync);
        AddActionButton(actions, _deletePetButton, L.DeleteCustomPet, DeleteSelectedPetAsync);
        root.Children.Add(actions);

        return new Border
        {
            Padding = new Thickness(14),
            Background = Brushes.White,
            BorderBrush = Brush("#e1e5ee"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Child = root
        };
    }

    private UIElement BuildPetActionFrequencyPanel()
    {
        var root = new StackPanel();
        AddFrequencySlider(
            root,
            _randomActionFrequencySlider,
            _randomActionFrequencyValue,
            L.RandomActions,
            _petActionFrequencySettings.RandomActionFrequency,
            PetActionFrequencySettings.RandomActionMinMultiplier,
            PetActionFrequencySettings.MaxMultiplier,
            PetActionFrequencySettings.RandomActionStep);
        AddFrequencySlider(
            root,
            _walkSpeedMultiplierSlider,
            _walkSpeedMultiplierValue,
            L.WalkingSpeed,
            _petActionFrequencySettings.WalkSpeedMultiplier);
        AddFrequencySlider(
            root,
            _wanderFrequencySlider,
            _wanderFrequencyValue,
            L.WanderPause,
            _petActionFrequencySettings.WanderFrequency);

        return root;
    }

    private void AddFrequencySlider(
        Panel root,
        Slider slider,
        TextBlock valueText,
        string label,
        double value,
        double minimum = PetActionFrequencySettings.MinMultiplier,
        double maximum = PetActionFrequencySettings.MaxMultiplier,
        double tickFrequency = PetActionFrequencySettings.Step)
    {
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(96) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44) });

        var labelText = new TextBlock
        {
            Text = label,
            FontSize = 11,
            Foreground = Brush("#4b5563"),
            VerticalAlignment = VerticalAlignment.Center
        };
        row.Children.Add(labelText);

        valueText.FontSize = 11;
        valueText.FontFamily = new FontFamily("Consolas");
        valueText.Foreground = Brush("#4b5563");
        valueText.TextAlignment = TextAlignment.Right;
        valueText.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(valueText, 2);
        row.Children.Add(valueText);

        slider.Minimum = minimum;
        slider.Maximum = maximum;
        slider.TickFrequency = tickFrequency;
        slider.SmallChange = tickFrequency;
        slider.LargeChange = tickFrequency * 5;
        slider.IsSnapToTickEnabled = true;
        slider.AutoToolTipPlacement = AutoToolTipPlacement.TopLeft;
        slider.Value = value;
        slider.Margin = new Thickness(8, 0, 8, 0);
        Grid.SetColumn(slider, 1);
        slider.ValueChanged += (_, _) => HandleActionFrequencySliderChanged();
        row.Children.Add(slider);
        root.Children.Add(row);
        UpdateFrequencyValueText(valueText, value);
    }

    private void RefreshActionFrequencyUi()
    {
        _isRefreshingActionFrequencyUi = true;
        try
        {
            _petActionFrequencySettings = _petWindowStateStore.LoadActionFrequencySettings();
            _randomActionFrequencySlider.Value = _petActionFrequencySettings.RandomActionFrequency;
            _walkSpeedMultiplierSlider.Value = _petActionFrequencySettings.WalkSpeedMultiplier;
            _wanderFrequencySlider.Value = _petActionFrequencySettings.WanderFrequency;
            UpdateActionFrequencyValueText();
        }
        finally
        {
            _isRefreshingActionFrequencyUi = false;
        }
    }

    private void HandleActionFrequencySliderChanged()
    {
        if (_isRefreshingActionFrequencyUi)
        {
            return;
        }

        var settings = new PetActionFrequencySettings
        {
            RandomActionFrequency = _randomActionFrequencySlider.Value,
            WalkSpeedMultiplier = _walkSpeedMultiplierSlider.Value,
            WanderFrequency = _wanderFrequencySlider.Value
        }.Clamped();
        _petActionFrequencySettings = settings;
        _petWindowStateStore.SaveActionFrequencySettings(settings);
        _petActionFrequencyChanged(settings);
        RefreshActionFrequencyUi();
    }

    private void UpdateActionFrequencyValueText()
    {
        UpdateFrequencyValueText(_randomActionFrequencyValue, _petActionFrequencySettings.RandomActionFrequency);
        UpdateFrequencyValueText(_walkSpeedMultiplierValue, _petActionFrequencySettings.WalkSpeedMultiplier);
        UpdateFrequencyValueText(_wanderFrequencyValue, _petActionFrequencySettings.WanderFrequency);
    }

    private static void UpdateFrequencyValueText(TextBlock valueText, double value)
    {
        valueText.Text = value < PetActionFrequencySettings.MinMultiplier
            ? $"{value:0.00}x"
            : $"{value:0.0}x";
    }

    public void RefreshPetLibraryUi()
    {
        _isRefreshingPetLibraryUi = true;
        try
        {
            var pets = _services.PetLibrary.GetPets();
            var current = _services.PetLibrary.GetCurrentPet();
            _petSelector.ItemsSource = pets
                .Select(pet => new PetSelectorItem(
                    pet.Id,
                    pet.IsBuiltIn ? $"{pet.DisplayName} ({L.BuiltIn})" : pet.DisplayName))
                .ToArray();
            _petSelector.SelectedItem = _petSelector.Items
                .OfType<PetSelectorItem>()
                .FirstOrDefault(item => string.Equals(item.Id, current.Id, StringComparison.OrdinalIgnoreCase));
            _petLibraryText.Text = $"{current.DisplayName}\n{current.Description}";
            _deletePetButton.IsEnabled = !current.IsBuiltIn;
            _exportPetButton.IsEnabled = true;
            _petPreview.Source = LoadPetPreview(current.SpritesheetPath);
        }
        finally
        {
            _isRefreshingPetLibraryUi = false;
        }
    }

    private Task ImportPetAsync()
    {
        var dialog = new OpenFileDialog
        {
            Title = L.ImportPetDialogTitle,
            Filter = L.ImportPetFilter,
            Multiselect = false
        };
        if (dialog.ShowDialog(this) == true)
        {
            ImportPetFile(dialog.FileName, replace: false, metadata: null);
        }
        return Task.CompletedTask;
    }

    private Task ExportCurrentPetAsync()
    {
        var current = _services.PetLibrary.GetCurrentPet();
        var dialog = new SaveFileDialog
        {
            Title = L.ExportPetDialogTitle,
            FileName = $"{current.Id}.vibestick-pet.zip",
            Filter = L.ExportPetFilter
        };
        if (dialog.ShowDialog(this) == true)
        {
            try
            {
                _services.PetLibrary.ExportPet(current.Id, dialog.FileName);
                MessageBox.Show(this, L.Exported(current.DisplayName), "Vibestick", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (PetLibraryException exception)
            {
                MessageBox.Show(this, exception.Message, "Vibestick", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }
        return Task.CompletedTask;
    }

    private Task DeleteSelectedPetAsync()
    {
        var current = _services.PetLibrary.GetCurrentPet();
        if (current.IsBuiltIn)
        {
            MessageBox.Show(this, L.BuiltInPetCannotDelete, "Vibestick", MessageBoxButton.OK, MessageBoxImage.Information);
            return Task.CompletedTask;
        }

        var answer = MessageBox.Show(
            this,
            L.DeletePetConfirm(current.DisplayName),
            "Vibestick",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);
        if (answer != MessageBoxResult.Yes)
        {
            return Task.CompletedTask;
        }

        try
        {
            _services.PetLibrary.DeleteCustomPet(current.Id);
            RefreshPetLibraryUi();
            _petLibraryChanged();
        }
        catch (PetLibraryException exception)
        {
            MessageBox.Show(this, exception.Message, "Vibestick", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        return Task.CompletedTask;
    }

    private void ImportPetFile(string path, bool replace, PetImportMetadata? metadata)
    {
        try
        {
            var extension = Path.GetExtension(path);
            PetDefinition imported;
            if (extension.Equals(".png", StringComparison.OrdinalIgnoreCase) ||
                extension.Equals(".webp", StringComparison.OrdinalIgnoreCase))
            {
                metadata ??= PetMetadataDialog.Prompt(this, Path.GetFileNameWithoutExtension(path), L);
                if (metadata is null)
                {
                    return;
                }
                imported = _services.PetLibrary.ImportRawAtlas(path, metadata, replace);
            }
            else
            {
                imported = _services.PetLibrary.ImportPackage(path, replace);
            }

            RefreshPetLibraryUi();
            _petLibraryChanged();
            MessageBox.Show(this, L.ImportedAndSwitched(imported.DisplayName), "Vibestick", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (PetLibraryDuplicateException duplicate)
        {
            var answer = MessageBox.Show(
                this,
                L.PetExistsReplace(duplicate.PetId),
                "Vibestick",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question);
            if (answer == MessageBoxResult.Yes)
            {
                ImportPetFile(path, replace: true, metadata);
            }
        }
        catch (PetLibraryException exception)
        {
            MessageBox.Show(this, exception.Message, "Vibestick", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private static BitmapSource? LoadPetPreview(string spritesheetPath)
    {
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.UriSource = new Uri(spritesheetPath, UriKind.Absolute);
            image.EndInit();
            image.Freeze();
            return new CroppedBitmap(image, new Int32Rect(0, 0, 192, 208));
        }
        catch (Exception exception) when (exception is IOException or NotSupportedException or InvalidOperationException)
        {
            return null;
        }
    }

    private UIElement BuildHyperWatchPanel()
    {
        var content = new Grid();
        content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.25, GridUnitType.Star) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.15, GridUnitType.Star) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var title = new TextBlock
        {
            Text = L.HyperWatch,
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brush("#172033"),
            Margin = new Thickness(0, 0, 0, 10)
        };
        Grid.SetColumnSpan(title, 4);
        content.Children.Add(title);

        AddWatchSection(content, 0, L.Protection, _protectionText);
        AddWatchSection(content, 1, L.BatterySafety, _batterySafetyText);
        AddWatchSection(content, 2, L.Timing, _timingText);
        AddWatchSection(content, 3, L.DoctorSnapshot, _doctorSummaryText);

        return new Border
        {
            Background = Brushes.White,
            BorderBrush = Brush("#e1e5ee"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(14),
            Child = content
        };
    }

    private static void AddWatchSection(Grid grid, int column, string label, TextBlock value)
    {
        value.FontSize = 12;
        value.Foreground = Brush("#172033");
        value.TextWrapping = TextWrapping.Wrap;
        value.LineHeight = 18;

        var labelBlock = new TextBlock
        {
            Text = label,
            FontSize = 11,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brush("#697386"),
            Margin = new Thickness(0, 0, 0, 6)
        };

        var section = new StackPanel
        {
            Margin = new Thickness(column == 0 ? 0 : 12, 0, column == 3 ? 0 : 12, 0),
            Children =
            {
                labelBlock,
                value
            }
        };
        Grid.SetRow(section, 1);
        Grid.SetColumn(section, column);
        grid.Children.Add(section);
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
        button.Height = 40;
        button.Margin = new Thickness(4, 0, 4, 8);
        button.Padding = new Thickness(8, 0, 8, 0);
        button.MinWidth = 0;
        button.FontWeight = FontWeights.SemiBold;
        button.Background = isPrimary ? Brush("#6d5dfc") : Brush("#eef2ff");
        button.Foreground = isPrimary ? Brushes.White : Brush("#29324a");
        button.BorderBrush = isPrimary ? Brush("#6d5dfc") : Brush("#cdd6f6");
        button.BorderThickness = new Thickness(1);
        button.HorizontalContentAlignment = System.Windows.HorizontalAlignment.Center;
        button.VerticalContentAlignment = System.Windows.VerticalAlignment.Center;
        button.Cursor = System.Windows.Input.Cursors.Hand;
        button.Click += async (_, _) => await action().ConfigureAwait(true);
        panel.Children.Add(button);
    }

    private async Task WritePanelLayoutSnapshotAsync()
    {
        if (_panelLayoutSnapshotPath is null)
        {
            return;
        }

        UpdateLayout();
        await Dispatcher.InvokeAsync(UpdateLayout, DispatcherPriority.Render);
        await Dispatcher.InvokeAsync(UpdateLayout, DispatcherPriority.ApplicationIdle);

        var snapshot = new PanelLayoutSnapshot(
            Width,
            Height,
            ActualWidth,
            ActualHeight,
            new[]
            {
                CaptureButtonLayout(_refreshButton),
                CaptureButtonLayout(_doctorButton),
                CaptureButtonLayout(_onButton),
                CaptureButtonLayout(_hyperButton),
                CaptureButtonLayout(_stopHyperButton),
                CaptureButtonLayout(_revertButton),
                CaptureButtonLayout(_importPetButton),
                CaptureButtonLayout(_exportPetButton),
                CaptureButtonLayout(_deletePetButton)
            },
            new[]
            {
                CaptureSliderLayout(_randomActionFrequencySlider, L.RandomActions),
                CaptureSliderLayout(_walkSpeedMultiplierSlider, L.WalkingSpeed),
                CaptureSliderLayout(_wanderFrequencySlider, L.WanderPause)
            },
            _languagePreference.ToStorageValue(),
            _languageSelector.Items.OfType<LanguageSelectorItem>().Select(static item => item.Label).ToArray());

        var directory = Path.GetDirectoryName(_panelLayoutSnapshotPath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        await File.WriteAllTextAsync(
                _panelLayoutSnapshotPath,
                JsonSerializer.Serialize(snapshot, JsonOptions))
            .ConfigureAwait(true);
    }

    private ButtonLayoutSnapshot CaptureButtonLayout(Button button)
    {
        var contentRoot = Content as FrameworkElement;
        var bounds = contentRoot is not null
            ? button.TransformToAncestor(contentRoot).TransformBounds(
                new Rect(0, 0, button.ActualWidth, button.ActualHeight))
            : button.TransformToAncestor(this).TransformBounds(
                new Rect(0, 0, button.ActualWidth, button.ActualHeight));
        var clientBounds = contentRoot is not null
            ? new Rect(0, 0, contentRoot.ActualWidth, contentRoot.ActualHeight)
            : new Rect(0, 0, ActualWidth, ActualHeight);
        var fitsWithinWindow =
            button.IsVisible &&
            button.ActualWidth > 0 &&
            button.ActualHeight > 0 &&
            bounds.Left >= clientBounds.Left &&
            bounds.Top >= clientBounds.Top &&
            bounds.Right <= clientBounds.Right &&
            bounds.Bottom <= clientBounds.Bottom;

        return new ButtonLayoutSnapshot(
            button.Content?.ToString() ?? string.Empty,
            button.IsVisible,
            button.ActualWidth,
            button.ActualHeight,
            bounds.Left,
            bounds.Top,
            bounds.Right,
            bounds.Bottom,
            fitsWithinWindow);
    }

    private SliderLayoutSnapshot CaptureSliderLayout(Slider slider, string label)
    {
        var contentRoot = Content as FrameworkElement;
        var bounds = contentRoot is not null
            ? slider.TransformToAncestor(contentRoot).TransformBounds(
                new Rect(0, 0, slider.ActualWidth, slider.ActualHeight))
            : slider.TransformToAncestor(this).TransformBounds(
                new Rect(0, 0, slider.ActualWidth, slider.ActualHeight));
        var clientBounds = contentRoot is not null
            ? new Rect(0, 0, contentRoot.ActualWidth, contentRoot.ActualHeight)
            : new Rect(0, 0, ActualWidth, ActualHeight);
        var fitsWithinWindow =
            slider.IsVisible &&
            slider.ActualWidth > 0 &&
            slider.ActualHeight > 0 &&
            bounds.Left >= clientBounds.Left &&
            bounds.Top >= clientBounds.Top &&
            bounds.Right <= clientBounds.Right &&
            bounds.Bottom <= clientBounds.Bottom;

        return new SliderLayoutSnapshot(
            label,
            slider.IsVisible,
            slider.ActualWidth,
            slider.ActualHeight,
            slider.Value,
            fitsWithinWindow);
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
            _lastDoctorReport = report;
            UpdateHyperWatch();
            WriteOutput(report.IsHealthy ? L.DoctorPassed : L.DoctorFoundIssues, report);
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
        _guardStartedAt = DateTimeOffset.Now;
        _lastSafetyCheckAt = DateTimeOffset.Now;
        _hyperTimer.Start();
        SetGuardUi();
        AppendLog(L.HyperGuardStarted);
    }

    private async Task ReleaseHyperGuardAsync(bool updateState)
    {
        StopHyperGuardOnly();
        if (updateState)
        {
            var result = await _services.Engine.ApplyModeAsync(VibestickMode.On).ConfigureAwait(true);
            WriteOutput(L.HyperGuardStopped, result);
            await RefreshStatusAsync().ConfigureAwait(true);
        }
    }

    private void StopHyperGuardOnly()
    {
        _hyperTimer.Stop();
        _sleepBlock?.Dispose();
        _sleepBlock = null;
        _runtimeState.IsHyperGuardRunning = false;
        _guardStartedAt = null;
        _lastSafetyCheckAt = null;
        SetGuardUi();
    }

    private async Task CheckHyperGuardAsync()
    {
        if (_sleepBlock is null)
        {
            return;
        }

        _lastSafetyCheckAt = DateTimeOffset.Now;
        var decision = new BatterySafetyPolicy(_services.Options).Evaluate(_services.BatteryMonitor.GetBatteryInfo());
        if (decision.Action == SafetyAction.RestoreNormalSleep)
        {
            AppendLog(decision.Message);
            StopHyperGuardOnly();
            await _services.Engine.RevertAsync().ConfigureAwait(true);
            await RefreshStatusAsync(L.CriticalBatteryActionApplied).ConfigureAwait(true);
            return;
        }

        if (decision.Action == SafetyAction.DowngradeToOn)
        {
            AppendLog(decision.Message);
            StopHyperGuardOnly();
            await _services.Engine.ApplyModeAsync(VibestickMode.On).ConfigureAwait(true);
            await RefreshStatusAsync(L.BatterySafetyDowngraded).ConfigureAwait(true);
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
        _lastStatus = status;
        _lastRefreshAt = DateTimeOffset.Now;
        _modeText.Text = L.ModeLabel(status.ActiveMode);
        _restoreText.Text = status.RestorePending ? L.Yes : L.No;
        _lidText.Text = FormatPolicy(status.CurrentPolicy);
        _batteryText.Text = FormatBattery(status.Battery);
        _schemeText.Text = status.CurrentSchemeGuid ?? "-";
        _tasksText.Text = status.LongTasks.Count == 0
            ? L.NoTasks
            : string.Join(", ", status.LongTasks.Select(static task => task.ProcessId.HasValue ? $"{task.Name} ({task.ProcessId})" : task.Name));

        SetGuardUi();
        UpdateHyperWatch();
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
        _guardText.Text = running ? L.Running : L.Stopped;
        _stopHyperButton.IsEnabled = running;
        UpdateHyperWatch();
    }

    private void UpdateHyperWatch()
    {
        var status = _lastStatus;
        if (status is null)
        {
            _protectionText.Text = L.RefreshProtection;
            _batterySafetyText.Text = L.BatteryPending;
            _timingText.Text = L.GuardStoppedTiming;
            _doctorSummaryText.Text = L.DoctorNotRun;
            return;
        }

        var running = _sleepBlock is not null;
        _protectionText.Text = string.Join(
            Environment.NewLine,
            running
                ? (L.Language == GuiLanguage.Zh ? "OK 空闲睡眠已被阻止" : "OK Idle sleep is blocked")
                : (L.Language == GuiLanguage.Zh ? "守护未阻止睡眠" : "Guard is not blocking sleep"),
            $"Lid close: {FormatPolicy(status.CurrentPolicy)}",
            status.RestorePending
                ? (L.Language == GuiLanguage.Zh ? "恢复备份已保存" : "Revert backup is saved")
                : (L.Language == GuiLanguage.Zh ? "没有待恢复状态" : "No restore is pending"));

        var batteryDecision = new BatterySafetyPolicy(_services.Options).Evaluate(status.Battery);
        _batterySafetyText.Text = string.Join(
            Environment.NewLine,
            FormatBattery(status.Battery),
            FormatSafetyDecision(batteryDecision, status.ActiveMode, running),
            $"Warn <{_services.Options.BatteryWarnPercent}% / Down <{_services.Options.BatteryDowngradePercent}% / Restore <{_services.Options.BatteryRestorePercent}%");

        _timingText.Text = BuildTimingText(running);
        _doctorSummaryText.Text = BuildDoctorSummaryText(status);
    }

    private string BuildTimingText(bool running)
    {
        var lastRefresh = _lastRefreshAt?.ToLocalTime().ToString("HH:mm:ss", CultureInfo.InvariantCulture) ?? "-";
        if (!running)
        {
            return string.Join(
                Environment.NewLine,
                L.Language == GuiLanguage.Zh ? "守护已停止" : "Guard stopped",
                L.Language == GuiLanguage.Zh ? "安全检查已暂停" : "Safety check paused",
                L.Language == GuiLanguage.Zh ? $"上次刷新：{lastRefresh}" : $"Last refresh: {lastRefresh}");
        }

        var now = DateTimeOffset.Now;
        var runningFor = _guardStartedAt.HasValue
            ? FormatWatchDuration(now - _guardStartedAt.Value)
            : "-";
        var nextCheck = _lastSafetyCheckAt.HasValue
            ? FormatWatchDuration((_lastSafetyCheckAt.Value + _services.Options.HyperGuardInterval) - now)
            : "soon";

        return string.Join(
            Environment.NewLine,
            L.Language == GuiLanguage.Zh ? $"守护运行时长：{runningFor}" : $"Guard running: {runningFor}",
            L.Language == GuiLanguage.Zh ? $"下次安全检查：{nextCheck}" : $"Next safety check: {nextCheck}",
            L.Language == GuiLanguage.Zh ? $"上次刷新：{lastRefresh}" : $"Last refresh: {lastRefresh}");
    }

    private string BuildDoctorSummaryText(VibestickStatus status)
    {
        if (status.Warnings.Count > 0)
        {
            return string.Join(
                Environment.NewLine,
                $"Warnings: {status.Warnings.Count}",
                status.Warnings[0]);
        }

        if (_lastDoctorReport is null)
        {
            return L.Language == GuiLanguage.Zh
                ? "尚未运行诊断。\n运行诊断以检查策略、电池和任务。"
                : "Doctor not run yet.\nRun Doctor for policy, battery, and task checks.";
        }

        var passed = _lastDoctorReport.Checks.Count(static check => check.Passed);
        var failed = _lastDoctorReport.Checks.Count - passed;
        return string.Join(
            Environment.NewLine,
            _lastDoctorReport.IsHealthy
                ? (L.Language == GuiLanguage.Zh ? "诊断通过" : "Doctor passed")
                : (L.Language == GuiLanguage.Zh ? "诊断需要处理" : "Doctor needs attention"),
            $"OK {passed} / ERR {failed}",
            _lastDoctorReport.Checks.FirstOrDefault(static check => !check.Passed)?.Message ??
                (L.Language == GuiLanguage.Zh ? "未发现问题。" : "No issues found."));
    }

    private string FormatSafetyDecision(
        BatterySafetyDecision decision,
        VibestickMode activeMode,
        bool isGuardRunning)
    {
        return decision.Action switch
        {
            SafetyAction.KeepHyper when activeMode == VibestickMode.Hyper || isGuardRunning => L.Language == GuiLanguage.Zh ? "安全：HYPER 可继续" : "Safe: HYPER can continue",
            SafetyAction.KeepHyper => L.Language == GuiLanguage.Zh ? "安全：无需电池动作" : "Safe: no battery action needed",
            SafetyAction.Warn => L.Language == GuiLanguage.Zh ? $"警告：{decision.Message}" : $"Warn: {decision.Message}",
            SafetyAction.DowngradeToOn => L.Language == GuiLanguage.Zh ? $"动作：{decision.Message}" : $"Action: {decision.Message}",
            SafetyAction.RestoreNormalSleep => L.Language == GuiLanguage.Zh ? $"动作：{decision.Message}" : $"Action: {decision.Message}",
            _ => decision.Message
        };
    }

    private static string FormatWatchDuration(TimeSpan duration)
    {
        if (duration < TimeSpan.Zero)
        {
            duration = TimeSpan.Zero;
        }

        var totalSeconds = Math.Max(0, (int)Math.Ceiling(duration.TotalSeconds));
        if (totalSeconds < 60)
        {
            return $"{totalSeconds}s";
        }

        var totalMinutes = totalSeconds / 60;
        var seconds = totalSeconds % 60;
        if (totalMinutes < 60)
        {
            return $"{totalMinutes}m {seconds:00}s";
        }

        var hours = totalMinutes / 60;
        var minutes = totalMinutes % 60;
        return $"{hours}h {minutes:00}m";
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

    private string FormatPolicy(PowerPolicySnapshot? policy)
    {
        return policy is null
            ? "-"
            : $"AC {FormatLidAction(policy.AcLidAction)} / DC {FormatLidAction(policy.DcLidAction)}";
    }

    private string FormatLidAction(int value)
    {
        return value switch
        {
            0 => L.Language == GuiLanguage.Zh ? "不执行操作" : "Do Nothing",
            1 => L.Language == GuiLanguage.Zh ? "睡眠" : "Sleep",
            2 => L.Language == GuiLanguage.Zh ? "休眠" : "Hibernate",
            3 => L.Language == GuiLanguage.Zh ? "关机" : "Shut Down",
            _ => L.Language == GuiLanguage.Zh ? $"未知 {value}" : $"Unknown {value}"
        };
    }

    private string FormatBattery(BatteryInfo battery)
    {
        if (!battery.IsAvailable)
        {
            return L.Language == GuiLanguage.Zh ? "无法读取" : "Unavailable";
        }

        var percent = battery.Percentage.HasValue ? $"{battery.Percentage.Value}%" : (L.Language == GuiLanguage.Zh ? "未知" : "Unknown");
        if (!battery.IsAcConnected)
        {
            return L.Language == GuiLanguage.Zh ? $"{percent}, 电池" : $"{percent}, battery";
        }

        var chargingDetail = FormatChargingDetail(battery);
        return chargingDetail is null ? $"{percent}, AC" : $"{percent}, AC, {chargingDetail}";
    }

    private static string? FormatChargingDetail(BatteryInfo battery)
    {
        if (battery.ChargeRateInMilliwatts is null or <= 0 || battery.EstimatedTimeToFull is null)
        {
            return null;
        }

        var watts = battery.ChargeRateInMilliwatts.Value / 1000d;
        return $"{watts.ToString(watts >= 10 ? "0" : "0.#", CultureInfo.InvariantCulture)}W charging, full in {FormatDuration(battery.EstimatedTimeToFull.Value)}";
    }

    private static string FormatDuration(TimeSpan duration)
    {
        var totalMinutes = Math.Max(1, (int)Math.Ceiling(duration.TotalMinutes));
        if (totalMinutes < 60)
        {
            return $"{totalMinutes}m";
        }

        var hours = totalMinutes / 60;
        var minutes = totalMinutes % 60;
        return minutes == 0 ? $"{hours}h" : $"{hours}h{minutes}m";
    }

    private static SolidColorBrush Brush(string color)
    {
        return new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));
    }

    private sealed record PanelLayoutSnapshot(
        double RequestedWidth,
        double RequestedHeight,
        double ActualWidth,
        double ActualHeight,
        IReadOnlyList<ButtonLayoutSnapshot> Buttons,
        IReadOnlyList<SliderLayoutSnapshot> Sliders,
        string LanguagePreference,
        IReadOnlyList<string> LanguageOptions);

    private sealed record ButtonLayoutSnapshot(
        string Text,
        bool IsVisible,
        double Width,
        double Height,
        double Left,
        double Top,
        double Right,
        double Bottom,
        bool FitsWithinWindow);

    private sealed record SliderLayoutSnapshot(
        string Label,
        bool IsVisible,
        double Width,
        double Height,
        double Value,
        bool FitsWithinWindow);

    private sealed record PetSelectorItem(string Id, string Label);
    private sealed record LanguageSelectorItem(GuiLanguagePreference Preference, string Label);
}

internal sealed class PetMetadataDialog : Window
{
    private readonly TextBox _nameBox = new();
    private readonly TextBox _descriptionBox = new();
    private readonly GuiText _text;
    private PetImportMetadata? _metadata;

    private PetMetadataDialog(string suggestedName, GuiText text)
    {
        _text = text;
        Title = _text.ImportPetAtlas;
        Width = 380;
        Height = 220;
        MinWidth = 340;
        MinHeight = 200;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.NoResize;
        Background = MainWindowBrush("#f7f8fb");

        _nameBox.Text = suggestedName;
        _descriptionBox.Text = _text.ImportedPetDescription;

        var root = new Grid { Margin = new Thickness(18) };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        AddLabeledTextBox(root, 0, _text.PetName, _nameBox);
        AddLabeledTextBox(root, 2, _text.Description, _descriptionBox);

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right
        };
        var cancel = new Button { Content = _text.Cancel, Width = 82, Height = 32, Margin = new Thickness(0, 0, 8, 0) };
        cancel.Click += (_, _) =>
        {
            DialogResult = false;
            Close();
        };
        var import = new Button
        {
            Content = _text.Import,
            Width = 82,
            Height = 32,
            FontWeight = FontWeights.SemiBold
        };
        import.Click += (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(_nameBox.Text))
            {
                MessageBox.Show(this, _text.PetNameRequired, "Vibestick", MessageBoxButton.OK, MessageBoxImage.Error);
                return;
            }

            _metadata = new PetImportMetadata(_nameBox.Text.Trim(), _descriptionBox.Text.Trim());
            DialogResult = true;
            Close();
        };
        buttons.Children.Add(cancel);
        buttons.Children.Add(import);
        Grid.SetRow(buttons, 4);
        root.Children.Add(buttons);

        Content = root;
    }

    public static PetImportMetadata? Prompt(Window? owner, string suggestedName, GuiText text)
    {
        var dialog = new PetMetadataDialog(string.IsNullOrWhiteSpace(suggestedName) ? text.ImportedPetName : suggestedName, text)
        {
            Owner = owner
        };
        return dialog.ShowDialog() == true ? dialog._metadata : null;
    }

    private static void AddLabeledTextBox(Grid root, int row, string label, TextBox box)
    {
        var labelBlock = new TextBlock
        {
            Text = label,
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = MainWindowBrush("#29324a"),
            Margin = new Thickness(0, 0, 0, 5)
        };
        Grid.SetRow(labelBlock, row);
        root.Children.Add(labelBlock);

        box.Height = 32;
        box.Margin = new Thickness(0, 0, 0, 12);
        Grid.SetRow(box, row + 1);
        root.Children.Add(box);
    }

    private static SolidColorBrush MainWindowBrush(string color)
    {
        return new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));
    }
}
