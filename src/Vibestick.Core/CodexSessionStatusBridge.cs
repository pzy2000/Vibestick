using System.Text.Json;

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

public static class CodexSessionEventMapper
{
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

    private readonly string _sessionsRoot;
    private readonly CoderStatusWriter _writer;
    private readonly Func<DateTimeOffset> _clock;
    private readonly SemaphoreSlim _refreshLock = new(1, 1);
    private FileSystemWatcher? _watcher;
    private Timer? _debounceTimer;
    private string? _activeSessionPath;
    private long _position;
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

        SelectLatestSession(tailFromEnd: true);
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

            SelectLatestSession(tailFromEnd: false);
            if (_activeSessionPath is null || !File.Exists(_activeSessionPath))
            {
                return;
            }

            var length = new FileInfo(_activeSessionPath).Length;
            if (length < _position)
            {
                _position = 0;
            }

            if (length == _position)
            {
                return;
            }

            var lines = ReadNewLines(_activeSessionPath, _position);
            _position = new FileInfo(_activeSessionPath).Length;

            foreach (var line in lines)
            {
                if (CodexSessionEventMapper.TryMapJsonLine(line, out var update))
                {
                    await _writer.EmitAsync(
                            "codex",
                            update.Phase,
                            update.Message,
                            ttlSeconds: update.TtlSeconds,
                            now: _clock())
                        .ConfigureAwait(false);
                }
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

    private void SelectLatestSession(bool tailFromEnd)
    {
        var latest = FindLatestSessionPath();
        if (latest is null || string.Equals(latest, _activeSessionPath, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        _activeSessionPath = latest;
        _position = tailFromEnd && File.Exists(latest) ? new FileInfo(latest).Length : 0;
    }

    private string? FindLatestSessionPath()
    {
        try
        {
            return Directory.EnumerateFiles(_sessionsRoot, "rollout-*.jsonl", SearchOption.AllDirectories)
                .Select(static path => new FileInfo(path))
                .Where(static file => file.Exists)
                .OrderByDescending(static file => file.LastWriteTimeUtc)
                .ThenByDescending(static file => file.FullName, StringComparer.OrdinalIgnoreCase)
                .FirstOrDefault()
                ?.FullName;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
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
}
