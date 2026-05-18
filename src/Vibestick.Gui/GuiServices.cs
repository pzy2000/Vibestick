using Vibestick.Core;

namespace Vibestick.Gui;

public sealed record GuiServices(
    VibestickEngine Engine,
    DoctorService Doctor,
    IBatteryMonitor BatteryMonitor,
    IProcessInspector ProcessInspector,
    ISleepBlocker SleepBlocker,
    VibestickOptions Options,
    ICoderStatusSource CoderStatusSource,
    CodexSessionStatusBridge? CodexStatusBridge,
    PetStateResolver PetStateResolver,
    string CoderStatusDirectory);

public sealed class GuiRuntimeState
{
    public bool IsHyperGuardRunning { get; set; }
}

public static class GuiServiceFactory
{
    public static GuiServices Create(
        string? coderStatusDirectory = null,
        bool enableCodexMonitor = true,
        string? codexSessionsRoot = null)
    {
        var options = new VibestickOptions();
        var commandRunner = new ProcessCommandRunner();
        var powerPolicy = new PowerCfgPowerPolicyManager(commandRunner);
        var stateStore = new JsonFileStateStore();
        var batteryMonitor = new WindowsBatteryMonitor();
        var processInspector = new WindowsProcessInspector();
        var engine = new VibestickEngine(powerPolicy, stateStore, batteryMonitor, processInspector, options);
        var doctor = new DoctorService(powerPolicy, stateStore, batteryMonitor, processInspector, options);
        var sleepBlocker = new WindowsSleepBlocker();
        var resolvedCoderStatusDirectory = coderStatusDirectory ?? CoderStatusPaths.GetDefaultDirectory();
        var coderStatusSource = new CompositeCoderStatusSource(
            new JsonFileCoderStatusSource(resolvedCoderStatusDirectory),
            new ProcessCoderStatusSource(processInspector, options.LongTaskProcessNames));
        var codexStatusBridge = enableCodexMonitor
            ? new CodexSessionStatusBridge(resolvedCoderStatusDirectory, codexSessionsRoot)
            : null;
        var petStateResolver = new PetStateResolver(options);

        return new GuiServices(
            engine,
            doctor,
            batteryMonitor,
            processInspector,
            sleepBlocker,
            options,
            coderStatusSource,
            codexStatusBridge,
            petStateResolver,
            resolvedCoderStatusDirectory);
    }
}
