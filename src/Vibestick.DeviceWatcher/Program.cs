using System.Diagnostics;
using Vibestick.Core;

namespace Vibestick.DeviceWatcher;

internal static class Program
{
    private const string MutexName = "Local\\VibestickDeviceWatcher";
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);

    public static async Task<int> Main(string[] args)
    {
        if (HasFlag(args, "--help") || HasFlag(args, "-h"))
        {
            WriteUsage();
            return 0;
        }

        var once = HasFlag(args, "--once");
        var createdNew = true;
        using var mutex = once ? null : new Mutex(initiallyOwned: true, MutexName, out createdNew);
        if (!once && !createdNew)
        {
            return 0;
        }

        using var shutdown = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            shutdown.Cancel();
        };

        var log = new DeviceWatcherLog(GetOption(args, "--log-path"));
        var options = VibestickDeviceOptions.Default;
        var source = new WindowsDeviceSnapshotSource(options);
        var policy = new DeviceAutoLaunchPolicy(options.LaunchDebounce);
        var guiPath = ResolveGuiPath(GetOption(args, "--gui-path"));
        var launcher = new GuiLauncher(guiPath, HasFlag(args, "--no-launch"), log);
        string? lastStatus = null;

        log.Write("Vibestick device watcher started.");
        log.Write($"GUI path: {guiPath}");

        do
        {
            var detection = DeviceDetector.Detect(source.GetSnapshots(), options);
            var decision = policy.Evaluate(detection, launcher.IsGuiRunning(), DateTimeOffset.UtcNow);
            var status = $"{detection.Kind}: {decision.Action}: {decision.Message}";
            if (!string.Equals(status, lastStatus, StringComparison.Ordinal))
            {
                log.Write(status);
                lastStatus = status;
            }

            if (decision.Action == DeviceAutoLaunchAction.Launch)
            {
                launcher.Launch();
            }

            if (once)
            {
                return detection.Kind == DeviceDetectionKind.None ? 1 : 0;
            }

            try
            {
                await Task.Delay(PollInterval, shutdown.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
        while (!shutdown.IsCancellationRequested);

        log.Write("Vibestick device watcher stopped.");
        return 0;
    }

    private static string ResolveGuiPath(string? configuredPath)
    {
        if (!string.IsNullOrWhiteSpace(configuredPath))
        {
            return Path.GetFullPath(configuredPath);
        }

        var appDirectory = AppContext.BaseDirectory;
        var sibling = Path.Combine(appDirectory, "vibestick-gui.exe");
        if (File.Exists(sibling))
        {
            return sibling;
        }

        return Path.GetFullPath(Path.Combine(
            appDirectory,
            "..",
            "..",
            "..",
            "..",
            "Vibestick.Gui",
            "bin",
            "Release",
            "net8.0-windows",
            "vibestick-gui.exe"));
    }

    private static bool HasFlag(string[] args, string flag)
    {
        return args.Any(arg => string.Equals(arg, flag, StringComparison.OrdinalIgnoreCase));
    }

    private static string? GetOption(string[] args, string option)
    {
        for (var index = 0; index < args.Length - 1; index++)
        {
            if (string.Equals(args[index], option, StringComparison.OrdinalIgnoreCase))
            {
                return args[index + 1];
            }
        }

        return null;
    }

    private static void WriteUsage()
    {
        Console.WriteLine("Vibestick Device Watcher");
        Console.WriteLine();
        Console.WriteLine("Usage:");
        Console.WriteLine("  vibestick-device-watcher [--gui-path <path>] [--once] [--no-launch] [--log-path <path>]");
    }
}

internal sealed class GuiLauncher
{
    private readonly string _guiPath;
    private readonly bool _noLaunch;
    private readonly DeviceWatcherLog _log;

    public GuiLauncher(string guiPath, bool noLaunch, DeviceWatcherLog log)
    {
        _guiPath = guiPath;
        _noLaunch = noLaunch;
        _log = log;
    }

    public bool IsGuiRunning()
    {
        var processName = Path.GetFileNameWithoutExtension(_guiPath);
        return Process.GetProcessesByName(processName)
            .Any(static process =>
            {
                try
                {
                    return !process.HasExited;
                }
                catch (InvalidOperationException)
                {
                    return false;
                }
            });
    }

    public void Launch()
    {
        if (_noLaunch)
        {
            _log.Write("Launch suppressed by --no-launch.");
            return;
        }

        if (!File.Exists(_guiPath))
        {
            _log.Write($"GUI launch skipped; file not found: {_guiPath}");
            return;
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = _guiPath,
            UseShellExecute = true,
            WorkingDirectory = Path.GetDirectoryName(_guiPath) ?? AppContext.BaseDirectory
        };
        startInfo.ArgumentList.Add("--device-auto-start");
        Process.Start(startInfo);
        _log.Write("Vibestick GUI launch requested.");
    }
}

internal sealed class DeviceWatcherLog
{
    private readonly string _path;

    public DeviceWatcherLog(string? path)
    {
        _path = string.IsNullOrWhiteSpace(path)
            ? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Vibestick",
                "device-watcher.log")
            : Path.GetFullPath(path);
    }

    public void Write(string message)
    {
        try
        {
            var directory = Path.GetDirectoryName(_path);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            File.AppendAllText(_path, $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }
    }
}
