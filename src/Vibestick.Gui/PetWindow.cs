using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Vibestick.Core;
using Brushes = System.Windows.Media.Brushes;
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
    private const double BaseWindowWidth = 248;
    private const double BaseWindowHeight = 292;
    private const double DefaultScale = 1.0;
    private const double MinScale = 0.35;
    private const double MaxScale = 1.5;
    private const double DefaultMargin = 16;
    private const double ResizeDragDivisor = 220;
    private const double ResizeHitPadding = 16;
    private const double ResizeHitSpriteYRatio = 0.45;

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
    private readonly TextBlock _titleText = new();
    private readonly TextBlock _messageText = new();
    private readonly StackPanel _badgesPanel = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly ScaleTransform _rootScale = new(DefaultScale, DefaultScale);
    private readonly Grid _spriteLayer = new()
    {
        Width = 184,
        Height = 198,
        HorizontalAlignment = HorizontalAlignment.Center
    };
    private readonly PetSpriteAnimator _spriteAnimator;
    private PetState? _currentState;
    private bool _isRefreshing;
    private Point? _dragStart;
    private Point _windowStart;
    private bool _isDragging;
    private PointerInteraction _pointerInteraction;
    private double _scale = DefaultScale;
    private double _resizeStartScale = DefaultScale;

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

        _frameTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(420) };
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

        var bubble = new Border
        {
            Width = 228,
            MinHeight = 68,
            Padding = new Thickness(12, 9, 12, 9),
            Margin = new Thickness(10, 8, 10, 4),
            Background = Brush("#f8fbff"),
            BorderBrush = Brush("#d5deea"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Effect = new System.Windows.Media.Effects.DropShadowEffect
            {
                BlurRadius = 12,
                ShadowDepth = 2,
                Opacity = 0.16
            }
        };
        panel.Children.Add(bubble);

        var bubbleStack = new StackPanel();
        bubble.Child = bubbleStack;

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
        if (_pointerInteraction == PointerInteraction.Resize)
        {
            ResizeFromDrag(delta);
            return;
        }

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

        _dragStart = null;
        _isDragging = false;
        Cursor = IsResizeHit(args) ? InputCursors.SizeNWSE : InputCursors.Arrow;
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

    private enum PointerInteraction
    {
        Move,
        Resize
    }
}
