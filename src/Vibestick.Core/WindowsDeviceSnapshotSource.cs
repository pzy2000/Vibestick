using System.Management;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Vibestick.Core;

[SupportedOSPlatform("windows")]
public sealed class WindowsDeviceSnapshotSource
{
    private const uint DigcfPresent = 0x00000002;
    private const uint DigcfDeviceInterface = 0x00000010;
    private static readonly IntPtr InvalidHandleValue = new(-1);
    private readonly VibestickDeviceOptions _options;

    public WindowsDeviceSnapshotSource(VibestickDeviceOptions? options = null)
    {
        _options = options ?? VibestickDeviceOptions.Default;
    }

    public IReadOnlyList<DeviceSnapshot> GetSnapshots()
    {
        var snapshots = new List<DeviceSnapshot>();
        snapshots.AddRange(GetPnpSnapshots());
        snapshots.AddRange(GetDeviceInterfaceSnapshots(_options.Device.InterfaceGuid));
        snapshots.AddRange(GetRemovableVolumeSnapshots());
        return snapshots;
    }

    private static IEnumerable<DeviceSnapshot> GetPnpSnapshots()
    {
        using var searcher = new ManagementObjectSearcher("SELECT PNPDeviceID, Name, ClassGuid FROM Win32_PnPEntity");
        foreach (ManagementBaseObject item in searcher.Get())
        {
            var instanceId = item["PNPDeviceID"]?.ToString();
            if (string.IsNullOrWhiteSpace(instanceId))
            {
                continue;
            }

            yield return new DeviceSnapshot(
                InstanceId: instanceId,
                FriendlyName: item["Name"]?.ToString(),
                InterfaceGuid: TryParseGuid(item["ClassGuid"]?.ToString()));
        }
    }

    private static IEnumerable<DeviceSnapshot> GetRemovableVolumeSnapshots()
    {
        using var searcher = new ManagementObjectSearcher("SELECT DeviceID, VolumeName FROM Win32_LogicalDisk WHERE DriveType = 2");
        foreach (ManagementBaseObject item in searcher.Get())
        {
            var deviceId = item["DeviceID"]?.ToString();
            if (string.IsNullOrWhiteSpace(deviceId))
            {
                continue;
            }

            var driveRoot = deviceId.EndsWith('\\')
                ? deviceId
                : $"{deviceId}\\";
            yield return new DeviceSnapshot(
                DriveRoot: driveRoot,
                VolumeLabel: item["VolumeName"]?.ToString(),
                BoardInfoText: TryReadBoardInfo(driveRoot));
        }
    }

    private static IEnumerable<DeviceSnapshot> GetDeviceInterfaceSnapshots(Guid? interfaceGuid)
    {
        if (!interfaceGuid.HasValue)
        {
            yield break;
        }

        var guid = interfaceGuid.Value;
        var infoSet = SetupDiGetClassDevs(ref guid, IntPtr.Zero, IntPtr.Zero, DigcfPresent | DigcfDeviceInterface);
        if (infoSet == InvalidHandleValue)
        {
            yield break;
        }

        try
        {
            for (var index = 0u; ; index++)
            {
                var data = new SpDeviceInterfaceData
                {
                    CbSize = Marshal.SizeOf<SpDeviceInterfaceData>()
                };

                if (!SetupDiEnumDeviceInterfaces(infoSet, IntPtr.Zero, ref guid, index, ref data))
                {
                    yield break;
                }

                yield return new DeviceSnapshot(
                    FriendlyName: "Vibestick WinUSB interface",
                    InterfaceGuid: interfaceGuid);
            }
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(infoSet);
        }
    }

    private static string? TryReadBoardInfo(string driveRoot)
    {
        try
        {
            var path = Path.Combine(driveRoot, "INFO_UF2.TXT");
            return File.Exists(path) ? File.ReadAllText(path) : null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static Guid? TryParseGuid(string? value)
    {
        if (Guid.TryParse(value?.Trim('{', '}'), out var guid))
        {
            return guid;
        }

        return null;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SpDeviceInterfaceData
    {
        public int CbSize;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern IntPtr SetupDiGetClassDevs(
        ref Guid classGuid,
        IntPtr enumerator,
        IntPtr hwndParent,
        uint flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInterfaces(
        IntPtr deviceInfoSet,
        IntPtr deviceInfoData,
        ref Guid interfaceClassGuid,
        uint memberIndex,
        ref SpDeviceInterfaceData deviceInterfaceData);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr deviceInfoSet);
}
