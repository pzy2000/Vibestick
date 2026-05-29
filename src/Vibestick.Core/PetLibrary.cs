using System.IO.Compression;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Vibestick.Core;

public sealed record PetManifest(
    string Id,
    string DisplayName,
    string Description,
    string SpritesheetPath);

public sealed record PetDefinition(
    string Id,
    string DisplayName,
    string Description,
    string SpritesheetPath,
    bool IsBuiltIn);

public sealed record PetImportMetadata(
    string DisplayName,
    string Description);

public sealed record PetAtlasInfo(
    int Width,
    int Height,
    bool HasAlpha,
    string Format);

public interface IPetAtlasCodec
{
    PetAtlasInfo ReadInfo(string path);

    void NormalizeToPng(string sourcePath, string targetPath);
}

public sealed class PetLibraryException : Exception
{
    public PetLibraryException(string message)
        : base(message)
    {
    }
}

public sealed class PetLibraryDuplicateException : PetLibraryException
{
    public PetLibraryDuplicateException(string petId)
        : base($"Pet '{petId}' already exists.")
    {
        PetId = petId;
    }

    public string PetId { get; }
}

public sealed class PetLibrary
{
    public const string BuiltInPetId = "golden-shaded-cat";
    public const int AtlasWidth = 1536;
    public const int AtlasHeight = 1872;

    private const string ManifestFileName = "pet.json";
    private const string SpritesheetFileName = "spritesheet.png";
    private const string SelectionFileName = "pet-selection.json";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true
    };

    private static readonly JsonSerializerOptions ManifestJsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };

    private readonly string _rootDirectory;
    private readonly string _selectionPath;
    private readonly string _builtInSpritesheetPath;
    private readonly IPetAtlasCodec _codec;

    public PetLibrary(
        string rootDirectory,
        string selectionPath,
        string builtInSpritesheetPath,
        IPetAtlasCodec codec)
    {
        _rootDirectory = rootDirectory;
        _selectionPath = selectionPath;
        _builtInSpritesheetPath = builtInSpritesheetPath;
        _codec = codec;
    }

    public static string GetDefaultRootDirectory()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(localAppData, "Vibestick", "pets");
    }

    public static string GetDefaultSelectionPath()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(localAppData, "Vibestick", SelectionFileName);
    }

    public PetDefinition BuiltInPet => new(
        BuiltInPetId,
        "Golden Shaded Cat",
        "The built-in Vibestick desktop pet.",
        _builtInSpritesheetPath,
        IsBuiltIn: true);

    public IReadOnlyList<PetDefinition> GetPets()
    {
        var pets = new List<PetDefinition> { BuiltInPet };
        if (!Directory.Exists(_rootDirectory))
        {
            return pets;
        }

        foreach (var directory in Directory.EnumerateDirectories(_rootDirectory).Order(StringComparer.OrdinalIgnoreCase))
        {
            var manifestPath = Path.Combine(directory, ManifestFileName);
            if (!File.Exists(manifestPath))
            {
                continue;
            }

            try
            {
                var manifest = ReadManifest(manifestPath);
                var spritesheetPath = Path.GetFullPath(Path.Combine(directory, manifest.SpritesheetPath));
                if (!File.Exists(spritesheetPath))
                {
                    continue;
                }
                pets.Add(new PetDefinition(
                    manifest.Id,
                    manifest.DisplayName,
                    manifest.Description,
                    spritesheetPath,
                    IsBuiltIn: false));
            }
            catch (PetLibraryException)
            {
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }

        return pets
            .GroupBy(static pet => pet.Id, StringComparer.OrdinalIgnoreCase)
            .Select(static group => group.First())
            .OrderBy(static pet => pet.IsBuiltIn ? 0 : 1)
            .ThenBy(static pet => pet.DisplayName, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    public PetDefinition GetCurrentPet()
    {
        var selectedId = ReadSelection();
        if (!string.IsNullOrWhiteSpace(selectedId))
        {
            var selected = GetPets().FirstOrDefault(pet =>
                string.Equals(pet.Id, selectedId, StringComparison.OrdinalIgnoreCase));
            if (selected is not null)
            {
                return selected;
            }
        }

        return BuiltInPet;
    }

    public void SelectPet(string petId)
    {
        var pet = GetPets().FirstOrDefault(candidate =>
            string.Equals(candidate.Id, petId, StringComparison.OrdinalIgnoreCase));
        if (pet is null)
        {
            throw new PetLibraryException($"Pet '{petId}' was not found.");
        }

        WriteSelection(pet.Id);
    }

    public PetDefinition ImportRawAtlas(string sourcePath, PetImportMetadata metadata, bool replace = false)
    {
        var displayName = RequireText(metadata.DisplayName, "Pet name is required.");
        var petId = Slugify(displayName);
        if (string.IsNullOrWhiteSpace(petId))
        {
            throw new PetLibraryException("Pet name must contain at least one letter or digit.");
        }

        var description = string.IsNullOrWhiteSpace(metadata.Description)
            ? "Imported Vibestick pet."
            : metadata.Description.Trim();
        return ImportValidatedSpritesheet(
            sourcePath,
            new PetManifest(petId, displayName, description, SpritesheetFileName),
            replace);
    }

    public PetDefinition ImportPackage(string packagePath, bool replace = false)
    {
        var source = Path.GetFullPath(packagePath);
        if (Directory.Exists(source))
        {
            return ImportPackageDirectory(source, replace);
        }

        if (!File.Exists(source))
        {
            throw new PetLibraryException("Pet package file was not found.");
        }

        var stagingRoot = CreateStagingDirectory();
        try
        {
            var extracted = Path.Combine(stagingRoot, "package");
            Directory.CreateDirectory(extracted);
            ExtractZipSafely(source, extracted);
            return ImportPackageDirectory(extracted, replace);
        }
        catch (InvalidDataException exception)
        {
            throw new PetLibraryException($"Could not read pet package: {exception.Message}");
        }
        finally
        {
            DeleteDirectoryQuietly(stagingRoot);
        }
    }

    public void ExportPet(string petId, string outputZipPath)
    {
        var pet = GetPets().FirstOrDefault(candidate =>
            string.Equals(candidate.Id, petId, StringComparison.OrdinalIgnoreCase));
        if (pet is null)
        {
            throw new PetLibraryException($"Pet '{petId}' was not found.");
        }

        var output = Path.GetFullPath(outputZipPath);
        var directory = Path.GetDirectoryName(output);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }
        if (File.Exists(output))
        {
            File.Delete(output);
        }

        using var archive = ZipFile.Open(output, ZipArchiveMode.Create);
        var manifest = new PetManifest(pet.Id, pet.DisplayName, pet.Description, SpritesheetFileName);
        var manifestEntry = archive.CreateEntry(ManifestFileName, CompressionLevel.Optimal);
        using (var stream = manifestEntry.Open())
        {
            JsonSerializer.Serialize(stream, manifest, ManifestJsonOptions);
        }

        var sheetEntry = archive.CreateEntry(SpritesheetFileName, CompressionLevel.Optimal);
        using var entryStream = sheetEntry.Open();
        using var sheetStream = File.OpenRead(pet.SpritesheetPath);
        sheetStream.CopyTo(entryStream);
    }

    public void DeleteCustomPet(string petId)
    {
        if (string.Equals(petId, BuiltInPetId, StringComparison.OrdinalIgnoreCase))
        {
            throw new PetLibraryException("The built-in pet cannot be deleted.");
        }

        var target = Path.Combine(_rootDirectory, Slugify(petId));
        if (!Directory.Exists(target))
        {
            throw new PetLibraryException($"Pet '{petId}' was not found.");
        }

        Directory.Delete(target, recursive: true);
        var current = ReadSelection();
        if (string.Equals(current, petId, StringComparison.OrdinalIgnoreCase))
        {
            WriteSelection(BuiltInPetId);
        }
    }

    private PetDefinition ImportPackageDirectory(string directory, bool replace)
    {
        var manifestPath = Path.Combine(directory, ManifestFileName);
        if (!File.Exists(manifestPath))
        {
            throw new PetLibraryException("Pet package is missing pet.json.");
        }

        var manifest = ReadManifest(manifestPath);
        var spritesheetPath = ResolvePackageSpritesheet(directory, manifest.SpritesheetPath);
        return ImportValidatedSpritesheet(spritesheetPath, manifest, replace);
    }

    private PetDefinition ImportValidatedSpritesheet(string sourcePath, PetManifest manifest, bool replace)
    {
        var source = Path.GetFullPath(sourcePath);
        if (!File.Exists(source))
        {
            throw new PetLibraryException("Pet spritesheet was not found.");
        }

        var normalizedId = Slugify(RequireText(manifest.Id, "Pet id is required."));
        if (string.IsNullOrWhiteSpace(normalizedId))
        {
            throw new PetLibraryException("Pet id must contain at least one letter or digit.");
        }
        var displayName = RequireText(manifest.DisplayName, "Pet display name is required.");
        var description = string.IsNullOrWhiteSpace(manifest.Description)
            ? "Imported Vibestick pet."
            : manifest.Description.Trim();
        ValidateSpritesheet(source);

        var targetDirectory = Path.Combine(_rootDirectory, normalizedId);
        if (Directory.Exists(targetDirectory) && !replace)
        {
            throw new PetLibraryDuplicateException(normalizedId);
        }

        var stagingRoot = CreateStagingDirectory();
        try
        {
            var stagedPet = Path.Combine(stagingRoot, normalizedId);
            Directory.CreateDirectory(stagedPet);
            var targetSheet = Path.Combine(stagedPet, SpritesheetFileName);
            _codec.NormalizeToPng(source, targetSheet);

            var normalizedManifest = new PetManifest(
                normalizedId,
                displayName,
                description,
                SpritesheetFileName);
            File.WriteAllText(
                Path.Combine(stagedPet, ManifestFileName),
                JsonSerializer.Serialize(normalizedManifest, ManifestJsonOptions) + Environment.NewLine);

            Directory.CreateDirectory(_rootDirectory);
            if (Directory.Exists(targetDirectory))
            {
                Directory.Delete(targetDirectory, recursive: true);
            }
            Directory.Move(stagedPet, targetDirectory);
            WriteSelection(normalizedId);

            return new PetDefinition(
                normalizedManifest.Id,
                normalizedManifest.DisplayName,
                normalizedManifest.Description,
                Path.Combine(targetDirectory, normalizedManifest.SpritesheetPath),
                IsBuiltIn: false);
        }
        finally
        {
            DeleteDirectoryQuietly(stagingRoot);
        }
    }

    private void ValidateSpritesheet(string source)
    {
        var info = _codec.ReadInfo(source);
        if (info.Width != AtlasWidth || info.Height != AtlasHeight)
        {
            throw new PetLibraryException(
                $"Pet spritesheet must be {AtlasWidth}x{AtlasHeight}; got {info.Width}x{info.Height}.");
        }
        if (!info.HasAlpha)
        {
            throw new PetLibraryException("Pet spritesheet must include an alpha channel.");
        }
    }

    private static PetManifest ReadManifest(string path)
    {
        try
        {
            var manifest = JsonSerializer.Deserialize<PetManifest>(
                File.ReadAllText(path),
                ManifestJsonOptions);
            if (manifest is null)
            {
                throw new PetLibraryException("Pet manifest is empty.");
            }

            var id = RequireText(manifest.Id, "Pet id is required.");
            var displayName = RequireText(manifest.DisplayName, "Pet display name is required.");
            var spritesheetPath = RequireText(manifest.SpritesheetPath, "Pet spritesheetPath is required.");
            if (Path.IsPathRooted(spritesheetPath) || spritesheetPath.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Contains(".."))
            {
                throw new PetLibraryException("Pet spritesheetPath must stay inside the package.");
            }

            return manifest with
            {
                Id = id,
                DisplayName = displayName,
                Description = manifest.Description?.Trim() ?? string.Empty,
                SpritesheetPath = spritesheetPath
            };
        }
        catch (JsonException exception)
        {
            throw new PetLibraryException($"Could not read pet manifest: {exception.Message}");
        }
    }

    private static string ResolvePackageSpritesheet(string directory, string manifestPath)
    {
        var fullDirectory = Path.GetFullPath(directory);
        var candidate = Path.GetFullPath(Path.Combine(fullDirectory, manifestPath));
        if (!candidate.StartsWith(fullDirectory + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(candidate, fullDirectory, StringComparison.OrdinalIgnoreCase))
        {
            throw new PetLibraryException("Pet spritesheetPath escapes the package directory.");
        }
        if (File.Exists(candidate))
        {
            return candidate;
        }

        foreach (var fallback in new[] { "spritesheet.png", "spritesheet.webp" })
        {
            var fallbackPath = Path.Combine(fullDirectory, fallback);
            if (File.Exists(fallbackPath))
            {
                return fallbackPath;
            }
        }

        throw new PetLibraryException("Pet package is missing the referenced spritesheet.");
    }

    private static void ExtractZipSafely(string zipPath, string destination)
    {
        var fullDestination = Path.GetFullPath(destination);
        using var archive = ZipFile.OpenRead(zipPath);
        foreach (var entry in archive.Entries)
        {
            if (string.IsNullOrEmpty(entry.Name) && entry.FullName.EndsWith("/", StringComparison.Ordinal))
            {
                continue;
            }
            if (Path.IsPathRooted(entry.FullName) ||
                entry.FullName.Split('/', '\\').Contains(".."))
            {
                throw new PetLibraryException("Pet package contains an unsafe path.");
            }

            var targetPath = Path.GetFullPath(Path.Combine(fullDestination, entry.FullName));
            if (!targetPath.StartsWith(fullDestination + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            {
                throw new PetLibraryException("Pet package contains an unsafe path.");
            }

            var targetDirectory = Path.GetDirectoryName(targetPath);
            if (!string.IsNullOrWhiteSpace(targetDirectory))
            {
                Directory.CreateDirectory(targetDirectory);
            }
            entry.ExtractToFile(targetPath, overwrite: false);
        }
    }

    private string? ReadSelection()
    {
        try
        {
            if (!File.Exists(_selectionPath))
            {
                return null;
            }

            var selection = JsonSerializer.Deserialize<PetSelection>(
                File.ReadAllText(_selectionPath),
                ManifestJsonOptions);
            return selection?.CurrentPetId;
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private void WriteSelection(string petId)
    {
        var directory = Path.GetDirectoryName(_selectionPath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        File.WriteAllText(
            _selectionPath,
            JsonSerializer.Serialize(new PetSelection(petId), JsonOptions) + Environment.NewLine);
    }

    private static string RequireText(string value, string message)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new PetLibraryException(message);
        }
        return value.Trim();
    }

    public static string Slugify(string value)
    {
        var result = new string(value
            .Trim()
            .ToLowerInvariant()
            .Select(static character => char.IsAsciiLetterOrDigit(character) ? character : '-')
            .ToArray());
        while (result.Contains("--", StringComparison.Ordinal))
        {
            result = result.Replace("--", "-", StringComparison.Ordinal);
        }
        return result.Trim('-');
    }

    private static string CreateStagingDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), $"vibestick-pet-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return path;
    }

    private static void DeleteDirectoryQuietly(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private sealed record PetSelection(string CurrentPetId);
}

public sealed class PngPetAtlasCodec : IPetAtlasCodec
{
    private static readonly byte[] PngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

    public PetAtlasInfo ReadInfo(string path)
    {
        using var stream = File.OpenRead(path);
        Span<byte> header = stackalloc byte[33];
        try
        {
            stream.ReadExactly(header);
        }
        catch (EndOfStreamException)
        {
            throw new PetLibraryException("Pet spritesheet must be a readable PNG image.");
        }

        if (!header[..8].SequenceEqual(PngSignature) ||
            ReadAscii(header[12..16]) != "IHDR")
        {
            throw new PetLibraryException("Pet spritesheet must be a readable PNG image.");
        }

        var width = ReadBigEndianInt32(header[16..20]);
        var height = ReadBigEndianInt32(header[20..24]);
        var colorType = header[25];
        var hasAlpha = colorType is 4 or 6;
        return new PetAtlasInfo(width, height, hasAlpha, "PNG");
    }

    public void NormalizeToPng(string sourcePath, string targetPath)
    {
        var directory = Path.GetDirectoryName(targetPath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }
        File.Copy(sourcePath, targetPath, overwrite: true);
    }

    private static int ReadBigEndianInt32(ReadOnlySpan<byte> bytes)
    {
        return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    }

    private static string ReadAscii(ReadOnlySpan<byte> bytes)
    {
        return System.Text.Encoding.ASCII.GetString(bytes);
    }
}
