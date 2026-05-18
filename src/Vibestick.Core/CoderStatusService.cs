using System.Text.Json;
using System.Text.Json.Serialization;

namespace Vibestick.Core;

public static class CoderStatusPaths
{
    public static string GetDefaultDirectory()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(localAppData, "Vibestick", "coder-status");
    }

    public static string GetStatusPath(string directory, string agent)
    {
        return GetStatusPath(directory, agent, sessionId: null);
    }

    public static string GetStatusPath(string directory, string agent, string? sessionId)
    {
        var sanitizedAgent = SanitizeAgentName(agent);
        if (string.IsNullOrWhiteSpace(sessionId))
        {
            return Path.Combine(directory, $"{sanitizedAgent}.json");
        }

        return Path.Combine(directory, $"{sanitizedAgent}-{SanitizeAgentName(sessionId)}.json");
    }

    public static bool IsStatusPathForAgent(string path, string agent)
    {
        var fileName = Path.GetFileNameWithoutExtension(path);
        var sanitizedAgent = SanitizeAgentName(agent);
        return string.Equals(fileName, sanitizedAgent, StringComparison.OrdinalIgnoreCase) ||
            fileName.StartsWith($"{sanitizedAgent}-", StringComparison.OrdinalIgnoreCase);
    }

    public static string SanitizeAgentName(string agent)
    {
        var trimmed = string.IsNullOrWhiteSpace(agent) ? "coder" : agent.Trim();
        var invalid = Path.GetInvalidFileNameChars();
        var characters = trimmed
            .Select(character => invalid.Contains(character) || character is '*' or '?' ? '-' : character)
            .ToArray();

        return new string(characters).Trim('.', ' ');
    }
}

public sealed class JsonFileCoderStatusSource : ICoderStatusSource
{
    public const int DefaultTtlSeconds = 120;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseLower) }
    };

    private readonly string _directory;

    public JsonFileCoderStatusSource(string? directory = null)
    {
        _directory = directory ?? CoderStatusPaths.GetDefaultDirectory();
    }

    public string DirectoryPath => _directory;

    public IReadOnlyList<CoderAgentStatus> GetStatuses(DateTimeOffset now)
    {
        if (!Directory.Exists(_directory))
        {
            return Array.Empty<CoderAgentStatus>();
        }

        var statuses = new List<CoderAgentStatus>();
        foreach (var path in Directory.EnumerateFiles(_directory, "*.json"))
        {
            try
            {
                var json = File.ReadAllText(path);
                var status = JsonSerializer.Deserialize<CoderAgentStatus>(json, JsonOptions);
                if (status is not null && !IsStale(status, now))
                {
                    statuses.Add(Normalize(status));
                }
            }
            catch (Exception exception) when (exception is JsonException or IOException or UnauthorizedAccessException)
            {
            }
        }

        return statuses
            .OrderBy(static status => PetStateResolver.GetPhasePriority(status.Phase))
            .ThenByDescending(static status => status.UpdatedAtUtc)
            .ThenBy(static status => status.Agent, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    public static bool IsStale(CoderAgentStatus status, DateTimeOffset now)
    {
        var ttlSeconds = status.TtlSeconds ?? DefaultTtlSeconds;
        if (ttlSeconds <= 0)
        {
            return false;
        }

        return status.UpdatedAtUtc.AddSeconds(ttlSeconds) < now;
    }

    private static CoderAgentStatus Normalize(CoderAgentStatus status)
    {
        return status with
        {
            Agent = string.IsNullOrWhiteSpace(status.Agent) ? "coder" : status.Agent.Trim(),
            Message = string.IsNullOrWhiteSpace(status.Message) ? null : status.Message.Trim(),
            Workspace = string.IsNullOrWhiteSpace(status.Workspace) ? null : status.Workspace.Trim(),
            SessionId = string.IsNullOrWhiteSpace(status.SessionId) ? null : status.SessionId.Trim(),
            TaskSummary = string.IsNullOrWhiteSpace(status.TaskSummary) ? null : status.TaskSummary.Trim(),
            SourcePath = string.IsNullOrWhiteSpace(status.SourcePath) ? null : status.SourcePath.Trim()
        };
    }
}

public sealed class CoderStatusWriter
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseLower) }
    };

    private readonly string _directory;

    public CoderStatusWriter(string? directory = null)
    {
        _directory = directory ?? CoderStatusPaths.GetDefaultDirectory();
    }

    public string DirectoryPath => _directory;

    public async Task<CoderAgentStatus> EmitAsync(
        string agent,
        CoderAgentPhase phase,
        string? message = null,
        string? workspace = null,
        int? processId = null,
        int? ttlSeconds = null,
        string? sessionId = null,
        string? taskSummary = null,
        string? sourcePath = null,
        DateTimeOffset? now = null,
        CancellationToken cancellationToken = default)
    {
        var status = new CoderAgentStatus(
            string.IsNullOrWhiteSpace(agent) ? "coder" : agent.Trim(),
            phase,
            string.IsNullOrWhiteSpace(message) ? null : message.Trim(),
            string.IsNullOrWhiteSpace(workspace) ? null : workspace.Trim(),
            processId,
            now ?? DateTimeOffset.UtcNow,
            ttlSeconds,
            string.IsNullOrWhiteSpace(sessionId) ? null : sessionId.Trim(),
            string.IsNullOrWhiteSpace(taskSummary) ? null : taskSummary.Trim(),
            string.IsNullOrWhiteSpace(sourcePath) ? null : sourcePath.Trim());

        Directory.CreateDirectory(_directory);
        var path = CoderStatusPaths.GetStatusPath(_directory, status.Agent, status.SessionId);
        var temporaryPath = $"{path}.tmp";
        await using (var stream = File.Create(temporaryPath))
        {
            await JsonSerializer.SerializeAsync(stream, status, JsonOptions, cancellationToken)
                .ConfigureAwait(false);
        }

        if (File.Exists(path))
        {
            File.Delete(path);
        }

        File.Move(temporaryPath, path);
        return status;
    }

    public int Clear(string? agent = null)
    {
        if (!Directory.Exists(_directory))
        {
            return 0;
        }

        if (!string.IsNullOrWhiteSpace(agent))
        {
            var deletedForAgent = 0;
            foreach (var path in Directory.EnumerateFiles(_directory, "*.json")
                         .Where(path => CoderStatusPaths.IsStatusPathForAgent(path, agent))
                         .ToArray())
            {
                File.Delete(path);
                deletedForAgent++;
            }

            return deletedForAgent;
        }

        var deleted = 0;
        foreach (var path in Directory.EnumerateFiles(_directory, "*.json"))
        {
            File.Delete(path);
            deleted++;
        }

        return deleted;
    }
}

public sealed class ProcessCoderStatusSource : ICoderStatusSource
{
    private readonly IProcessInspector _processInspector;
    private readonly IReadOnlyList<string> _processNames;

    public ProcessCoderStatusSource(IProcessInspector processInspector, IReadOnlyList<string> processNames)
    {
        _processInspector = processInspector;
        _processNames = processNames;
    }

    public IReadOnlyList<CoderAgentStatus> GetStatuses(DateTimeOffset now)
    {
        return _processInspector.GetLongTasks(_processNames)
            .Select(task => new CoderAgentStatus(
                task.Name,
                IsCodexProcess(task.Name) ? CoderAgentPhase.Sleeping : CoderAgentPhase.Running,
                IsCodexProcess(task.Name) ? "No active Codex task is running." : "Detected running coder process.",
                Workspace: null,
                task.ProcessId,
                now,
                TtlSeconds: null))
            .ToArray();
    }

    private static bool IsCodexProcess(string processName)
    {
        return string.Equals(processName, "codex", StringComparison.OrdinalIgnoreCase);
    }
}

public sealed class CompositeCoderStatusSource : ICoderStatusSource
{
    private readonly IReadOnlyList<ICoderStatusSource> _sources;

    public CompositeCoderStatusSource(params ICoderStatusSource[] sources)
    {
        _sources = sources;
    }

    public IReadOnlyList<CoderAgentStatus> GetStatuses(DateTimeOffset now)
    {
        var byIdentity = new Dictionary<string, CoderAgentStatus>(StringComparer.OrdinalIgnoreCase);
        foreach (var source in _sources)
        {
            if (byIdentity.Count > 0)
            {
                break;
            }

            var sourceStatuses = source.GetStatuses(now)
                .GroupBy(static status => GetStatusIdentity(status), StringComparer.OrdinalIgnoreCase)
                .Select(static group => group
                    .OrderBy(static status => PetStateResolver.GetPhasePriority(status.Phase))
                    .ThenByDescending(static status => status.UpdatedAtUtc)
                    .First());

            foreach (var status in sourceStatuses)
            {
                var identity = GetStatusIdentity(status);
                if (!byIdentity.ContainsKey(identity))
                {
                    byIdentity[identity] = status;
                }
            }
        }

        return byIdentity.Values
            .OrderBy(static status => PetStateResolver.GetPhasePriority(status.Phase))
            .ThenByDescending(static status => status.UpdatedAtUtc)
            .ThenBy(static status => status.Agent, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private static string GetStatusIdentity(CoderAgentStatus status)
    {
        return string.IsNullOrWhiteSpace(status.SessionId)
            ? status.Agent
            : $"{status.Agent}:{status.SessionId}";
    }
}
