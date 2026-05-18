using System.Text.Json;
using System.IO;

namespace Vibestick.Gui;

public sealed record PetWindowPlacement(
    double Left,
    double Top,
    double? Scale = null,
    bool? WalkingEnabled = null);

public sealed class PetWindowStateStore
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    public PetWindowStateStore(string? path = null)
    {
        Path = path ?? GetDefaultPath();
    }

    public string Path { get; }

    public PetWindowPlacement? Load()
    {
        if (!File.Exists(Path))
        {
            return null;
        }

        try
        {
            var json = File.ReadAllText(Path);
            return JsonSerializer.Deserialize<PetWindowPlacement>(json, JsonOptions);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }

    public void Save(PetWindowPlacement placement)
    {
        var directory = System.IO.Path.GetDirectoryName(Path);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        File.WriteAllText(Path, JsonSerializer.Serialize(placement, JsonOptions));
    }

    public static string GetDefaultPath()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return System.IO.Path.Combine(localAppData, "Vibestick", "pet-window.json");
    }
}
