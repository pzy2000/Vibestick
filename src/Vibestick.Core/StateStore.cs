using System.Text.Json;
using System.Text.Json.Serialization;

namespace Vibestick.Core;

public interface IStateStore
{
    string StatePath { get; }

    Task<StateLoadResult> LoadAsync(CancellationToken cancellationToken = default);

    Task SaveAsync(VibestickState state, CancellationToken cancellationToken = default);
}

public sealed class JsonFileStateStore : IStateStore
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };

    public JsonFileStateStore(string? statePath = null)
    {
        StatePath = statePath ?? GetDefaultStatePath();
    }

    public string StatePath { get; }

    public async Task<StateLoadResult> LoadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(StatePath))
        {
            return new StateLoadResult(VibestickState.Empty(), WasCorrupted: false, Warning: null);
        }

        try
        {
            await using var stream = File.OpenRead(StatePath);
            var state = await JsonSerializer.DeserializeAsync<VibestickState>(
                    stream,
                    SerializerOptions,
                    cancellationToken)
                .ConfigureAwait(false);

            return new StateLoadResult(
                state ?? VibestickState.Empty(),
                WasCorrupted: false,
                Warning: null);
        }
        catch (Exception exception) when (exception is JsonException or IOException or UnauthorizedAccessException)
        {
            return new StateLoadResult(
                VibestickState.Empty(),
                WasCorrupted: true,
                Warning: $"State file could not be read and will be ignored: {exception.Message}");
        }
    }

    public async Task SaveAsync(VibestickState state, CancellationToken cancellationToken = default)
    {
        state.UpdatedAtUtc = DateTimeOffset.UtcNow;
        var directory = Path.GetDirectoryName(StatePath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var temporaryPath = $"{StatePath}.tmp";
        await using (var stream = File.Create(temporaryPath))
        {
            await JsonSerializer.SerializeAsync(stream, state, SerializerOptions, cancellationToken)
                .ConfigureAwait(false);
        }

        if (File.Exists(StatePath))
        {
            File.Replace(temporaryPath, StatePath, destinationBackupFileName: null);
        }
        else
        {
            File.Move(temporaryPath, StatePath);
        }
    }

    public static string GetDefaultStatePath()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(localAppData, "Vibestick", "state.json");
    }
}

