using System.Windows.Media;
using System.Windows.Media.Imaging;
using Vibestick.Core;
using Directory = System.IO.Directory;
using File = System.IO.File;
using FileFormatException = System.IO.FileFormatException;
using IOException = System.IO.IOException;
using Path = System.IO.Path;

namespace Vibestick.Gui;

public sealed class WpfPetAtlasCodec : IPetAtlasCodec
{
    public PetAtlasInfo ReadInfo(string path)
    {
        var bitmap = LoadBitmap(path);
        return new PetAtlasInfo(
            bitmap.PixelWidth,
            bitmap.PixelHeight,
            HasAlpha(bitmap),
            DetectFormat(path));
    }

    public void NormalizeToPng(string sourcePath, string targetPath)
    {
        var bitmap = LoadBitmap(sourcePath);
        var directory = Path.GetDirectoryName(targetPath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(targetPath);
        encoder.Save(stream);
    }

    private static BitmapSource LoadBitmap(string path)
    {
        try
        {
            using var stream = File.OpenRead(path);
            var decoder = BitmapDecoder.Create(
                stream,
                BitmapCreateOptions.PreservePixelFormat,
                BitmapCacheOption.OnLoad);
            if (decoder.Frames.Count == 0)
            {
                throw new PetLibraryException("Pet spritesheet did not contain an image frame.");
            }

            var frame = decoder.Frames[0];
            frame.Freeze();
            return frame;
        }
        catch (NotSupportedException exception)
        {
            throw new PetLibraryException($"Pet spritesheet format is not supported by this system: {exception.Message}");
        }
        catch (FileFormatException exception)
        {
            throw new PetLibraryException($"Pet spritesheet format is not supported by this system: {exception.Message}");
        }
        catch (IOException exception)
        {
            throw new PetLibraryException($"Could not read pet spritesheet: {exception.Message}");
        }
    }

    private static bool HasAlpha(BitmapSource bitmap)
    {
        if (bitmap.Format == PixelFormats.Bgra32 ||
            bitmap.Format == PixelFormats.Pbgra32 ||
            bitmap.Format == PixelFormats.Rgba64 ||
            bitmap.Format == PixelFormats.Prgba64 ||
            bitmap.Format == PixelFormats.Rgba128Float ||
            bitmap.Format == PixelFormats.Prgba128Float)
        {
            return true;
        }

        return bitmap.Palette?.Colors.Any(static color => color.A < byte.MaxValue) == true;
    }

    private static string DetectFormat(string path)
    {
        var extension = Path.GetExtension(path).TrimStart('.').ToUpperInvariant();
        return string.IsNullOrWhiteSpace(extension) ? "IMAGE" : extension;
    }
}
