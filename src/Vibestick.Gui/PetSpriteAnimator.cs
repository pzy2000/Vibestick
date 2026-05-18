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

public sealed class PetSpriteAnimator
{
    private const int FrameWidth = 192;
    private const int FrameHeight = 208;
    private const int MoodFrameCount = 2;
    private const int CrawlFrameCount = 4;

    private readonly Image _image;
    private readonly TextBlock _fallback;
    private readonly BitmapSource? _sheet;
    private readonly ScaleTransform _directionTransform = new(1, 1);
    private PetMood _mood = PetMood.Idle;
    private PetSpriteCrawlDirection? _crawlDirection;
    private int _frameIndex;

    public PetSpriteAnimator(Image image, TextBlock fallback)
    {
        _image = image;
        _fallback = fallback;
        _sheet = LoadSheet();
        _image.RenderTransformOrigin = new System.Windows.Point(0.5, 0.5);
        _image.RenderTransform = _directionTransform;
        _image.Visibility = _sheet is null ? System.Windows.Visibility.Collapsed : System.Windows.Visibility.Visible;
        _fallback.Visibility = _sheet is null ? System.Windows.Visibility.Visible : System.Windows.Visibility.Collapsed;
        Render();
    }

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

    public void AdvanceFrame()
    {
        _frameIndex = (_frameIndex + 1) % GetActiveFrameCount();
        Render();
    }

    private void Render()
    {
        _fallback.Text = _crawlDirection is null ? _mood.ToString() : $"Crawling {_crawlDirection}";
        if (_sheet is null)
        {
            return;
        }

        var (column, row) = _crawlDirection is null
            ? GetMoodFrame(_mood, _frameIndex)
            : GetCrawlFrame(_frameIndex);
        _directionTransform.ScaleX = _crawlDirection == PetSpriteCrawlDirection.Left ? -1 : 1;
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
        return _crawlDirection is null ? MoodFrameCount : CrawlFrameCount;
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

    private static (int Column, int Row) GetMoodFrame(PetMood mood, int frameIndex)
    {
        return mood switch
        {
            PetMood.Sleeping => (2 + frameIndex, 5),
            PetMood.Running => (frameIndex, 1),
            PetMood.Reasoning => (4 + frameIndex, 7),
            PetMood.ToolCalling => (frameIndex, 1),
            PetMood.WaitingAuthorization => (1 + frameIndex, 3),
            PetMood.Error => (frameIndex, 5),
            PetMood.Success => (1 + frameIndex, 7),
            PetMood.Offline => (2 + frameIndex, 5),
            PetMood.PowerWarning => (6 + frameIndex, 5),
            _ => (frameIndex, 0)
        };
    }
}
