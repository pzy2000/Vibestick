namespace Vibestick.Core;

public sealed record DeviceIdentity(
    string Name,
    string VendorId,
    string ProductId,
    Guid? InterfaceGuid = null)
{
    public string NormalizedVendorId { get; } = NormalizeHexId(VendorId);

    public string NormalizedProductId { get; } = NormalizeHexId(ProductId);

    public bool MatchesInstanceId(string? instanceId)
    {
        if (string.IsNullOrWhiteSpace(instanceId))
        {
            return false;
        }

        var normalized = instanceId.ToUpperInvariant();
        return normalized.Contains($"VID_{NormalizedVendorId}&PID_{NormalizedProductId}", StringComparison.Ordinal);
    }

    private static string NormalizeHexId(string value)
    {
        var trimmed = value.Trim()
            .Replace("0x", string.Empty, StringComparison.OrdinalIgnoreCase)
            .Replace("&H", string.Empty, StringComparison.OrdinalIgnoreCase);
        return trimmed.PadLeft(4, '0').ToUpperInvariant();
    }
}

public sealed record VibestickDeviceOptions(
    DeviceIdentity Device,
    DeviceIdentity Bootloader,
    string BootloaderVolumeLabel,
    string BootloaderBoardId,
    TimeSpan LaunchDebounce)
{
    public static readonly Guid DefaultInterfaceGuid = new("af77c38f-7c8c-4d86-9f2d-f7c40a8e08e5");

    public static VibestickDeviceOptions Default { get; } = new(
        new DeviceIdentity("Vibestick RP2040 WinUSB", "2E8A", "4002", DefaultInterfaceGuid),
        new DeviceIdentity("Raspberry Pi RP2 UF2 Bootloader", "2E8A", "0003"),
        "RPI-RP2",
        "RPI-RP2",
        TimeSpan.FromSeconds(5));
}

public sealed record DeviceSnapshot(
    string? InstanceId = null,
    string? FriendlyName = null,
    Guid? InterfaceGuid = null,
    string? DriveRoot = null,
    string? VolumeLabel = null,
    string? BoardInfoText = null);

public enum DeviceDetectionKind
{
    None,
    Bootloader,
    VibestickDevice
}

public sealed record DeviceDetectionResult(
    DeviceDetectionKind Kind,
    string Message,
    DeviceIdentity? MatchedIdentity = null,
    DeviceSnapshot? Snapshot = null)
{
    public static DeviceDetectionResult None { get; } = new(DeviceDetectionKind.None, "No Vibestick device detected.");
}

public enum DeviceAutoLaunchAction
{
    None,
    Launch,
    AlreadyRunning,
    Debounced,
    BootloaderOnly
}

public sealed record DeviceAutoLaunchDecision(
    DeviceAutoLaunchAction Action,
    string Message);
