using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Microsoft.Win32;
using Vibestick.Core;
using Brushes = System.Windows.Media.Brushes;
using Button = System.Windows.Controls.Button;
using Color = System.Windows.Media.Color;
using ColorConverter = System.Windows.Media.ColorConverter;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using Image = System.Windows.Controls.Image;
using InputCursors = System.Windows.Input.Cursors;
using MouseEventArgs = System.Windows.Input.MouseEventArgs;
using Orientation = System.Windows.Controls.Orientation;
using Point = System.Windows.Point;
using Directory = System.IO.Directory;
using File = System.IO.File;
using IOException = System.IO.IOException;
using Path = System.IO.Path;

namespace Vibestick.Gui;

public sealed class PetWindow : Window
{
    private const double BaseWindowWidth = 410;
    private const double BaseWindowHeight = 580;
    private const double DefaultScale = 1.0;
    private const double MinScale = 0.35;
    private const double MaxScale = 1.5;
    private const double DefaultMargin = 16;
    private const double ResizeDragDivisor = 220;
    private const double ResizeHitPadding = 16;
    private const double ResizeHitSpriteYRatio = 0.45;
    private const double CrawlDirectionThreshold = 0.75;
    private const int CollapsedTaskCardLimit = 3;
    private const double ExpandedTaskListMaxHeight = 220;
    private const double TaskCardWidth = 324;
    private static readonly TimeSpan MoodFrameInterval = TimeSpan.FromMilliseconds(420);
    private static readonly TimeSpan CrawlFrameInterval = TimeSpan.FromMilliseconds(140);
    private static readonly TimeSpan HoverFrameInterval = TimeSpan.FromMilliseconds(240);

    private static readonly JsonSerializerOptions SnapshotJsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseLower) }
    };

    private readonly GuiServices _services;
    private readonly GuiRuntimeState _runtimeState;
    private readonly PetWindowStateStore _placementStore;
    private readonly Action _openControlPanel;
    private readonly Action _exitApplication;
    private readonly DispatcherTimer _statusTimer;
    private readonly DispatcherTimer _statusDebounceTimer;
    private readonly DispatcherTimer _frameTimer;
    private readonly System.IO.FileSystemWatcher? _statusWatcher;
    private readonly StackPanel _taskHost = new();
    private readonly StackPanel _taskCardsPanel = new();
    private readonly ScrollViewer _taskScrollViewer = new();
    private readonly Button _taskToggleButton = new();
    private readonly TextBlock _taskOverflowText = new();
    private readonly TextBlock _titleText = new();
    private readonly TextBlock _messageText = new();
    private readonly Border _statusBubble = new();
    private readonly StackPanel _badgesPanel = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly ScaleTransform _rootScale = new(DefaultScale, DefaultScale);
    private readonly Grid _spriteLayer = new()
    {
        Width = 184,
        Height = 198,
        HorizontalAlignment = HorizontalAlignment.Center,
        Background = Brushes.Transparent
    };
    private readonly PetSpriteAnimator _spriteAnimator;
    private PetState? _currentState;
    private bool _isRefreshing;
    private Point? _dragStart;
    private Point? _lastDragPoint;
    private Point _windowStart;
    private bool _isDragging;
    private PointerInteraction _pointerInteraction;
    private double _scale = DefaultScale;
    private double _resizeStartScale = DefaultScale;
    private bool _taskListExpanded;
    private IReadOnlyList<TaskCardSnapshot> _lastRenderedTaskCards = Array.Empty<TaskCardSnapshot>();
    private int _lastTaskCardsTotal;
    private int _lastTaskCardsVisible;
    private int _lastTaskCardsHidden;

    public PetWindow(
        GuiServices services,
        GuiRuntimeState runtimeState,
        Action openControlPanel,
        Action exitApplication,
        PetWindowStateStore? placementStore = null)
    {
        _services = services;
        _runtimeState = runtimeState;
        _openControlPanel = openControlPanel;
        _exitApplication = exitApplication;
        _placementStore = placementStore ?? new PetWindowStateStore();

        Title = "Vibestick Pet - Idle";
        ApplyScale(DefaultScale);
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ResizeMode = ResizeMode.NoResize;

        var sprite = new Image
        {
            Width = 180,
            Height = 195,
            Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Center
        };
        RenderOptions.SetBitmapScalingMode(sprite, BitmapScalingMode.NearestNeighbor);
        RenderOptions.SetEdgeMode(sprite, EdgeMode.Aliased);
        var fallback = new TextBlock
        {
            Width = 180,
            Height = 195,
            TextAlignment = TextAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = Brush("#172033"),
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap
        };
        _spriteAnimator = new PetSpriteAnimator(sprite, fallback);

        Content = BuildLayout(sprite, fallback);
        ContextMenu = BuildContextMenu();

        _statusTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _statusTimer.Tick += async (_, _) => await RefreshNowAsync().ConfigureAwait(true);
        _statusTimer.Start();

        _statusDebounceTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(180) };
        _statusDebounceTimer.Tick += async (_, _) =>
        {
            _statusDebounceTimer.Stop();
            await RefreshNowAsync().ConfigureAwait(true);
        };
        _statusWatcher = CreateStatusWatcher();

        _frameTimer = new DispatcherTimer { Interval = MoodFrameInterval };
        _frameTimer.Tick += (_, _) => _spriteAnimator.AdvanceFrame();
        _frameTimer.Start();

        Loaded += async (_, _) =>
        {
            ApplyInitialPlacement();
            await RefreshNowAsync().ConfigureAwait(true);
        };
        Closing += (_, _) =>
        {
            _statusDebounceTimer.Stop();
            _statusWatcher?.Dispose();
            SavePlacement();
        };
        MouseLeftButtonDown += OnMouseLeftButtonDown;
        MouseMove += OnMouseMove;
        MouseLeftButtonUp += OnMouseLeftButtonUp;
        _spriteLayer.MouseEnter += (_, _) => StartSpriteHover();
        _spriteLayer.MouseLeave += (_, _) => StopSpriteHover();
    }

    public async Task RefreshNowAsync()
    {
        if (_isRefreshing)
        {
            return;
        }

        _isRefreshing = true;
        try
        {
            var now = DateTimeOffset.UtcNow;
            var vibestickStatus = await _services.Engine.GetStatusAsync().ConfigureAwait(true);
            var coderStatuses = _services.CoderStatusSource.GetStatuses(now);
            Render(_services.PetStateResolver.Resolve(
                vibestickStatus,
                coderStatuses,
                _runtimeState.IsHyperGuardRunning,
                now));
        }
        catch (Exception exception)
        {
            RenderFailure(exception);
        }
        finally
        {
            _isRefreshing = false;
        }
    }

    private UIElement BuildLayout(Image sprite, TextBlock fallback)
    {
        var root = new Grid
        {
            Width = BaseWindowWidth,
            Height = BaseWindowHeight,
            LayoutTransform = _rootScale,
            Background = Brushes.Transparent,
            Margin = new Thickness(0)
        };

        var panel = new StackPanel
        {
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center
        };
        root.Children.Add(panel);

        _taskHost.Margin = new Thickness(12, 8, 12, 4);
        panel.Children.Add(_taskHost);

        var taskHeader = new DockPanel
        {
            Margin = new Thickness(0, 0, 0, 5),
            LastChildFill = false
        };
        _taskHost.Children.Add(taskHeader);

        _taskOverflowText.FontSize = 12;
        _taskOverflowText.FontWeight = FontWeights.SemiBold;
        _taskOverflowText.Foreground = Brush("#4b5563");
        _taskOverflowText.VerticalAlignment = VerticalAlignment.Center;
        _taskOverflowText.Margin = new Thickness(0, 0, 6, 0);
        DockPanel.SetDock(_taskOverflowText, Dock.Right);
        taskHeader.Children.Add(_taskOverflowText);

        _taskToggleButton.Width = 28;
        _taskToggleButton.Height = 24;
        _taskToggleButton.Padding = new Thickness(0);
        _taskToggleButton.FontWeight = FontWeights.Bold;
        _taskToggleButton.Cursor = InputCursors.Hand;
        _taskToggleButton.Click += (_, args) =>
        {
            args.Handled = true;
            _taskListExpanded = !_taskListExpanded;
            if (_currentState is not null)
            {
                Render(_currentState);
            }
        };
        DockPanel.SetDock(_taskToggleButton, Dock.Right);
        taskHeader.Children.Add(_taskToggleButton);

        _taskScrollViewer.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        _taskScrollViewer.VerticalScrollBarVisibility = ScrollBarVisibility.Disabled;
        _taskScrollViewer.Content = _taskCardsPanel;
        _taskHost.Children.Add(_taskScrollViewer);

        _statusBubble.Width = 386;
        _statusBubble.MinHeight = 68;
        _statusBubble.Padding = new Thickness(12, 9, 12, 9);
        _statusBubble.Margin = new Thickness(12, 4, 12, 4);
        _statusBubble.Background = Brush("#f8fbff");
        _statusBubble.BorderBrush = Brush("#d5deea");
        _statusBubble.BorderThickness = new Thickness(1);
        _statusBubble.CornerRadius = new CornerRadius(8);
        _statusBubble.Effect = new System.Windows.Media.Effects.DropShadowEffect
        {
            BlurRadius = 12,
            ShadowDepth = 2,
            Opacity = 0.16
        };
        panel.Children.Add(_statusBubble);

        var bubbleStack = new StackPanel();
        _statusBubble.Child = bubbleStack;

        _titleText.FontSize = 13;
        _titleText.FontWeight = FontWeights.SemiBold;
        _titleText.Foreground = Brush("#172033");
        _titleText.TextTrimming = TextTrimming.CharacterEllipsis;
        bubbleStack.Children.Add(_titleText);

        _messageText.Margin = new Thickness(0, 3, 0, 0);
        _messageText.FontSize = 11;
        _messageText.Foreground = Brush("#4b5563");
        _messageText.TextWrapping = TextWrapping.Wrap;
        _messageText.MaxHeight = 36;
        bubbleStack.Children.Add(_messageText);

        _spriteLayer.Children.Add(sprite);
        _spriteLayer.Children.Add(fallback);
        panel.Children.Add(_spriteLayer);

        _badgesPanel.Margin = new Thickness(0, 4, 0, 8);
        panel.Children.Add(_badgesPanel);

        return root;
    }

    private ContextMenu BuildContextMenu()
    {
        var menu = new ContextMenu();
        var open = new MenuItem { Header = "Open Control Panel" };
        open.Click += (_, _) => _openControlPanel();
        menu.Items.Add(open);

        var refresh = new MenuItem { Header = "Refresh Pet" };
        refresh.Click += async (_, _) => await RefreshNowAsync().ConfigureAwait(true);
        menu.Items.Add(refresh);

        menu.Items.Add(new Separator());
        var exit = new MenuItem { Header = "Exit Vibestick" };
        exit.Click += (_, _) => _exitApplication();
        menu.Items.Add(exit);
        return menu;
    }

    private System.IO.FileSystemWatcher? CreateStatusWatcher()
    {
        try
        {
            Directory.CreateDirectory(_services.CoderStatusDirectory);
            var watcher = new System.IO.FileSystemWatcher(_services.CoderStatusDirectory, "*.json")
            {
                IncludeSubdirectories = false,
                NotifyFilter = System.IO.NotifyFilters.CreationTime |
                    System.IO.NotifyFilters.FileName |
                    System.IO.NotifyFilters.LastWrite |
                    System.IO.NotifyFilters.Size
            };

            watcher.Changed += (_, _) => ScheduleStatusRefresh();
            watcher.Created += (_, _) => ScheduleStatusRefresh();
            watcher.Deleted += (_, _) => ScheduleStatusRefresh();
            watcher.Renamed += (_, _) => ScheduleStatusRefresh();
            watcher.Error += (_, _) => ScheduleStatusRefresh();
            watcher.EnableRaisingEvents = true;
            return watcher;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private void ScheduleStatusRefresh()
    {
        if (!Dispatcher.CheckAccess())
        {
            _ = Dispatcher.InvokeAsync(ScheduleStatusRefresh);
            return;
        }

        _statusDebounceTimer.Stop();
        _statusDebounceTimer.Start();
    }

    private void Render(PetState state)
    {
        _currentState = state;
        _spriteAnimator.SetMood(state.Mood);
        Title = $"Vibestick Pet - {state.Mood}";
        SetNativeTitle(Title);
        AutomationProperties.SetName(this, Title);
        _titleText.Text = state.Title;
        _messageText.Text = state.Message;
        ToolTip = $"{state.Title}: {state.Message}";
        RenderTaskCards(state);
        _statusBubble.Visibility = _lastTaskCardsTotal > 0 ? Visibility.Collapsed : Visibility.Visible;

        _badgesPanel.Children.Clear();
        foreach (var badge in state.Badges.Take(3))
        {
            _badgesPanel.Children.Add(new Border
            {
                Margin = new Thickness(2, 0, 2, 0),
                Padding = new Thickness(8, 3, 8, 4),
                Background = BadgeBrush(badge.Kind),
                CornerRadius = new CornerRadius(8),
                Child = new TextBlock
                {
                    Text = badge.Text,
                    FontSize = 11,
                    Foreground = Brushes.White,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    MaxWidth = 88
                }
            });
        }

        WriteRuntimeSnapshot(state);
    }

    private void RenderTaskCards(PetState state)
    {
        var taskCoders = state.Coders
            .Where(ShouldShowTaskCard)
            .OrderBy(static status => PetStateResolver.GetPhasePriority(status.Phase))
            .ThenByDescending(static status => status.UpdatedAtUtc)
            .ThenBy(static status => status.TaskSummary ?? status.Agent, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        _lastTaskCardsTotal = taskCoders.Length;
        if (taskCoders.Length == 0)
        {
            _taskHost.Visibility = Visibility.Collapsed;
            _taskCardsPanel.Children.Clear();
            _lastTaskCardsVisible = 0;
            _lastTaskCardsHidden = 0;
            _lastRenderedTaskCards = Array.Empty<TaskCardSnapshot>();
            return;
        }

        _taskHost.Visibility = Visibility.Visible;
        var visibleCoders = _taskListExpanded
            ? taskCoders
            : taskCoders.Take(CollapsedTaskCardLimit).ToArray();
        var hiddenCount = Math.Max(0, taskCoders.Length - visibleCoders.Length);
        _lastTaskCardsVisible = visibleCoders.Length;
        _lastTaskCardsHidden = hiddenCount;

        _taskToggleButton.Visibility = taskCoders.Length > CollapsedTaskCardLimit ? Visibility.Visible : Visibility.Collapsed;
        _taskToggleButton.Content = _taskListExpanded ? "^" : "v";
        _taskToggleButton.ToolTip = _taskListExpanded ? "Collapse sessions" : "Expand sessions";
        _taskOverflowText.Text = !_taskListExpanded && hiddenCount > 0 ? $"+{hiddenCount}" : string.Empty;

        _taskScrollViewer.MaxHeight = _taskListExpanded ? ExpandedTaskListMaxHeight : double.PositiveInfinity;
        _taskScrollViewer.VerticalScrollBarVisibility = _taskListExpanded
            ? ScrollBarVisibility.Auto
            : ScrollBarVisibility.Disabled;

        var cardBrushes = GetTaskCardBrushes();
        var snapshots = new List<TaskCardSnapshot>();
        _taskCardsPanel.Children.Clear();
        foreach (var coder in visibleCoders)
        {
            var summary = GetTaskSummary(coder);
            var status = GetTaskStatus(coder, state.UpdatedAtUtc);
            var detail = GetTaskDetail(coder, status);
            snapshots.Add(new TaskCardSnapshot(
                coder.Agent,
                coder.SessionId,
                summary,
                detail,
                coder.Phase,
                status,
                coder.Workspace,
                coder.SourcePath,
                GetClickTarget(coder),
                GetPhaseIconName(coder.Phase)));
            _taskCardsPanel.Children.Add(BuildTaskCard(coder, summary, detail, status, cardBrushes));
        }

        _lastRenderedTaskCards = snapshots;
    }

    private Border BuildTaskCard(
        CoderAgentStatus coder,
        string summary,
        string detail,
        string status,
        TaskCardBrushes cardBrushes)
    {
        var card = new Border
        {
            Width = TaskCardWidth,
            MinHeight = 70,
            Margin = new Thickness(0, 0, 0, 6),
            Padding = new Thickness(12, 8, 10, 9),
            Background = cardBrushes.Background,
            BorderBrush = cardBrushes.Border,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Cursor = InputCursors.Hand,
            ToolTip = $"{summary}: {detail}",
            Effect = new System.Windows.Media.Effects.DropShadowEffect
            {
                BlurRadius = 12,
                ShadowDepth = 2,
                Opacity = cardBrushes.ShadowOpacity
            }
        };
        card.MouseLeftButtonDown += (_, args) => args.Handled = true;
        card.MouseLeftButtonUp += (_, args) =>
        {
            args.Handled = true;
            FocusCoderOrControlPanel(coder);
        };

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        card.Child = grid;

        var summaryText = new TextBlock
        {
            Text = summary,
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            Foreground = cardBrushes.PrimaryText,
            TextWrapping = TextWrapping.NoWrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = TaskCardWidth - 58,
            Margin = new Thickness(0, 0, 12, 3)
        };
        grid.Children.Add(summaryText);

        var detailText = new TextBlock
        {
            Text = detail,
            FontSize = 11,
            Foreground = cardBrushes.SecondaryText,
            TextWrapping = TextWrapping.Wrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            LineHeight = 15,
            MaxHeight = 32,
            MaxWidth = TaskCardWidth - 34,
            Margin = new Thickness(0, 0, 12, 0)
        };
        Grid.SetRow(detailText, 1);
        grid.Children.Add(detailText);

        var phaseIcon = BuildPhaseIcon(coder.Phase, cardBrushes, status);
        Grid.SetColumn(phaseIcon, 1);
        Grid.SetRow(phaseIcon, 0);
        Grid.SetRowSpan(phaseIcon, 2);
        grid.Children.Add(phaseIcon);

        return card;
    }

    private void FocusCoderOrControlPanel(CoderAgentStatus coder)
    {
        if (!WindowFocusService.TryFocusCoderWindow(coder))
        {
            _openControlPanel();
        }
    }

    private static Grid BuildPhaseIcon(CoderAgentPhase phase, TaskCardBrushes cardBrushes, string status)
    {
        var icon = new Grid
        {
            Width = 18,
            Height = 18,
            Margin = new Thickness(6, 1, 0, 0),
            VerticalAlignment = VerticalAlignment.Top,
            ToolTip = status
        };
        icon.Children.Add(new Ellipse
        {
            Width = 17,
            Height = 17,
            Fill = Brush("#ffffff"),
            Stroke = cardBrushes.Border,
            StrokeThickness = 1,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        });
        icon.Children.Add(new Ellipse
        {
            Width = 7,
            Height = 7,
            Fill = PhaseBrush(phase),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        });

        return icon;
    }

    private static bool ShouldShowTaskCard(CoderAgentStatus status)
    {
        if (!string.IsNullOrWhiteSpace(status.SessionId) ||
            !string.IsNullOrWhiteSpace(status.TaskSummary))
        {
            return true;
        }

        return status.Phase is not CoderAgentPhase.Idle and not CoderAgentPhase.Sleeping;
    }

    private static string GetTaskSummary(CoderAgentStatus coder)
    {
        if (!string.IsNullOrWhiteSpace(coder.TaskSummary))
        {
            return coder.TaskSummary!;
        }

        if (!string.IsNullOrWhiteSpace(coder.Workspace))
        {
            var workspaceName = Path.GetFileName(coder.Workspace.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
            if (!string.IsNullOrWhiteSpace(workspaceName))
            {
                return $"{FormatAgentName(coder.Agent)} task in {workspaceName}";
            }
        }

        return $"{FormatAgentName(coder.Agent)} task";
    }

    private static string GetTaskDetail(CoderAgentStatus coder, string status)
    {
        if (!string.IsNullOrWhiteSpace(coder.TaskDetail))
        {
            return coder.TaskDetail!;
        }

        return status;
    }

    private static string GetTaskStatus(CoderAgentStatus coder, DateTimeOffset now)
    {
        var baseStatus = !string.IsNullOrWhiteSpace(coder.Message)
            ? coder.Message!.TrimEnd('.', ' ')
            : coder.Phase switch
            {
                CoderAgentPhase.ToolCalling => "Using a tool",
                CoderAgentPhase.Reasoning => "Thinking",
                CoderAgentPhase.WaitingAuthorization => "Waiting for authorization",
                CoderAgentPhase.Error => "Error",
                CoderAgentPhase.Success => "Finished",
                CoderAgentPhase.Running => "Running",
                CoderAgentPhase.Sleeping => "Sleeping",
                CoderAgentPhase.Offline => "Offline",
                _ => "Active"
            };

        if (coder.Phase is CoderAgentPhase.Reasoning or CoderAgentPhase.ToolCalling or CoderAgentPhase.Running)
        {
            return $"{baseStatus} for {FormatElapsed(now - coder.UpdatedAtUtc)}";
        }

        return baseStatus;
    }

    private static string GetClickTarget(CoderAgentStatus coder)
    {
        if (!string.IsNullOrWhiteSpace(coder.SourcePath))
        {
            return coder.SourcePath!;
        }

        if (coder.ProcessId.HasValue)
        {
            return $"pid:{coder.ProcessId.Value}";
        }

        if (!string.IsNullOrWhiteSpace(coder.SessionId))
        {
            return $"session:{coder.SessionId}";
        }

        return $"agent:{coder.Agent}";
    }

    private static string GetPhaseIconName(CoderAgentPhase phase)
    {
        return phase switch
        {
            CoderAgentPhase.Error => "error",
            CoderAgentPhase.WaitingAuthorization => "authorization",
            CoderAgentPhase.ToolCalling => "tool",
            CoderAgentPhase.Reasoning => "thinking",
            CoderAgentPhase.Success => "success",
            CoderAgentPhase.Offline => "offline",
            CoderAgentPhase.Running => "running",
            CoderAgentPhase.Sleeping => "sleeping",
            _ => "active"
        };
    }

    private static string FormatElapsed(TimeSpan elapsed)
    {
        if (elapsed < TimeSpan.Zero)
        {
            elapsed = TimeSpan.Zero;
        }

        var totalSeconds = Math.Max(0, (int)Math.Floor(elapsed.TotalSeconds));
        if (totalSeconds < 60)
        {
            return $"{totalSeconds}s";
        }

        var minutes = totalSeconds / 60;
        var seconds = totalSeconds % 60;
        return $"{minutes}m{seconds:00}s";
    }

    private static string FormatAgentName(string agent)
    {
        return string.Equals(agent, "codex", StringComparison.OrdinalIgnoreCase)
            ? "Codex"
            : agent;
    }

    private static SolidColorBrush PhaseBrush(CoderAgentPhase phase)
    {
        return phase switch
        {
            CoderAgentPhase.Error => Brush("#e11d48"),
            CoderAgentPhase.WaitingAuthorization => Brush("#f59e0b"),
            CoderAgentPhase.ToolCalling => Brush("#2563eb"),
            CoderAgentPhase.Reasoning => Brush("#7c3aed"),
            CoderAgentPhase.Success => Brush("#16a34a"),
            CoderAgentPhase.Offline => Brush("#64748b"),
            _ => Brush("#0f766e")
        };
    }

    private static TaskCardBrushes GetTaskCardBrushes()
    {
        if (IsSystemLightTheme())
        {
            return new TaskCardBrushes(
                Brush("#f8fbff"),
                Brush("#d5deea"),
                Brush("#172033"),
                Brush("#4b5563"),
                Brush("#eef2ff"),
                0.16);
        }

        return new TaskCardBrushes(
            Brush("#18181b"),
            Brush("#52525b"),
            Brush("#f8fafc"),
            Brush("#d4d4d8"),
            Brush("#27272a"),
            0.26);
    }

    private static bool IsSystemLightTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is not int value || value != 0;
        }
        catch
        {
            return true;
        }
    }

    private void RenderFailure(Exception exception)
    {
        var now = DateTimeOffset.UtcNow;
        Render(new PetState(
            PetMood.PowerWarning,
            "Pet status unavailable",
            exception.Message,
            PrimaryCoder: null,
            Array.Empty<CoderAgentStatus>(),
            new[] { new PetBadge(PetBadgeKind.Warning, "status error") },
            now));
    }

    private void ApplyInitialPlacement()
    {
        var saved = _placementStore.Load();
        if (saved is not null)
        {
            ApplyScale(saved.Scale ?? DefaultScale);
            Left = Clamp(saved.Left, SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - Width);
            Top = Clamp(saved.Top, SystemParameters.VirtualScreenTop, SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - Height);
            return;
        }

        ApplyScale(DefaultScale);
        Left = SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - Width - DefaultMargin;
        Top = SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - Height - DefaultMargin;
    }

    private void SavePlacement()
    {
        _placementStore.Save(new PetWindowPlacement(Left, Top, _scale));
    }

    private void OnMouseLeftButtonDown(object sender, MouseButtonEventArgs args)
    {
        _dragStart = ToScreenDip(args.GetPosition(this));
        _lastDragPoint = _dragStart;
        _windowStart = new Point(Left, Top);
        _resizeStartScale = _scale;
        _pointerInteraction = IsResizeHit(args) ? PointerInteraction.Resize : PointerInteraction.Move;
        _isDragging = false;
        CaptureMouse();
    }

    private void OnMouseMove(object sender, MouseEventArgs args)
    {
        if (args.LeftButton != MouseButtonState.Pressed)
        {
            Cursor = IsResizeHit(args) ? InputCursors.SizeNWSE : InputCursors.Arrow;
            return;
        }

        if (_dragStart is null)
        {
            return;
        }

        var current = ToScreenDip(args.GetPosition(this));
        var delta = current - _dragStart.Value;
        if (!_isDragging && Math.Abs(delta.X) + Math.Abs(delta.Y) < 4)
        {
            return;
        }

        _isDragging = true;
        StopSpriteHover();
        if (_pointerInteraction == PointerInteraction.Resize)
        {
            ResizeFromDrag(delta);
            return;
        }

        UpdateCrawlDirection(current, delta);
        Left = _windowStart.X + delta.X;
        Top = _windowStart.Y + delta.Y;
    }

    private void OnMouseLeftButtonUp(object sender, MouseButtonEventArgs args)
    {
        ReleaseMouseCapture();
        if (_dragStart is not null && !_isDragging && _pointerInteraction == PointerInteraction.Move)
        {
            HandlePrimaryClick();
        }

        if (_isDragging)
        {
            SavePlacement();
        }

        StopCrawling();
        _dragStart = null;
        _lastDragPoint = null;
        _isDragging = false;
        Cursor = IsResizeHit(args) ? InputCursors.SizeNWSE : InputCursors.Arrow;
    }

    private void StartSpriteHover()
    {
        if (_isDragging)
        {
            return;
        }

        _spriteAnimator.SetHovering(true);
        _frameTimer.Interval = HoverFrameInterval;
    }

    private void StopSpriteHover()
    {
        _spriteAnimator.SetHovering(false);
        if (!_isDragging)
        {
            _frameTimer.Interval = MoodFrameInterval;
        }
    }

    private void UpdateCrawlDirection(Point current, Vector totalDelta)
    {
        var previous = _lastDragPoint ?? _dragStart ?? current;
        var stepX = current.X - previous.X;
        var directionX = Math.Abs(stepX) >= CrawlDirectionThreshold ? stepX : totalDelta.X;
        _lastDragPoint = current;

        if (Math.Abs(directionX) < CrawlDirectionThreshold)
        {
            return;
        }

        _spriteAnimator.SetCrawlDirection(directionX < 0
            ? PetSpriteCrawlDirection.Left
            : PetSpriteCrawlDirection.Right);
        _frameTimer.Interval = CrawlFrameInterval;
    }

    private void StopCrawling()
    {
        _spriteAnimator.SetCrawlDirection(null);
        _spriteAnimator.SetHovering(false);
        _frameTimer.Interval = MoodFrameInterval;
    }

    private void HandlePrimaryClick()
    {
        if (_currentState?.Mood == PetMood.WaitingAuthorization &&
            WindowFocusService.TryFocusProcessWindow(_currentState.PrimaryCoder?.ProcessId))
        {
            return;
        }

        _openControlPanel();
    }

    private Point ToScreenDip(Point localPoint)
    {
        var screenPoint = PointToScreen(localPoint);
        var source = PresentationSource.FromVisual(this);
        return source?.CompositionTarget?.TransformFromDevice.Transform(screenPoint) ?? screenPoint;
    }

    private bool IsResizeHit(MouseEventArgs args)
    {
        if (_spriteLayer.ActualWidth <= 0 || _spriteLayer.ActualHeight <= 0)
        {
            return false;
        }

        var point = args.GetPosition(_spriteLayer);
        return point.X >= -ResizeHitPadding &&
            point.X <= _spriteLayer.ActualWidth + ResizeHitPadding &&
            point.Y >= _spriteLayer.ActualHeight * ResizeHitSpriteYRatio;
    }

    private void ResizeFromDrag(Vector delta)
    {
        var dominantDelta = Math.Abs(delta.X) >= Math.Abs(delta.Y) ? delta.X : delta.Y;
        ApplyScale(_resizeStartScale + dominantDelta / ResizeDragDivisor);
        ClampToVirtualScreen();
    }

    private void ApplyScale(double scale)
    {
        _scale = Clamp(scale, MinScale, MaxScale);
        _rootScale.ScaleX = _scale;
        _rootScale.ScaleY = _scale;
        Width = BaseWindowWidth * _scale;
        Height = BaseWindowHeight * _scale;
    }

    private void ClampToVirtualScreen()
    {
        Left = Clamp(
            Left,
            SystemParameters.VirtualScreenLeft,
            SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - Width);
        Top = Clamp(
            Top,
            SystemParameters.VirtualScreenTop,
            SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - Height);
    }

    private static double Clamp(double value, double minimum, double maximum)
    {
        return Math.Max(minimum, Math.Min(value, maximum));
    }

    private static SolidColorBrush BadgeBrush(PetBadgeKind kind)
    {
        return kind switch
        {
            PetBadgeKind.Warning => Brush("#e11d48"),
            PetBadgeKind.Battery => Brush("#0f766e"),
            PetBadgeKind.Guard => Brush("#7c3aed"),
            _ => Brush("#334155")
        };
    }

    private static SolidColorBrush Brush(string color)
    {
        return new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));
    }

    private void WriteRuntimeSnapshot(PetState state)
    {
        try
        {
            Directory.CreateDirectory(_services.CoderStatusDirectory);
            var snapshot = new
            {
                state.Mood,
                state.Title,
                state.Message,
                Left,
                Top,
                Width,
                Height,
                Scale = _scale,
                Sprite = _spriteAnimator.CurrentFrame,
                StatusBubbleVisible = _statusBubble.Visibility == Visibility.Visible,
                TaskCards = new
                {
                    Total = _lastTaskCardsTotal,
                    Visible = _lastTaskCardsVisible,
                    Hidden = _lastTaskCardsHidden,
                    Expanded = _taskListExpanded,
                    Items = _lastRenderedTaskCards
                },
                UpdatedAtUtc = DateTimeOffset.UtcNow
            };
            File.WriteAllText(
                Path.Combine(_services.CoderStatusDirectory, "pet-runtime-state.snapshot"),
                JsonSerializer.Serialize(snapshot, SnapshotJsonOptions));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }
    }

    private void SetNativeTitle(string title)
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle != IntPtr.Zero)
        {
            NativeMethods.SetWindowText(handle, title);
        }
    }

    private static class NativeMethods
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern bool SetWindowText(IntPtr hWnd, string lpString);
    }

    private sealed record TaskCardBrushes(
        SolidColorBrush Background,
        SolidColorBrush Border,
        SolidColorBrush PrimaryText,
        SolidColorBrush SecondaryText,
        SolidColorBrush ButtonBackground,
        double ShadowOpacity);

    private sealed record TaskCardSnapshot(
        string Agent,
        string? SessionId,
        string Summary,
        string Detail,
        CoderAgentPhase Phase,
        string Status,
        string? Workspace,
        string? SourcePath,
        string ClickTarget,
        string PhaseIcon);

    private enum PointerInteraction
    {
        Move,
        Resize
    }
}
