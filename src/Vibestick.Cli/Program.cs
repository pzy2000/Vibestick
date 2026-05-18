using System.Text.Json;
using System.Text.Json.Serialization;
using Vibestick.Core;

namespace Vibestick.Cli;

internal static class Program
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };

    public static async Task<int> Main(string[] args)
    {
        var json = HasFlag(args, "--json");

        try
        {
            if (args.Length == 0 || HasFlag(args, "--help") || HasFlag(args, "-h"))
            {
                PrintHelp();
                return 0;
            }

            var services = CreateServices();
            var command = args[0].ToLowerInvariant();

            return command switch
            {
                "status" => await RunStatusAsync(services.Engine, json).ConfigureAwait(false),
                "doctor" => await RunDoctorAsync(services.Doctor, json).ConfigureAwait(false),
                "revert" => await RunRevertAsync(services.Engine, json).ConfigureAwait(false),
                "mode" => await RunModeAsync(args, services, json).ConfigureAwait(false),
                _ => UnknownCommand(command)
            };
        }
        catch (Exception exception)
        {
            if (json)
            {
                WriteJson(new { ok = false, error = exception.Message });
            }
            else
            {
                Console.Error.WriteLine($"Error: {exception.Message}");
            }

            return 3;
        }
    }

    private static Services CreateServices()
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

        return new Services(engine, doctor, batteryMonitor, processInspector, sleepBlocker, options);
    }

    private static async Task<int> RunStatusAsync(VibestickEngine engine, bool json)
    {
        var status = await engine.GetStatusAsync().ConfigureAwait(false);
        if (json)
        {
            WriteJson(status);
        }
        else
        {
            PrintStatus(status);
        }

        return status.Warnings.Count == 0 ? 0 : 2;
    }

    private static async Task<int> RunDoctorAsync(DoctorService doctor, bool json)
    {
        var report = await doctor.RunAsync().ConfigureAwait(false);
        if (json)
        {
            WriteJson(report);
        }
        else
        {
            PrintDoctor(report);
        }

        return report.IsHealthy ? 0 : 2;
    }

    private static async Task<int> RunRevertAsync(VibestickEngine engine, bool json)
    {
        var result = await engine.RevertAsync().ConfigureAwait(false);
        PrintModeResult(result, json);
        return 0;
    }

    private static async Task<int> RunModeAsync(string[] args, Services services, bool json)
    {
        if (args.Length < 2)
        {
            Console.Error.WriteLine("Missing mode. Expected: off, on, hyper.");
            return 1;
        }

        if (!TryParseMode(args[1], out var mode))
        {
            Console.Error.WriteLine($"Unknown mode '{args[1]}'. Expected: off, on, hyper.");
            return 1;
        }

        var once = HasFlag(args, "--once") || json;
        var result = await services.Engine.ApplyModeAsync(mode).ConfigureAwait(false);
        PrintModeResult(result, json);

        if (result.AppliedMode == VibestickMode.Hyper && !once)
        {
            return await RunHyperGuardAsync(services).ConfigureAwait(false);
        }

        if (mode == VibestickMode.Hyper && once && !json)
        {
            Console.WriteLine("HYPER was applied once. Idle sleep is not blocked after this process exits.");
        }

        return 0;
    }

    private static async Task<int> RunHyperGuardAsync(Services services)
    {
        using var sleepBlock = services.SleepBlocker.BlockSystemSleep();
        using var shutdown = new CancellationTokenSource();
        Console.CancelKeyPress += (_, args) =>
        {
            args.Cancel = true;
            shutdown.Cancel();
        };

        Console.WriteLine("HYPER guard is running. Display sleep is allowed; system idle sleep is blocked.");
        Console.WriteLine("Press Ctrl+C to stop the guard. Vibestick will downgrade state to ON.");

        var batteryPolicy = new BatterySafetyPolicy(services.Options);
        while (!shutdown.IsCancellationRequested)
        {
            var decision = batteryPolicy.Evaluate(services.BatteryMonitor.GetBatteryInfo());
            if (decision.Action == SafetyAction.RestoreNormalSleep)
            {
                Console.WriteLine(decision.Message);
                await services.Engine.RevertAsync(shutdown.Token).ConfigureAwait(false);
                return 2;
            }

            if (decision.Action == SafetyAction.DowngradeToOn)
            {
                Console.WriteLine(decision.Message);
                await services.Engine.ApplyModeAsync(VibestickMode.On, shutdown.Token).ConfigureAwait(false);
                return 2;
            }

            if (decision.Action == SafetyAction.Warn)
            {
                Console.WriteLine(decision.Message);
            }

            var longTasks = services.ProcessInspector.GetLongTasks(services.Options.LongTaskProcessNames);
            if (longTasks.Count > 0)
            {
                Console.WriteLine($"Long tasks: {string.Join(", ", longTasks.Select(static task => task.Name))}");
            }

            try
            {
                await Task.Delay(services.Options.HyperGuardInterval, shutdown.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }

        await services.Engine.ApplyModeAsync(VibestickMode.On).ConfigureAwait(false);
        Console.WriteLine("HYPER guard stopped. Mode state downgraded to ON; run 'vibestick revert' to restore normal sleep.");
        return 0;
    }

    private static void PrintStatus(VibestickStatus status)
    {
        Console.WriteLine("Vibestick");
        Console.WriteLine($"Mode:             {status.ActiveMode}");
        Console.WriteLine($"Restore pending:  {YesNo(status.RestorePending)}");
        Console.WriteLine($"State scheme:     {status.LastAppliedSchemeGuid ?? "-"}");
        Console.WriteLine($"Current scheme:   {status.CurrentSchemeGuid ?? "-"}");
        Console.WriteLine($"Current lid:      {FormatPolicy(status.CurrentPolicy)}");
        Console.WriteLine($"Original lid:     {FormatPolicy(status.OriginalPolicy)}");
        Console.WriteLine($"Battery:          {FormatBattery(status.Battery)}");
        Console.WriteLine($"Long tasks:       {FormatTasks(status.LongTasks)}");

        if (status.Warnings.Count > 0)
        {
            Console.WriteLine();
            Console.WriteLine("Warnings:");
            foreach (var warning in status.Warnings)
            {
                Console.WriteLine($"- {warning}");
            }
        }
    }

    private static void PrintDoctor(DoctorReport report)
    {
        Console.WriteLine("Vibestick doctor");
        foreach (var check in report.Checks)
        {
            Console.WriteLine($"{(check.Passed ? "OK " : "ERR")} {check.Name,-12} {check.Message}");
        }
    }

    private static void PrintModeResult(ModeChangeResult result, bool json)
    {
        if (json)
        {
            WriteJson(result);
            return;
        }

        Console.WriteLine(result.Message);
        Console.WriteLine($"Requested:        {result.RequestedMode}");
        Console.WriteLine($"Applied:          {result.AppliedMode}");
        Console.WriteLine($"Restore pending:  {YesNo(result.RestorePending)}");

        foreach (var warning in result.Warnings)
        {
            Console.WriteLine($"Warning: {warning}");
        }
    }

    private static void PrintHelp()
    {
        Console.WriteLine("Vibestick Windows CLI MVP");
        Console.WriteLine();
        Console.WriteLine("Usage:");
        Console.WriteLine("  vibestick status [--json]");
        Console.WriteLine("  vibestick doctor [--json]");
        Console.WriteLine("  vibestick mode off|on|hyper [--json] [--once]");
        Console.WriteLine("  vibestick revert [--json]");
        Console.WriteLine();
        Console.WriteLine("Notes:");
        Console.WriteLine("  mode hyper runs a foreground guard by default. Use --once to apply policy and exit.");
    }

    private static int UnknownCommand(string command)
    {
        Console.Error.WriteLine($"Unknown command '{command}'.");
        PrintHelp();
        return 1;
    }

    private static bool TryParseMode(string value, out VibestickMode mode)
    {
        switch (value.ToLowerInvariant())
        {
            case "off":
                mode = VibestickMode.Off;
                return true;
            case "on":
                mode = VibestickMode.On;
                return true;
            case "hyper":
                mode = VibestickMode.Hyper;
                return true;
            default:
                mode = VibestickMode.Off;
                return false;
        }
    }

    private static bool HasFlag(string[] args, string flag)
    {
        return args.Any(arg => string.Equals(arg, flag, StringComparison.OrdinalIgnoreCase));
    }

    private static void WriteJson<T>(T value)
    {
        Console.WriteLine(JsonSerializer.Serialize(value, JsonOptions));
    }

    private static string FormatPolicy(PowerPolicySnapshot? policy)
    {
        return policy is null
            ? "-"
            : $"AC={FormatLidAction(policy.AcLidAction)} ({policy.AcLidAction}), DC={FormatLidAction(policy.DcLidAction)} ({policy.DcLidAction})";
    }

    private static string FormatLidAction(int value)
    {
        return value switch
        {
            0 => "Do Nothing",
            1 => "Sleep",
            2 => "Hibernate",
            3 => "Shut Down",
            _ => $"Unknown {value}"
        };
    }

    private static string FormatBattery(BatteryInfo battery)
    {
        if (!battery.IsAvailable)
        {
            return "unavailable";
        }

        var percent = battery.Percentage.HasValue ? $"{battery.Percentage.Value}%" : "unknown";
        return $"{percent}, AC connected={YesNo(battery.IsAcConnected)}";
    }

    private static string FormatTasks(IReadOnlyList<LongTaskProcess> tasks)
    {
        return tasks.Count == 0
            ? "-"
            : string.Join(", ", tasks.Select(static task => task.ProcessId.HasValue ? $"{task.Name}({task.ProcessId})" : task.Name));
    }

    private static string YesNo(bool value) => value ? "yes" : "no";

    private sealed record Services(
        VibestickEngine Engine,
        DoctorService Doctor,
        IBatteryMonitor BatteryMonitor,
        IProcessInspector ProcessInspector,
        ISleepBlocker SleepBlocker,
        VibestickOptions Options);
}

