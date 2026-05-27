namespace Vibestick.Core;

public sealed record PowerPolicySnapshot(
    string SchemeGuid,
    int AcLidAction,
    int DcLidAction);

public sealed class VibestickState
{
    public VibestickMode ActiveMode { get; set; } = VibestickMode.Off;

    public string? LastAppliedSchemeGuid { get; set; }

    public PowerPolicySnapshot? OriginalPolicy { get; set; }

    public bool RestorePending { get; set; }

    public DateTimeOffset UpdatedAtUtc { get; set; } = DateTimeOffset.UtcNow;

    public static VibestickState Empty() => new();
}

public sealed record StateLoadResult(
    VibestickState State,
    bool WasCorrupted,
    string? Warning);

public sealed record BatteryInfo(
    int? Percentage,
    bool IsAcConnected,
    bool IsAvailable,
    int? ChargeRateInMilliwatts = null,
    int? RemainingCapacityInMilliwattHours = null,
    int? FullChargeCapacityInMilliwattHours = null,
    TimeSpan? EstimatedTimeToFull = null);

public enum SafetyAction
{
    KeepHyper,
    Warn,
    DowngradeToOn,
    RestoreNormalSleep
}

public sealed record BatterySafetyDecision(
    SafetyAction Action,
    string Message);

public sealed record LongTaskProcess(
    int? ProcessId,
    string Name);

public sealed class VibestickOptions
{
    public int BatteryWarnPercent { get; init; } = 30;

    public int BatteryDowngradePercent { get; init; } = 20;

    public int BatteryRestorePercent { get; init; } = 10;

    public TimeSpan HyperGuardInterval { get; init; } = TimeSpan.FromSeconds(30);

    public IReadOnlyList<string> LongTaskProcessNames { get; init; } = new[]
    {
        "cargo",
        "go",
        "pytest",
        "docker",
        "uv",
        "npm",
        "pnpm",
        "claude",
        "claude-code",
        "codex",
        "hermes",
        "nanobot",
        "openclaw",
        "openclaw-cli",
        "openclaw-doctor",
        "opencode",
        "openhands"
    };
}

public sealed record ModeChangeResult(
    VibestickMode RequestedMode,
    VibestickMode AppliedMode,
    bool RestorePending,
    IReadOnlyList<string> Warnings,
    string Message);

public sealed record VibestickStatus(
    VibestickMode ActiveMode,
    bool RestorePending,
    string? LastAppliedSchemeGuid,
    PowerPolicySnapshot? OriginalPolicy,
    string? CurrentSchemeGuid,
    PowerPolicySnapshot? CurrentPolicy,
    BatteryInfo Battery,
    IReadOnlyList<LongTaskProcess> LongTasks,
    IReadOnlyList<string> Warnings);

public sealed record DoctorCheck(
    string Name,
    bool Passed,
    string Message);

public sealed record DoctorReport(
    bool IsHealthy,
    IReadOnlyList<DoctorCheck> Checks);
