using System.Security.Principal;

namespace Vibestick.Core;

public sealed class DoctorService
{
    private readonly IPowerPolicyManager _powerPolicy;
    private readonly IStateStore _stateStore;
    private readonly IBatteryMonitor _batteryMonitor;
    private readonly IProcessInspector _processInspector;
    private readonly VibestickOptions _options;

    public DoctorService(
        IPowerPolicyManager powerPolicy,
        IStateStore stateStore,
        IBatteryMonitor batteryMonitor,
        IProcessInspector processInspector,
        VibestickOptions? options = null)
    {
        _powerPolicy = powerPolicy;
        _stateStore = stateStore;
        _batteryMonitor = batteryMonitor;
        _processInspector = processInspector;
        _options = options ?? new VibestickOptions();
    }

    public async Task<DoctorReport> RunAsync(CancellationToken cancellationToken = default)
    {
        var checks = new List<DoctorCheck>();

        checks.Add(new DoctorCheck(
            "os",
            OperatingSystem.IsWindows(),
            OperatingSystem.IsWindows()
                ? "Windows detected."
                : "This MVP supports Windows only."));

        checks.Add(GetPrivilegeCheck());

        var stateLoad = await _stateStore.LoadAsync(cancellationToken).ConfigureAwait(false);
        checks.Add(new DoctorCheck(
            "state",
            !stateLoad.WasCorrupted,
            stateLoad.Warning ?? $"State path: {_stateStore.StatePath}"));

        try
        {
            var schemeGuid = await _powerPolicy.GetActiveSchemeGuidAsync(cancellationToken).ConfigureAwait(false);
            var lidPolicy = await _powerPolicy.ReadLidActionAsync(schemeGuid, cancellationToken).ConfigureAwait(false);
            checks.Add(new DoctorCheck(
                "powercfg",
                true,
                $"Active scheme {schemeGuid}; lid AC={lidPolicy.AcLidAction}, DC={lidPolicy.DcLidAction}."));
        }
        catch (PowerPolicyException exception)
        {
            checks.Add(new DoctorCheck("powercfg", false, exception.Message));
        }

        var battery = _batteryMonitor.GetBatteryInfo();
        checks.Add(new DoctorCheck(
            "battery",
            battery.IsAvailable,
            battery.IsAvailable
                ? $"Battery {(battery.Percentage.HasValue ? battery.Percentage.Value + "%" : "unknown")}; AC connected={battery.IsAcConnected}."
                : "Battery status is unavailable."));

        var longTasks = _processInspector.GetLongTasks(_options.LongTaskProcessNames);
        checks.Add(new DoctorCheck(
            "long-tasks",
            true,
            longTasks.Count == 0
                ? "No whitelisted long-running coder tasks detected."
                : $"Detected: {string.Join(", ", longTasks.Select(static task => task.Name))}."));

        return new DoctorReport(checks.All(static check => check.Passed), checks);
    }

    private static DoctorCheck GetPrivilegeCheck()
    {
        if (!OperatingSystem.IsWindows())
        {
            return new DoctorCheck("privilege", false, "Privilege check is only implemented on Windows.");
        }

        try
        {
            using var identity = WindowsIdentity.GetCurrent();
            var principal = new WindowsPrincipal(identity);
            var isAdmin = principal.IsInRole(WindowsBuiltInRole.Administrator);
            return new DoctorCheck(
                "privilege",
                true,
                isAdmin
                    ? "Running elevated."
                    : "Not elevated. powercfg may still work for the active user plan; UAC may be needed if policy is locked.");
        }
        catch (Exception exception)
        {
            return new DoctorCheck("privilege", false, $"Could not determine privilege level: {exception.Message}");
        }
    }
}

