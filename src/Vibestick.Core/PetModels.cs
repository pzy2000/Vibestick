namespace Vibestick.Core;

public enum CoderAgentPhase
{
    Idle,
    Sleeping,
    Running,
    Reasoning,
    ToolCalling,
    WaitingAuthorization,
    Error,
    Success,
    Offline,
    Unknown
}

public sealed record CoderAgentStatus(
    string Agent,
    CoderAgentPhase Phase,
    string? Message,
    string? Workspace,
    int? ProcessId,
    DateTimeOffset UpdatedAtUtc,
    int? TtlSeconds,
    string? SessionId = null,
    string? TaskSummary = null,
    string? SourcePath = null);

public enum PetMood
{
    Idle,
    Sleeping,
    Running,
    Reasoning,
    ToolCalling,
    WaitingAuthorization,
    Error,
    Success,
    Offline,
    PowerWarning
}

public enum PetBadgeKind
{
    Mode,
    Guard,
    Battery,
    Warning
}

public sealed record PetBadge(
    PetBadgeKind Kind,
    string Text);

public sealed record PetState(
    PetMood Mood,
    string Title,
    string Message,
    CoderAgentStatus? PrimaryCoder,
    IReadOnlyList<CoderAgentStatus> Coders,
    IReadOnlyList<PetBadge> Badges,
    DateTimeOffset UpdatedAtUtc);

public interface ICoderStatusSource
{
    IReadOnlyList<CoderAgentStatus> GetStatuses(DateTimeOffset now);
}
