using System.Runtime.InteropServices;

namespace Vibestick.Core;

public interface IBatteryMonitor
{
    BatteryInfo GetBatteryInfo();
}

public sealed class WindowsBatteryMonitor : IBatteryMonitor
{
    public BatteryInfo GetBatteryInfo()
    {
        if (!OperatingSystem.IsWindows())
        {
            return new BatteryInfo(null, IsAcConnected: false, IsAvailable: false);
        }

        if (!NativeMethods.GetSystemPowerStatus(out var status))
        {
            return new BatteryInfo(null, IsAcConnected: false, IsAvailable: false);
        }

        var isAcConnected = status.ACLineStatus == 1;
        int? percentage = status.BatteryLifePercent == 255 ? null : status.BatteryLifePercent;
        var isAvailable = status.ACLineStatus != 255 || percentage.HasValue;

        return new BatteryInfo(percentage, isAcConnected, isAvailable);
    }

    private static class NativeMethods
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool GetSystemPowerStatus(out SystemPowerStatus status);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SystemPowerStatus
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }
}

public sealed class BatterySafetyPolicy
{
    private readonly VibestickOptions _options;

    public BatterySafetyPolicy(VibestickOptions options)
    {
        _options = options;
    }

    public BatterySafetyDecision Evaluate(BatteryInfo battery)
    {
        if (!battery.IsAvailable)
        {
            return new BatterySafetyDecision(SafetyAction.KeepHyper, "Battery status is unavailable.");
        }

        if (battery.IsAcConnected)
        {
            return new BatterySafetyDecision(SafetyAction.KeepHyper, "AC power is connected.");
        }

        if (battery.Percentage is null)
        {
            return new BatterySafetyDecision(SafetyAction.KeepHyper, "Battery percentage is unavailable.");
        }

        var percentage = battery.Percentage.Value;
        if (percentage < _options.BatteryRestorePercent)
        {
            return new BatterySafetyDecision(
                SafetyAction.RestoreNormalSleep,
                $"Battery is {percentage}%, below {_options.BatteryRestorePercent}%; restoring normal sleep.");
        }

        if (percentage < _options.BatteryDowngradePercent)
        {
            return new BatterySafetyDecision(
                SafetyAction.DowngradeToOn,
                $"Battery is {percentage}%, below {_options.BatteryDowngradePercent}%; downgrading HYPER to ON.");
        }

        if (percentage < _options.BatteryWarnPercent)
        {
            return new BatterySafetyDecision(
                SafetyAction.Warn,
                $"Battery is {percentage}%, below {_options.BatteryWarnPercent}%; HYPER is allowed but risky.");
        }

        return new BatterySafetyDecision(SafetyAction.KeepHyper, $"Battery is {percentage}%.");
    }
}

