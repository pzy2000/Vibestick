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
    double MotionOffsetX = 0,
    double MotionOffsetY = 0);

public sealed class PetSpriteAnimator
{
    private const int FrameWidth = 192;
    private const int FrameHeight = 208;
    private const int MoodFrameCount = 2;
    private const int CrawlFrameCount = 4;
    private const int HoverFrameCount = 2;

    private readonly Image _image;
    private readonly TextBlock _fallback;
    private readonly BitmapSource? _sheet;
    private readonly ScaleTransform _directionTransform = new(1, 1);
    private readonly TranslateTransform _motionTransform = new();
    private PetMood _mood = PetMood.Idle;
    private PetSpriteCrawlDirection? _crawlDirection;
    private bool _isHovering;
    private int _frameIndex;

    public PetSpriteAnimator(Image image, TextBlock fallback)
    {
        _image = image;
        _fallback = fallback;
        _sheet = LoadSheet();
        var transformGroup = new TransformGroup();
        transformGroup.Children.Add(_directionTransform);
        transformGroup.Children.Add(_motionTransform);
        _image.RenderTransformOrigin = new System.Windows.Point(0.5, 0.5);
        _image.RenderTransform = transformGroup;
        _image.Visibility = _sheet is null ? System.Windows.Visibility.Collapsed : System.Windows.Visibility.Visible;
        _fallback.Visibility = _sheet is null ? System.Windows.Visibility.Visible : System.Windows.Visibility.Collapsed;
        Render();
    }

    public PetSpriteFrameSnapshot CurrentFrame { get; private set; } = new("seated", 1, 4, 0, null);

    public void SetMood(PetMood mood)
    {
        if (_mood == mood)
        {
            return;
        }

        _mood = mood;
        _frameIndex = 0;
        Render();
    }

    public void SetCrawlDirection(PetSpriteCrawlDirection? direction)
    {
        if (_crawlDirection == direction)
        {
            return;
        }

        _crawlDirection = direction;
        _frameIndex = 0;
        Render();
    }

    public void SetHovering(bool isHovering)
    {
        if (_isHovering == isHovering)
        {
            return;
        }

        _isHovering = isHovering;
        if (_crawlDirection is null)
        {
            _frameIndex = 0;
            Render();
        }
    }

    public void AdvanceFrame()
    {
        _frameIndex = (_frameIndex + 1) % GetActiveFrameCount();
        Render();
    }

    private void Render()
    {
        var frame = GetActiveFrame();
        CurrentFrame = frame;
        _fallback.Text = frame.Pose;
        if (_sheet is null)
        {
            return;
        }

        var (column, row) = (frame.Column, frame.Row);
        _directionTransform.ScaleX = _crawlDirection == PetSpriteCrawlDirection.Left ? -1 : 1;
        _motionTransform.X = frame.MotionOffsetX;
        _motionTransform.Y = frame.MotionOffsetY;
        _image.Source = new CroppedBitmap(
            _sheet,
            new System.Windows.Int32Rect(
                column * FrameWidth,
                row * FrameHeight,
                FrameWidth,
                FrameHeight));
    }

    private int GetActiveFrameCount()
    {
        if (_crawlDirection is not null)
        {
            return CrawlFrameCount;
        }

        return _isHovering ? HoverFrameCount : MoodFrameCount;
    }

    private PetSpriteFrameSnapshot GetActiveFrame()
    {
        if (_crawlDirection is not null)
        {
            var (column, row) = GetCrawlFrame(_frameIndex);
            var (offsetX, offsetY) = GetCrawlMotion(_frameIndex, _crawlDirection.Value);
            return new PetSpriteFrameSnapshot(
                "crawling",
                column,
                row,
                _frameIndex,
                _crawlDirection.ToString(),
                offsetX,
                offsetY);
        }

        if (_isHovering)
        {
            var (column, row) = GetHoverFrame(_frameIndex);
            return new PetSpriteFrameSnapshot("hover-bob", column, row, _frameIndex, null);
        }

        var moodPose = _mood == PetMood.Running ? "standing" : "seated";
        var (moodColumn, moodRow) = GetMoodFrame(_mood, _frameIndex);
        return new PetSpriteFrameSnapshot(moodPose, moodColumn, moodRow, _frameIndex, null);
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

    private static (int Column, int Row) GetCrawlFrame(int frameIndex)
    {
        return (frameIndex % CrawlFrameCount, 1);
    }

    private static (double OffsetX, double OffsetY) GetCrawlMotion(int frameIndex, PetSpriteCrawlDirection direction)
    {
        var signedStride = direction == PetSpriteCrawlDirection.Right ? 1 : -1;
        return (frameIndex % CrawlFrameCount) switch
        {
            0 => (-2 * signedStride, 1),
            1 => (2 * signedStride, -7),
            2 => (5 * signedStride, -3),
            _ => (1 * signedStride, 2)
        };
    }

    private static (int Column, int Row) GetHoverFrame(int frameIndex)
    {
        return frameIndex % HoverFrameCount == 0
            ? (1, 4)
            : (0, 1);
    }

    private static (int Column, int Row) GetMoodFrame(PetMood mood, int frameIndex)
    {
        if (mood == PetMood.Running)
        {
            return (frameIndex % MoodFrameCount, 2);
        }

        return (1 + frameIndex % MoodFrameCount, 4);
    }
}
