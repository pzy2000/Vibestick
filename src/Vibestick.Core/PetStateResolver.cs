namespace Vibestick.Core;

public sealed class PetStateResolver
{
    private readonly VibestickOptions _options;

    public PetStateResolver(VibestickOptions? options = null)
    {
        _options = options ?? new VibestickOptions();
    }

    public PetState Resolve(
        VibestickStatus vibestickStatus,
        IReadOnlyList<CoderAgentStatus> coderStatuses,
        bool isHyperGuardRunning,
        DateTimeOffset? now = null)
    {
        var updatedAtUtc = now ?? DateTimeOffset.UtcNow;
        var orderedCoders = coderStatuses
            .OrderBy(static status => GetPhasePriority(status.Phase))
            .ThenByDescending(static status => status.UpdatedAtUtc)
            .ThenBy(static status => status.Agent, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        var primaryCoder = orderedCoders.FirstOrDefault();
        var batteryDecision = new BatterySafetyPolicy(_options).Evaluate(vibestickStatus.Battery);
        var shouldOverrideForPower =
            batteryDecision.Action is SafetyAction.RestoreNormalSleep or SafetyAction.DowngradeToOn ||
            vibestickStatus.Warnings.Count > 0;

        var mood = shouldOverrideForPower
            ? PetMood.PowerWarning
            : primaryCoder is null
                ? PetMood.Idle
                : MapMood(primaryCoder.Phase);

        var title = GetTitle(mood, primaryCoder);
        var message = GetMessage(mood, primaryCoder, vibestickStatus, batteryDecision);

        return new PetState(
            mood,
            title,
            message,
            primaryCoder,
            orderedCoders,
            BuildBadges(vibestickStatus, isHyperGuardRunning, batteryDecision),
            updatedAtUtc);
    }

    public static int CompareCoderStatus(CoderAgentStatus left, CoderAgentStatus right)
    {
        var priority = GetPhasePriority(left.Phase).CompareTo(GetPhasePriority(right.Phase));
        if (priority != 0)
        {
            return priority;
        }

        return right.UpdatedAtUtc.CompareTo(left.UpdatedAtUtc);
    }

    public static int GetPhasePriority(CoderAgentPhase phase)
    {
        return phase switch
        {
            CoderAgentPhase.Error => 0,
            CoderAgentPhase.WaitingAuthorization => 1,
            CoderAgentPhase.Reasoning => 2,
            CoderAgentPhase.Running => 3,
            CoderAgentPhase.Success => 4,
            CoderAgentPhase.Offline => 5,
            CoderAgentPhase.Unknown => 6,
            CoderAgentPhase.Idle => 7,
            _ => 8
        };
    }

    private static PetMood MapMood(CoderAgentPhase phase)
    {
        return phase switch
        {
            CoderAgentPhase.Running => PetMood.Running,
            CoderAgentPhase.Reasoning => PetMood.Reasoning,
            CoderAgentPhase.WaitingAuthorization => PetMood.WaitingAuthorization,
            CoderAgentPhase.Error => PetMood.Error,
            CoderAgentPhase.Success => PetMood.Success,
            CoderAgentPhase.Offline => PetMood.Offline,
            _ => PetMood.Idle
        };
    }

    private static string GetTitle(PetMood mood, CoderAgentStatus? coder)
    {
        if (mood == PetMood.PowerWarning)
        {
            return "Power needs attention";
        }

        return coder is null
            ? "Vibestick is watching"
            : $"{coder.Agent}: {coder.Phase}";
    }

    private static string GetMessage(
        PetMood mood,
        CoderAgentStatus? coder,
        VibestickStatus vibestickStatus,
        BatterySafetyDecision batteryDecision)
    {
        if (mood == PetMood.PowerWarning)
        {
            return vibestickStatus.Warnings.FirstOrDefault() ?? batteryDecision.Message;
        }

        if (!string.IsNullOrWhiteSpace(coder?.Message))
        {
            return coder.Message!;
        }

        return mood switch
        {
            PetMood.Running => "A coder is running in the background.",
            PetMood.Reasoning => "The coder is thinking through the next step.",
            PetMood.WaitingAuthorization => "Authorization is needed. Click the pet to bring the coder forward.",
            PetMood.Error => "The coder reported an error.",
            PetMood.Success => "The coder finished successfully.",
            PetMood.Offline => "The coder appears offline.",
            _ => "No active coder state is available."
        };
    }

    private static IReadOnlyList<PetBadge> BuildBadges(
        VibestickStatus status,
        bool isHyperGuardRunning,
        BatterySafetyDecision batteryDecision)
    {
        var badges = new List<PetBadge>
        {
            new(PetBadgeKind.Mode, status.ActiveMode.ToString())
        };

        if (status.ActiveMode == VibestickMode.Hyper || isHyperGuardRunning)
        {
            badges.Add(new PetBadge(PetBadgeKind.Guard, isHyperGuardRunning ? "Guard on" : "Guard off"));
        }

        if (status.Battery.IsAvailable)
        {
            var percent = status.Battery.Percentage.HasValue ? $"{status.Battery.Percentage.Value}%" : "Battery ?";
            badges.Add(new PetBadge(PetBadgeKind.Battery, status.Battery.IsAcConnected ? $"{percent} AC" : percent));
        }

        if (batteryDecision.Action == SafetyAction.Warn)
        {
            badges.Add(new PetBadge(PetBadgeKind.Warning, batteryDecision.Message));
        }

        foreach (var warning in status.Warnings)
        {
            badges.Add(new PetBadge(PetBadgeKind.Warning, warning));
        }

        return badges;
    }
}
