using System.Text.Json;
using System.Text.RegularExpressions;

namespace Vibestick.Core;

public static class CodexSessionPaths
{
    public static string GetDefaultSessionsRoot()
    {
        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return Path.Combine(userProfile, ".codex", "sessions");
    }
}

public sealed record CodexSessionStatusUpdate(
    CoderAgentPhase Phase,
    string Message,
    int TtlSeconds);

public sealed record CodexSessionMetadata(
    string? SessionId,
    string? Workspace);

public static class CodexSessionEventMapper
{
    private const int MaxTaskSummaryLength = 48;
    private const int MaxTaskDetailLength = 118;
    private static readonly RegexOptions CleanupOptions =
        RegexOptions.IgnoreCase | RegexOptions.Singleline | RegexOptions.CultureInvariant;

    public static bool TryMapJsonLine(string line, out CodexSessionStatusUpdate update)
    {
        update = default!;
        if (string.IsNullOrWhiteSpace(line))
        {
            return false;
        }

        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (!TryGetString(root, "type", out var type) ||
                !root.TryGetProperty("payload", out var payload))
            {
                return false;
            }

            if (string.Equals(type, "event_msg", StringComparison.OrdinalIgnoreCase))
            {
                return TryMapEventMessage(payload, out update);
            }

            if (string.Equals(type, "response_item", StringComparison.OrdinalIgnoreCase))
            {
                return TryMapResponseItem(payload, out update);
            }
        }
        catch (JsonException)
        {
        }

        return false;
    }

    public static bool TryReadSessionMetadata(string line, out CodexSessionMetadata metadata)
    {
        metadata = default!;
        if (string.IsNullOrWhiteSpace(line))
        {
            return false;
        }

        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (!TryGetString(root, "type", out var type) ||
                !string.Equals(type, "session_meta", StringComparison.OrdinalIgnoreCase) ||
                !root.TryGetProperty("payload", out var payload))
            {
                return false;
            }

            TryGetString(payload, "id", out var sessionId);
            TryGetString(payload, "cwd", out var workspace);
            if (string.IsNullOrWhiteSpace(sessionId) && string.IsNullOrWhiteSpace(workspace))
            {
                return false;
            }

            metadata = new CodexSessionMetadata(
                string.IsNullOrWhiteSpace(sessionId) ? null : sessionId.Trim(),
                string.IsNullOrWhiteSpace(workspace) ? null : workspace.Trim());
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    public static bool TryReadTaskSummary(string line, out string summary)
    {
        summary = string.Empty;
        if (string.IsNullOrWhiteSpace(line))
        {
            return false;
        }

        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (!TryGetString(root, "type", out var type) ||
                !root.TryGetProperty("payload", out var payload))
            {
                return false;
            }

            if (string.Equals(type, "event_msg", StringComparison.OrdinalIgnoreCase) &&
                TryGetString(payload, "type", out var eventType) &&
                string.Equals(eventType, "user_message", StringComparison.OrdinalIgnoreCase) &&
                TryGetString(payload, "message", out var eventMessage))
            {
                return TryNormalizeTaskSummary(eventMessage, out summary);
            }

            if (!string.Equals(type, "response_item", StringComparison.OrdinalIgnoreCase) ||
                !TryGetString(payload, "type", out var itemType) ||
                !string.Equals(itemType, "message", StringComparison.OrdinalIgnoreCase) ||
                !TryGetString(payload, "role", out var role) ||
                !string.Equals(role, "user", StringComparison.OrdinalIgnoreCase) ||
                !payload.TryGetProperty("content", out var content) ||
                content.ValueKind != JsonValueKind.Array)
            {
                return false;
            }

            foreach (var contentItem in content.EnumerateArray())
            {
                if (contentItem.ValueKind != JsonValueKind.Object ||
                    !TryGetString(contentItem, "type", out var contentType) ||
                    contentType is not "input_text" and not "text" ||
                    !TryGetString(contentItem, "text", out var text))
                {
                    continue;
                }

                if (TryNormalizeTaskSummary(text, out summary))
                {
                    return true;
                }
            }
        }
        catch (JsonException)
        {
        }

        return false;
    }

    public static bool TryReadTaskDetail(string line, out string detail)
    {
        detail = string.Empty;
        if (string.IsNullOrWhiteSpace(line))
        {
            return false;
        }

        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (!TryGetString(root, "type", out var type) ||
                !root.TryGetProperty("payload", out var payload))
            {
                return false;
            }

            if (string.Equals(type, "event_msg", StringComparison.OrdinalIgnoreCase) &&
                TryGetString(payload, "type", out var eventType) &&
                string.Equals(eventType, "agent_message", StringComparison.OrdinalIgnoreCase) &&
                TryGetString(payload, "message", out var eventMessage))
            {
                return TryNormalizeTaskDetail(eventMessage, out detail);
            }

            if (!string.Equals(type, "response_item", StringComparison.OrdinalIgnoreCase) ||
                !TryGetString(payload, "type", out var itemType) ||
                !string.Equals(itemType, "message", StringComparison.OrdinalIgnoreCase) ||
                !TryGetString(payload, "role", out var role) ||
                !string.Equals(role, "assistant", StringComparison.OrdinalIgnoreCase) ||
                !payload.TryGetProperty("content", out var content) ||
                content.ValueKind != JsonValueKind.Array)
            {
                return false;
            }

            foreach (var contentItem in content.EnumerateArray())
            {
                if (contentItem.ValueKind != JsonValueKind.Object ||
                    !TryGetString(contentItem, "type", out var contentType) ||
                    contentType is not "output_text" and not "text" ||
                    !TryGetString(contentItem, "text", out var text))
                {
                    continue;
                }

                if (TryNormalizeTaskDetail(text, out detail))
                {
                    return true;
                }
            }
        }
        catch (JsonException)
        {
        }

        return false;
    }

    public static bool TryReadTimestamp(string line, out DateTimeOffset timestamp)
    {
        timestamp = default;
        if (string.IsNullOrWhiteSpace(line))
        {
            return false;
        }

        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            return TryGetString(root, "timestamp", out var value) &&
                DateTimeOffset.TryParse(value, out timestamp);
        }
        catch (JsonException)
        {
            return false;
        }
    }

    public static bool TryNormalizeTaskSummary(string value, out string summary)
    {
        summary = string.Empty;
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var cleaned = CleanCodexDisplayText(value);
        if (cleaned.Length == 0)
        {
            return false;
        }

        var researchName = Regex.Match(
            cleaned,
            @"(?:^|\s)#+\s*Task\s+Research\s+name:\s*(?<name>.+?)\s+category:",
            CleanupOptions);
        if (researchName.Success)
        {
            cleaned = researchName.Groups["name"].Value.Trim();
        }

        cleaned = BuildShortTaskSummary(cleaned);
        summary = Truncate(cleaned, MaxTaskSummaryLength);
        return true;
    }

    public static bool TryNormalizeTaskDetail(string value, out string detail)
    {
        detail = string.Empty;
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var cleaned = CleanCodexDisplayText(value);
        if (cleaned.Length == 0)
        {
            return false;
        }

        detail = Truncate(cleaned, MaxTaskDetailLength);
        return true;
    }

    private static string CleanCodexDisplayText(string value)
    {
        var cleaned = Regex.Replace(
            value,
            "<environment_context>.*?</environment_context>",
            " ",
            CleanupOptions);
        cleaned = Regex.Replace(
            cleaned,
            "<image>.*?</image>",
            " ",
            CleanupOptions);
        cleaned = Regex.Replace(
            cleaned,
            "<oai-mem-citation>.*?</oai-mem-citation>",
            " ",
            CleanupOptions);
        cleaned = Regex.Replace(cleaned, @"!\[[^\]]*\]\([^)]+\)", " ", CleanupOptions);
        cleaned = Regex.Replace(cleaned, @"\[\$[^\]]+\]\([^)]+\)", " ", CleanupOptions);
        cleaned = Regex.Replace(cleaned, @"\[([^\]]+)\]\([^)]+\)", "$1", CleanupOptions);
        cleaned = Regex.Replace(cleaned, @"`[^`]*[\\/][^`]*`", " ", CleanupOptions);
        cleaned = Regex.Replace(cleaned, @"[A-Za-z]:\\[^\s\]\)>""']+", " ", CleanupOptions);
        cleaned = Regex.Replace(cleaned, @"\s+", " ").Trim();
        return NormalizeKnownTerms(cleaned);
    }

    private static string BuildShortTaskSummary(string cleaned)
    {
        cleaned = StripRequestPrefix(cleaned);
        if (cleaned.Length == 0)
        {
            return cleaned;
        }

        if (ContainsHan(cleaned))
        {
            if (ContainsAny(cleaned, "\u8c03\u7814", "\u7814\u7a76") &&
                Regex.IsMatch(cleaned, "LLM", CleanupOptions) &&
                Regex.IsMatch(cleaned, "Router", CleanupOptions))
            {
                return "\u8c03\u7814 LLM Router \u65b9\u6848";
            }

            if ((Regex.IsMatch(cleaned, "pet", CleanupOptions) || cleaned.Contains("\u5ba0\u7269", StringComparison.Ordinal)) &&
                (Regex.IsMatch(cleaned, "summary", CleanupOptions) || cleaned.Contains("\u6458\u8981\u683c\u5f0f", StringComparison.Ordinal)))
            {
                return "\u8c03\u6574 pet \u6458\u8981\u683c\u5f0f";
            }

            var clause = cleaned.Split(
                    new[] { '\uFF0C', '\u3002', '\uFF01', '\uFF1F', '!', '?', '\uFF1B', ';', '\uFF1A', ':' },
                    StringSplitOptions.RemoveEmptyEntries)
                .Select(static part => part.Trim())
                .FirstOrDefault(static part => part.Length > 0) ?? cleaned;
            return StripRequestPrefix(clause);
        }

        return cleaned;
    }

    private static string StripRequestPrefix(string value)
    {
        var cleaned = value.Trim();
        foreach (var prefix in new[]
                 {
                     "please implement this plan:",
                     "please ",
                     "can you ",
                     "could you ",
                     "help me ",
                     "\u8bf7\u5e2e\u6211",
                     "\u8bf7\u4f60\u5e2e\u6211",
                     "\u5e2e\u6211",
                     "\u9ebb\u70e6\u5e2e\u6211",
                     "\u9ebb\u70e6\u4f60",
                     "\u8bf7",
                     "\u6211\u60f3",
                     "\u6211\u73b0\u5728\u5e0c\u671b",
                     "\u73b0\u5728\u6211\u5e0c\u671b",
                     "\u73b0\u5728\u5e0c\u671b",
                     "\u5e0c\u671b"
                 })
        {
            if (cleaned.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                cleaned = cleaned[prefix.Length..].Trim();
                break;
            }
        }

        return cleaned.Trim(' ', '\t', '\r', '\n', '\uFF0C', '\u3002', ':', '\uFF1A', '-', '\'', '"');
    }

    private static string NormalizeKnownTerms(string value)
    {
        var normalized = Regex.Replace(value, "llm", "LLM", CleanupOptions);
        normalized = Regex.Replace(normalized, "router", "Router", CleanupOptions);
        normalized = Regex.Replace(normalized, "cursor", "Cursor", CleanupOptions);
        normalized = Regex.Replace(normalized, "qwen", "Qwen", CleanupOptions);
        return normalized;
    }

    private static string Truncate(string value, int maxLength)
    {
        var cleaned = value.Trim();
        return cleaned.Length <= maxLength
            ? cleaned
            : $"{cleaned[..(maxLength - 3)]}...";
    }

    private static bool ContainsHan(string value)
    {
        return value.Any(static character => character is >= '\u4e00' and <= '\u9fff');
    }

    private static bool ContainsAny(string value, params string[] tokens)
    {
        return tokens.Any(token => value.Contains(token, StringComparison.Ordinal));
    }

    private static bool TryMapEventMessage(JsonElement payload, out CodexSessionStatusUpdate update)
    {
        update = default!;
        if (!TryGetString(payload, "type", out var eventType))
        {
            return false;
        }

        update = eventType switch
        {
            "task_started" or "user_message" => new CodexSessionStatusUpdate(
                CoderAgentPhase.Reasoning,
                "Codex is thinking",
                30),
            "task_complete" => new CodexSessionStatusUpdate(
                CoderAgentPhase.Success,
                "Codex finished",
                10),
            _ => null!
        };

        return update is not null;
    }

    private static bool TryMapResponseItem(JsonElement payload, out CodexSessionStatusUpdate update)
    {
        update = default!;
        if (!TryGetString(payload, "type", out var itemType))
        {
            return false;
        }

        update = itemType switch
        {
            "reasoning" => new CodexSessionStatusUpdate(
                CoderAgentPhase.Reasoning,
                "Codex is thinking",
                30),
            "function_call" or "custom_tool_call" => new CodexSessionStatusUpdate(
                CoderAgentPhase.ToolCalling,
                $"Using {GetToolName(payload)}",
                30),
            "function_call_output" or "custom_tool_call_output" => new CodexSessionStatusUpdate(
                CoderAgentPhase.Reasoning,
                "Reviewing tool result",
                30),
            _ => null!
        };

        return update is not null;
    }

    private static string GetToolName(JsonElement payload)
    {
        if (!TryGetString(payload, "name", out var name) &&
            !TryGetString(payload, "tool_name", out name))
        {
            return "tool";
        }

        name = name.Trim();
        if (name.Length == 0)
        {
            return "tool";
        }

        return name.Length <= 48 ? name : name[..48];
    }

    private static bool TryGetString(JsonElement element, string propertyName, out string value)
    {
        value = string.Empty;
        if (!element.TryGetProperty(propertyName, out var property) ||
            property.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        value = property.GetString() ?? string.Empty;
        return true;
    }
}

public sealed class CodexSessionStatusBridge : IDisposable
{
    private static readonly TimeSpan DebounceInterval = TimeSpan.FromMilliseconds(200);
    private static readonly TimeSpan RecentSessionWindow = TimeSpan.FromHours(12);
    private const int MaxTrackedSessions = 12;
    private const int ActiveSessionTtlSeconds = 300;

    private readonly string _sessionsRoot;
    private readonly CoderStatusWriter _writer;
    private readonly Func<DateTimeOffset> _clock;
    private readonly SemaphoreSlim _refreshLock = new(1, 1);
    private readonly Dictionary<string, TrackedCodexSession> _sessions = new(StringComparer.OrdinalIgnoreCase);
    private FileSystemWatcher? _watcher;
    private Timer? _debounceTimer;
    private string? _activeSessionPath;
    private bool _disposed;

    public CodexSessionStatusBridge(
        string statusDirectory,
        string? sessionsRoot = null,
        Func<DateTimeOffset>? clock = null)
    {
        _sessionsRoot = sessionsRoot ?? CodexSessionPaths.GetDefaultSessionsRoot();
        _writer = new CoderStatusWriter(statusDirectory);
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    public string SessionsRoot => _sessionsRoot;

    public string? ActiveSessionPath => _activeSessionPath;

    public IReadOnlyList<string> ActiveSessionPaths => _sessions.Keys
        .OrderBy(static path => path, StringComparer.OrdinalIgnoreCase)
        .ToArray();

    public bool IsRunning => _watcher is not null;

    public void Start()
    {
        if (_disposed || _watcher is not null || !Directory.Exists(_sessionsRoot))
        {
            return;
        }

        _debounceTimer = new Timer(_ => _ = RefreshAsync(), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
        _watcher = new FileSystemWatcher(_sessionsRoot, "rollout-*.jsonl")
        {
            IncludeSubdirectories = true,
            NotifyFilter = NotifyFilters.CreationTime |
                NotifyFilters.FileName |
                NotifyFilters.LastWrite |
                NotifyFilters.Size
        };
        _watcher.Changed += (_, _) => ScheduleRefresh();
        _watcher.Created += (_, _) => ScheduleRefresh();
        _watcher.Renamed += (_, _) => ScheduleRefresh();
        _watcher.Error += (_, _) => ScheduleRefresh();
        _watcher.EnableRaisingEvents = true;

        TrackRecentSessions(_clock());
        ScheduleRefresh();
    }

    public void Dispose()
    {
        _disposed = true;
        _watcher?.Dispose();
        _watcher = null;
        _debounceTimer?.Dispose();
        _debounceTimer = null;
        _refreshLock.Dispose();
    }

    private void ScheduleRefresh()
    {
        if (_disposed)
        {
            return;
        }

        _debounceTimer?.Change(DebounceInterval, Timeout.InfiniteTimeSpan);
    }

    private async Task RefreshAsync()
    {
        if (_disposed)
        {
            return;
        }

        await _refreshLock.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_disposed)
            {
                return;
            }

            var now = _clock();
            TrackRecentSessions(now);
            foreach (var session in _sessions.Values.ToArray())
            {
                await RefreshSessionAsync(session, now).ConfigureAwait(false);
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }
        finally
        {
            _refreshLock.Release();
        }
    }

    private void TrackRecentSessions(DateTimeOffset now)
    {
        var paths = FindRecentSessionPaths(now);
        _activeSessionPath = paths.FirstOrDefault();
        var pathSet = paths.ToHashSet(StringComparer.OrdinalIgnoreCase);

        foreach (var path in paths)
        {
            if (!_sessions.ContainsKey(path))
            {
                _sessions[path] = new TrackedCodexSession(path);
            }
        }

        foreach (var path in _sessions.Keys.Where(path => !pathSet.Contains(path)).ToArray())
        {
            _sessions.Remove(path);
        }
    }

    private IReadOnlyList<string> FindRecentSessionPaths(DateTimeOffset now)
    {
        try
        {
            return Directory.EnumerateFiles(_sessionsRoot, "rollout-*.jsonl", SearchOption.AllDirectories)
                .Select(static path => new FileInfo(path))
                .Where(static file => file.Exists)
                .Where(file => new DateTimeOffset(file.LastWriteTimeUtc, TimeSpan.Zero) >= now.Subtract(RecentSessionWindow))
                .OrderByDescending(static file => file.LastWriteTimeUtc)
                .ThenByDescending(static file => file.FullName, StringComparer.OrdinalIgnoreCase)
                .Take(MaxTrackedSessions)
                .Select(static file => file.FullName)
                .ToArray();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return Array.Empty<string>();
        }
    }

    private async Task RefreshSessionAsync(TrackedCodexSession session, DateTimeOffset now)
    {
        if (!File.Exists(session.Path))
        {
            return;
        }

        var length = new FileInfo(session.Path).Length;
        if (length < session.Position)
        {
            session.Position = 0;
        }

        if (length == session.Position)
        {
            return;
        }

        var lines = ReadNewLines(session.Path, session.Position);
        session.Position = new FileInfo(session.Path).Length;

        CodexSessionStatusUpdate? latestUpdate = null;
        DateTimeOffset latestTimestamp = now;
        foreach (var line in lines)
        {
            if (CodexSessionEventMapper.TryReadSessionMetadata(line, out var metadata))
            {
                session.SessionId ??= metadata.SessionId;
                session.Workspace ??= metadata.Workspace;
            }

            if (session.TaskSummary is null &&
                CodexSessionEventMapper.TryReadTaskSummary(line, out var taskSummary))
            {
                session.TaskSummary = taskSummary;
            }

            if (CodexSessionEventMapper.TryReadTaskDetail(line, out var taskDetail))
            {
                session.TaskDetail = taskDetail;
            }

            if (!CodexSessionEventMapper.TryMapJsonLine(line, out var update))
            {
                continue;
            }

            latestUpdate = update;
            latestTimestamp = CodexSessionEventMapper.TryReadTimestamp(line, out var timestamp)
                ? timestamp
                : now;
        }

        if (latestUpdate is null)
        {
            return;
        }

        var ttlSeconds = GetBridgeTtlSeconds(latestUpdate);
        if (latestTimestamp.AddSeconds(ttlSeconds) < now)
        {
            return;
        }

        await _writer.EmitAsync(
                "codex",
                latestUpdate.Phase,
                latestUpdate.Message,
                session.Workspace,
                processId: null,
                ttlSeconds,
                sessionId: session.SessionId ?? Path.GetFileNameWithoutExtension(session.Path),
                taskSummary: session.TaskSummary ?? BuildFallbackSummary(session),
                sourcePath: session.Path,
                taskDetail: session.TaskDetail,
                now: latestTimestamp)
            .ConfigureAwait(false);
    }

    private static int GetBridgeTtlSeconds(CodexSessionStatusUpdate update)
    {
        return update.Phase == CoderAgentPhase.Success
            ? update.TtlSeconds
            : Math.Max(update.TtlSeconds, ActiveSessionTtlSeconds);
    }

    private static string BuildFallbackSummary(TrackedCodexSession session)
    {
        if (!string.IsNullOrWhiteSpace(session.Workspace))
        {
            var workspaceName = Path.GetFileName(session.Workspace.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
            if (!string.IsNullOrWhiteSpace(workspaceName))
            {
                return $"Codex task in {workspaceName}";
            }
        }

        return "Codex task";
    }

    private static IReadOnlyList<string> ReadNewLines(string path, long position)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        stream.Seek(position, SeekOrigin.Begin);
        using var reader = new StreamReader(stream);
        var lines = new List<string>();
        while (reader.ReadLine() is { } line)
        {
            lines.Add(line);
        }

        return lines;
    }

    private sealed class TrackedCodexSession
    {
        public TrackedCodexSession(string path)
        {
            Path = path;
        }

        public string Path { get; }

        public long Position { get; set; }

        public string? SessionId { get; set; }

        public string? Workspace { get; set; }

        public string? TaskSummary { get; set; }

        public string? TaskDetail { get; set; }
    }
}
