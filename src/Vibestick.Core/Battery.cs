using System.Runtime.InteropServices;

namespace Vibestick.Core;

public interface IBatteryMonitor
{
    BatteryInfo GetBatteryInfo();
}

public sealed class WindowsBatteryMonitor : IBatteryMonitor
{
    private const int SystemBatteryStateInformationLevel = 5;

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

        if (!isAvailable || !TryGetSystemBatteryState(out var batteryState) || batteryState.BatteryPresent == 0)
        {
            return new BatteryInfo(percentage, isAcConnected, isAvailable);
        }

        var isCharging = isAcConnected && batteryState.Charging != 0 && batteryState.Rate > 0;
        int? chargeRate = isCharging ? batteryState.Rate : null;
        var remainingCapacity = ToCapacity(batteryState.RemainingCapacity);
        var fullChargeCapacity = ToCapacity(batteryState.MaxCapacity);
        var estimatedTimeToFull = CalculateEstimatedTimeToFull(
            isCharging,
            chargeRate,
            remainingCapacity,
            fullChargeCapacity);

        return new BatteryInfo(
            percentage,
            isAcConnected,
            isAvailable,
            chargeRate,
            remainingCapacity,
            fullChargeCapacity,
            estimatedTimeToFull);
    }

    private static int? ToCapacity(uint capacity)
    {
        return capacity is > 0 and < int.MaxValue ? (int)capacity : null;
    }

    private static TimeSpan? CalculateEstimatedTimeToFull(
        bool isCharging,
        int? chargeRate,
        int? remainingCapacity,
        int? fullChargeCapacity)
    {
        if (!isCharging ||
            chargeRate is null or <= 0 ||
            remainingCapacity is null ||
            fullChargeCapacity is null ||
            fullChargeCapacity <= remainingCapacity)
        {
            return null;
        }

        var remainingMilliwattHours = fullChargeCapacity.Value - remainingCapacity.Value;
        var hours = remainingMilliwattHours / (double)chargeRate.Value;
        if (double.IsNaN(hours) || double.IsInfinity(hours) || hours <= 0)
        {
            return null;
        }

        return TimeSpan.FromHours(hours);
    }

    private static bool TryGetSystemBatteryState(out SystemBatteryState state)
    {
        state = default;
        var result = NativeMethods.CallNtPowerInformation(
            SystemBatteryStateInformationLevel,
            IntPtr.Zero,
            0,
            out state,
            Marshal.SizeOf<SystemBatteryState>());
        return result == 0;
    }

    private static class NativeMethods
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool GetSystemPowerStatus(out SystemPowerStatus status);

        [DllImport("powrprof.dll", SetLastError = true)]
        internal static extern uint CallNtPowerInformation(
            int informationLevel,
            IntPtr inputBuffer,
            int inputBufferLength,
            out SystemBatteryState outputBuffer,
            int outputBufferLength);
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

    [StructLayout(LayoutKind.Sequential)]
    private struct SystemBatteryState
    {
        public byte AcOnLine;
        public byte BatteryPresent;
        public byte Charging;
        public byte Discharging;
        public byte Spare1;
        public byte Spare2;
        public byte Spare3;
        public byte Tag;
        public uint MaxCapacity;
        public uint RemainingCapacity;
        public int Rate;
        public uint EstimatedTime;
        public uint DefaultAlert1;
        public uint DefaultAlert2;
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
