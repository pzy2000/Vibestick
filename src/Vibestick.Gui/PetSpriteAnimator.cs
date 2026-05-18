using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Vibestick.Core;
using Image = System.Windows.Controls.Image;
using Path = System.IO.Path;

namespace Vibestick.Gui;

public enum PetSpriteCrawlDirection
{
    Left,
    Right
}

public sealed record PetSpriteFrameSnapshot(
    string Pose,
    int Column,
    int Row,
    int FrameIndex,
    string? Direction,
    string ClipName = "seated_blink",
    string FrameKey = "r0c0",
    int CatalogFrameCount = 57,
    double MotionOffsetX = 0,
    double MotionOffsetY = 0)
{
    public IReadOnlyList<string> CatalogFrameKeys { get; init; } = Array.Empty<string>();
}

public sealed class PetSpriteAnimator
{
    private const int FrameWidth = 192;
    private const int FrameHeight = 208;
    private const int CatalogFrameTotal = 57;
    private static readonly TimeSpan DefaultRandomDelay = TimeSpan.FromSeconds(6);
    private static readonly IReadOnlyDictionary<string, PetAnimationClip> Clips = BuildClips();
    private static readonly IReadOnlyList<string> CatalogFrameKeys = Clips.Values
        .SelectMany(static clip => clip.Frames.Select(static frame => frame.Key))
        .Distinct(StringComparer.OrdinalIgnoreCase)
        .OrderBy(static key => key, StringComparer.OrdinalIgnoreCase)
        .ToArray();

    private readonly Image _image;
    private readonly TextBlock _fallback;
    private readonly BitmapSource? _sheet;
    private readonly ScaleTransform _directionTransform = new(1, 1);
    private readonly TranslateTransform _motionTransform = new();
    private readonly Random _random = CreateRandom();
    private readonly bool _useSeededFastSchedule = Environment.GetEnvironmentVariable("VIBESTICK_PET_ANIMATION_SEED") is not null;
    private PetMood _mood = PetMood.Idle;
    private PetSpriteCrawlDirection? _crawlDirection;
    private bool _isHovering;
    private PetAnimationClip _activeClip;
    private PetAnimationClip? _randomActionClip;
    private DateTimeOffset _nextRandomActionAtUtc;
    private int _frameIndex;

    public PetSpriteAnimator(Image image, TextBlock fallback)
    {
        _image = image;
        _fallback = fallback;
        _sheet = LoadSheet();
        _activeClip = Clip("seated_blink");
        _nextRandomActionAtUtc = DateTimeOffset.UtcNow +
            (_useSeededFastSchedule ? TimeSpan.FromMilliseconds(900) : DefaultRandomDelay);
        var transformGroup = new TransformGroup();
        transformGroup.Children.Add(_directionTransform);
        transformGroup.Children.Add(_motionTransform);
        _image.RenderTransformOrigin = new System.Windows.Point(0.5, 0.5);
        _image.RenderTransform = transformGroup;
        _image.Visibility = _sheet is null ? System.Windows.Visibility.Collapsed : System.Windows.Visibility.Visible;
        _fallback.Visibility = _sheet is null ? System.Windows.Visibility.Visible : System.Windows.Visibility.Collapsed;
        Render();
    }

    public PetSpriteFrameSnapshot CurrentFrame { get; private set; } = new("seated", 0, 0, 0, null);

    public TimeSpan CurrentFrameInterval => _activeClip.FrameInterval;

    public int CatalogFrameCount => CatalogFrameTotal;

    public void SetMood(PetMood mood)
    {
        if (_mood == mood)
        {
            return;
        }

        _mood = mood;
        _randomActionClip = null;
        ScheduleNextRandomAction(DateTimeOffset.UtcNow);
        SelectActiveClip(forceReset: true);
        Render();
    }

    public void SetCrawlDirection(PetSpriteCrawlDirection? direction)
    {
        if (_crawlDirection == direction)
        {
            return;
        }

        _crawlDirection = direction;
        if (direction is not null)
        {
            _randomActionClip = null;
        }

        SelectActiveClip(forceReset: true);
        Render();
    }

    public void SetHovering(bool isHovering)
    {
        if (_isHovering == isHovering)
        {
            return;
        }

        _isHovering = isHovering;
        if (isHovering)
        {
            _randomActionClip = null;
        }

        SelectActiveClip(forceReset: true);
        Render();
    }

    public void AdvanceFrame()
    {
        var now = DateTimeOffset.UtcNow;
        var clipChanged = SelectActiveClip(forceReset: false, now: now);

        if (!clipChanged && !_activeClip.Loops && _frameIndex >= _activeClip.Frames.Count - 1)
        {
            _randomActionClip = null;
            ScheduleNextRandomAction(now);
            SelectActiveClip(forceReset: true, now: now);
        }
        else if (!clipChanged)
        {
            _frameIndex = (_frameIndex + 1) % _activeClip.Frames.Count;
        }

        Render();
    }

    private bool SelectActiveClip(bool forceReset, DateTimeOffset? now = null)
    {
        var selected = ResolveClip(now ?? DateTimeOffset.UtcNow);
        if (forceReset || !ReferenceEquals(selected, _activeClip))
        {
            _activeClip = selected;
            _frameIndex = 0;
            return true;
        }

        return false;
    }

    private PetAnimationClip ResolveClip(DateTimeOffset now)
    {
        if (_crawlDirection is not null)
        {
            return Clip("patrol_crawl");
        }

        if (_isHovering)
        {
            return Clip("attention_paw");
        }

        if (IsUrgentMood(_mood))
        {
            _randomActionClip = null;
            return Clip("attention_paw");
        }

        if (_mood == PetMood.Sleeping)
        {
            _randomActionClip = null;
            return Clip("sleepy_nap");
        }

        if (_randomActionClip is not null)
        {
            return _randomActionClip;
        }

        if (CanUseRandomActions(_mood) && now >= _nextRandomActionAtUtc)
        {
            _randomActionClip = ChooseRandomAction(_mood);
            return _randomActionClip;
        }

        return BaseMoodClip(_mood);
    }

    private void Render()
    {
        var frame = _activeClip.Frames[_frameIndex % _activeClip.Frames.Count];
        var direction = _crawlDirection?.ToString();
        CurrentFrame = new PetSpriteFrameSnapshot(
                _activeClip.Pose,
                frame.Column,
                frame.Row,
                _frameIndex,
                direction,
                _activeClip.Name,
                frame.Key,
                CatalogFrameTotal,
                frame.MotionOffsetX,
                frame.MotionOffsetY)
            { CatalogFrameKeys = CatalogFrameKeys };
        _fallback.Text = $"{_activeClip.Name}:{frame.Key}";
        if (_sheet is null)
        {
            return;
        }

        _directionTransform.ScaleX = _activeClip.FlipsWithDirection && _crawlDirection == PetSpriteCrawlDirection.Left ? -1 : 1;
        _motionTransform.X = frame.MotionOffsetX;
        _motionTransform.Y = frame.MotionOffsetY;
        _image.Source = new CroppedBitmap(
            _sheet,
            new System.Windows.Int32Rect(
                frame.Column * FrameWidth,
                frame.Row * FrameHeight,
                FrameWidth,
                FrameHeight));
    }

    private PetAnimationClip ChooseRandomAction(PetMood mood)
    {
        var pool = mood is PetMood.Running or PetMood.Reasoning or PetMood.ToolCalling
            ? new[] { "curious_look", "attention_paw", "playful_stretch", "groom_think" }
            : new[] { "curious_look", "attention_paw", "playful_stretch", "sleepy_nap", "happy_beg", "groom_think" };
        return Clip(pool[_random.Next(pool.Length)]);
    }

    private void ScheduleNextRandomAction(DateTimeOffset now)
    {
        if (!CanUseRandomActions(_mood))
        {
            _nextRandomActionAtUtc = DateTimeOffset.MaxValue;
            return;
        }

        if (_useSeededFastSchedule)
        {
            _nextRandomActionAtUtc = now + TimeSpan.FromMilliseconds(900);
            return;
        }

        var minSeconds = _mood is PetMood.Running or PetMood.Reasoning or PetMood.ToolCalling ? 8 : 6;
        var rangeSeconds = _mood is PetMood.Running or PetMood.Reasoning or PetMood.ToolCalling ? 10 : 8;
        _nextRandomActionAtUtc = now + TimeSpan.FromSeconds(minSeconds + _random.NextDouble() * rangeSeconds);
    }

    private static bool CanUseRandomActions(PetMood mood)
    {
        return mood is PetMood.Idle or
            PetMood.Success or
            PetMood.Offline or
            PetMood.Running or
            PetMood.Reasoning or
            PetMood.ToolCalling;
    }

    private static bool IsUrgentMood(PetMood mood)
    {
        return mood is PetMood.Error or PetMood.WaitingAuthorization or PetMood.PowerWarning;
    }

    private static PetAnimationClip BaseMoodClip(PetMood mood)
    {
        return mood switch
        {
            PetMood.Running or PetMood.Reasoning or PetMood.ToolCalling => Clip("curious_look"),
            PetMood.Sleeping => Clip("sleepy_nap"),
            PetMood.Error or PetMood.WaitingAuthorization or PetMood.PowerWarning => Clip("attention_paw"),
            _ => Clip("seated_blink")
        };
    }

    private static BitmapSource? LoadSheet()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Assets", "PetSprites", "golden-shaded-cat-spritesheet.cleaned.png");
        if (!System.IO.File.Exists(path))
        {
            return null;
        }

        var bitmap = new BitmapImage();
        bitmap.BeginInit();
        bitmap.CacheOption = BitmapCacheOption.OnLoad;
        bitmap.UriSource = new System.Uri(path, System.UriKind.Absolute);
        bitmap.EndInit();
        bitmap.Freeze();
        return bitmap;
    }

    private static Random CreateRandom()
    {
        var seedText = Environment.GetEnvironmentVariable("VIBESTICK_PET_ANIMATION_SEED");
        return int.TryParse(seedText, out var seed) ? new Random(seed) : new Random();
    }

    private static IReadOnlyDictionary<string, PetAnimationClip> BuildClips()
    {
        var clips = new[]
        {
            new PetAnimationClip("seated_blink", "seated", Row(0, 0, 5), TimeSpan.FromMilliseconds(360), Loops: true, FlipsWithDirection: false),
            new PetAnimationClip("patrol_crawl", "crawling", PatrolFrames(), TimeSpan.FromMilliseconds(115), Loops: true, FlipsWithDirection: true),
            new PetAnimationClip("attention_paw", "attention", Row(3, 0, 3), TimeSpan.FromMilliseconds(210), Loops: false, FlipsWithDirection: false),
            new PetAnimationClip("playful_stretch", "stretch", Row(4, 0, 4), TimeSpan.FromMilliseconds(240), Loops: false, FlipsWithDirection: false),
            new PetAnimationClip("sleepy_nap", "sleepy", Row(5, 0, 7), TimeSpan.FromMilliseconds(300), Loops: false, FlipsWithDirection: false),
            new PetAnimationClip("curious_look", "curious", Row(6, 0, 5), TimeSpan.FromMilliseconds(260), Loops: true, FlipsWithDirection: false),
            new PetAnimationClip("happy_beg", "happy", Row(7, 0, 5), TimeSpan.FromMilliseconds(250), Loops: false, FlipsWithDirection: false),
            new PetAnimationClip("groom_think", "grooming", Row(8, 0, 5), TimeSpan.FromMilliseconds(260), Loops: false, FlipsWithDirection: false)
        };

        return clips.ToDictionary(static clip => clip.Name, StringComparer.OrdinalIgnoreCase);
    }

    private static PetAnimationClip Clip(string name)
    {
        return Clips[name];
    }

    private static IReadOnlyList<PetSpriteFrameRef> Row(int row, int firstColumn, int lastColumn)
    {
        return Enumerable.Range(firstColumn, lastColumn - firstColumn + 1)
            .Select(column => new PetSpriteFrameRef(column, row))
            .ToArray();
    }

    private static IReadOnlyList<PetSpriteFrameRef> PatrolFrames()
    {
        return Row(1, 0, 7)
            .Concat(Row(2, 0, 7))
            .Select((frame, index) =>
            {
                var (offsetX, offsetY) = GetPatrolMotion(index);
                return frame with { MotionOffsetX = offsetX, MotionOffsetY = offsetY };
            })
            .ToArray();
    }

    private static (double OffsetX, double OffsetY) GetPatrolMotion(int frameIndex)
    {
        return (frameIndex % 8) switch
        {
            0 => (-3, 1),
            1 => (-1, -4),
            2 => (2, -7),
            3 => (4, -4),
            4 => (5, 1),
            5 => (3, -3),
            6 => (0, -6),
            _ => (-2, -2)
        };
    }

    private sealed record PetSpriteFrameRef(
        int Column,
        int Row,
        double MotionOffsetX = 0,
        double MotionOffsetY = 0)
    {
        public string Key => $"r{Row}c{Column}";
    }

    private sealed record PetAnimationClip(
        string Name,
        string Pose,
        IReadOnlyList<PetSpriteFrameRef> Frames,
        TimeSpan FrameInterval,
        bool Loops,
        bool FlipsWithDirection);
}
