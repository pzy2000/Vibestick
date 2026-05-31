using System.Text.Json;
using System.IO;
using System.Text.Json.Serialization;

namespace Vibestick.Gui;

public sealed record PetWindowPlacement(
    double? Left = null,
    double? Top = null,
    double? Scale = null,
    bool? WalkingEnabled = null,
    string? LanguagePreference = null,
    double? RandomActionFrequency = null,
    double? WalkSpeedMultiplier = null,
    double? WanderFrequency = null)
{
    [JsonIgnore]
    public bool HasWindowPosition => Left is not null && Top is not null;

    [JsonIgnore]
    public PetActionFrequencySettings ActionFrequencySettings => new PetActionFrequencySettings()
    {
        RandomActionFrequency = RandomActionFrequency ?? PetActionFrequencySettings.Default.RandomActionFrequency,
        WalkSpeedMultiplier = WalkSpeedMultiplier ?? PetActionFrequencySettings.Default.WalkSpeedMultiplier,
        WanderFrequency = WanderFrequency ?? PetActionFrequencySettings.Default.WanderFrequency
    }.Clamped();
}

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

    public PetActionFrequencySettings LoadActionFrequencySettings()
    {
        return Load()?.ActionFrequencySettings ?? PetActionFrequencySettings.Default;
    }

    public GuiLanguagePreference LoadLanguagePreference()
    {
        return GuiLanguagePreferenceExtensions.ParseLanguagePreference(Load()?.LanguagePreference);
    }

    public void SaveLanguagePreference(GuiLanguagePreference preference)
    {
        var placement = Load() ?? new PetWindowPlacement();
        Save(placement with
        {
            LanguagePreference = preference.ToStorageValue()
        });
    }

    public void SaveActionFrequencySettings(PetActionFrequencySettings settings)
    {
        var clamped = settings.Clamped();
        var placement = Load() ?? new PetWindowPlacement();
        Save(placement with
        {
            RandomActionFrequency = clamped.RandomActionFrequency,
            WalkSpeedMultiplier = clamped.WalkSpeedMultiplier,
            WanderFrequency = clamped.WanderFrequency
        });
    }

    public static string GetDefaultPath()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return System.IO.Path.Combine(localAppData, "Vibestick", "pet-window.json");
    }
}
