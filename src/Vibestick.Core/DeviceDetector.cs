namespace Vibestick.Core;

public static class DeviceDetector
{
    public static DeviceDetectionResult Detect(
        IEnumerable<DeviceSnapshot> snapshots,
        VibestickDeviceOptions? options = null)
    {
        options ??= VibestickDeviceOptions.Default;
        var snapshotList = snapshots.ToList();

        var deviceSnapshot = snapshotList.FirstOrDefault(snapshot => IsVibestickDevice(snapshot, options));
        if (deviceSnapshot is not null)
        {
            return new DeviceDetectionResult(
                DeviceDetectionKind.VibestickDevice,
                $"Detected {options.Device.Name}.",
                options.Device,
                deviceSnapshot);
        }

        var bootloaderSnapshot = snapshotList.FirstOrDefault(snapshot => IsBootloader(snapshot, options));
        if (bootloaderSnapshot is not null)
        {
            return new DeviceDetectionResult(
                DeviceDetectionKind.Bootloader,
                "Detected RP2 bootloader; waiting for Vibestick firmware.",
                options.Bootloader,
                bootloaderSnapshot);
        }

        return DeviceDetectionResult.None;
    }

    public static bool IsVibestickDevice(DeviceSnapshot snapshot, VibestickDeviceOptions? options = null)
    {
        options ??= VibestickDeviceOptions.Default;
        return options.Device.MatchesInstanceId(snapshot.InstanceId) ||
            (options.Device.InterfaceGuid.HasValue && snapshot.InterfaceGuid == options.Device.InterfaceGuid);
    }

    public static bool IsBootloader(DeviceSnapshot snapshot, VibestickDeviceOptions? options = null)
    {
        options ??= VibestickDeviceOptions.Default;
        return options.Bootloader.MatchesInstanceId(snapshot.InstanceId) ||
            IsBootloaderVolume(snapshot, options);
    }

    private static bool IsBootloaderVolume(DeviceSnapshot snapshot, VibestickDeviceOptions options)
    {
        if (string.Equals(snapshot.VolumeLabel, options.BootloaderVolumeLabel, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return snapshot.BoardInfoText is not null &&
            snapshot.BoardInfoText.Contains($"Board-ID: {options.BootloaderBoardId}", StringComparison.OrdinalIgnoreCase);
    }
}

public sealed class DeviceAutoLaunchPolicy
{
    private readonly TimeSpan _debounce;
    private DateTimeOffset? _lastLaunchAt;

    public DeviceAutoLaunchPolicy(TimeSpan debounce)
    {
        _debounce = debounce;
    }

    public DeviceAutoLaunchDecision Evaluate(
        DeviceDetectionResult detection,
        bool isGuiAlreadyRunning,
        DateTimeOffset now)
    {
        if (detection.Kind == DeviceDetectionKind.Bootloader)
        {
            return new DeviceAutoLaunchDecision(
                DeviceAutoLaunchAction.BootloaderOnly,
                "RP2 bootloader is connected; flash Vibestick firmware before auto-launching the GUI.");
        }

        if (detection.Kind != DeviceDetectionKind.VibestickDevice)
        {
            return new DeviceAutoLaunchDecision(DeviceAutoLaunchAction.None, detection.Message);
        }

        if (isGuiAlreadyRunning)
        {
            return new DeviceAutoLaunchDecision(
                DeviceAutoLaunchAction.AlreadyRunning,
                "Vibestick GUI is already running.");
        }

        if (_lastLaunchAt.HasValue && now - _lastLaunchAt.Value < _debounce)
        {
            return new DeviceAutoLaunchDecision(
                DeviceAutoLaunchAction.Debounced,
                "Vibestick device event ignored because the GUI was launched recently.");
        }

        _lastLaunchAt = now;
        return new DeviceAutoLaunchDecision(
            DeviceAutoLaunchAction.Launch,
            "Vibestick device detected; launching the GUI.");
    }
}
