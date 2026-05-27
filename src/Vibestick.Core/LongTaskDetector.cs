using System.Diagnostics;
using System.Management;

namespace Vibestick.Core;

public interface IProcessInspector
{
    IReadOnlyList<LongTaskProcess> GetLongTasks(IReadOnlyList<string> whitelist);
}

public sealed class WindowsProcessInspector : IProcessInspector
{
    public IReadOnlyList<LongTaskProcess> GetLongTasks(IReadOnlyList<string> whitelist)
    {
        var matches = new List<LongTaskProcess>();
        IReadOnlyDictionary<int, string>? commandLinesByProcessId = null;

        foreach (var process in Process.GetProcesses())
        {
            try
            {
                if (LongTaskDetector.TryMatchProcessName(process.ProcessName, whitelist, out var processMatch))
                {
                    matches.Add(new LongTaskProcess(process.Id, processMatch));
                }
                else if (LongTaskDetector.ShouldInspectCommandLine(process.ProcessName, whitelist))
                {
                    commandLinesByProcessId ??= ReadCommandLinesByProcessId();
                    if (commandLinesByProcessId.TryGetValue(process.Id, out var commandLine) &&
                        LongTaskDetector.TryMatchCommandLine(process.ProcessName, commandLine, whitelist, out var commandLineMatch))
                    {
                        matches.Add(new LongTaskProcess(process.Id, commandLineMatch));
                    }
                }
            }
            catch (InvalidOperationException)
            {
            }
        }

        return matches
            .GroupBy(static task => Normalize(task.Name), StringComparer.OrdinalIgnoreCase)
            .Select(static group => group.OrderBy(static task => task.ProcessId ?? int.MaxValue).First())
            .OrderBy(static task => task.Name, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private static IReadOnlyDictionary<int, string> ReadCommandLinesByProcessId()
    {
        if (!OperatingSystem.IsWindows())
        {
            return new Dictionary<int, string>();
        }

        var commandLines = new Dictionary<int, string>();
        try
        {
            using var searcher = new ManagementObjectSearcher("SELECT ProcessId, CommandLine FROM Win32_Process");
            foreach (ManagementObject process in searcher.Get())
            {
                if (process["ProcessId"] is uint processId &&
                    process["CommandLine"] is string commandLine &&
                    !string.IsNullOrWhiteSpace(commandLine))
                {
                    commandLines[(int)processId] = commandLine;
                }
            }
        }
        catch (ManagementException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }

        return commandLines;
    }

    private static string Normalize(string value) => LongTaskDetector.NormalizeProcessName(value);
}

public static class LongTaskDetector
{
    private static readonly string[] CommandLineHostProcessNames =
    {
        "node",
        "python",
        "python3",
        "bun",
        "deno",
        "npm",
        "npx",
        "pnpm",
        "cmd",
        "powershell",
        "pwsh"
    };

    private static readonly string[] CommandLineCoderAliases =
    {
        "claude",
        "claude-code",
        "opencode",
        "openclaw",
        "openclaw-cli",
        "openclaw-doctor",
        "hermes",
        "nanobot"
    };

    public static bool IsMatch(string processName, IReadOnlyList<string> whitelist)
    {
        return TryMatchProcessName(processName, whitelist, out _);
    }

    public static bool TryMatchProcessName(
        string processName,
        IReadOnlyList<string> whitelist,
        out string match)
    {
        var normalized = NormalizeProcessName(processName);
        match = whitelist
            .Select(NormalizeProcessName)
            .FirstOrDefault(entry => entry == normalized) ?? string.Empty;
        return match.Length > 0;
    }

    public static bool ShouldInspectCommandLine(string processName, IReadOnlyList<string> whitelist)
    {
        if (!IsCommandLineHostProcess(processName))
        {
            return false;
        }

        return CommandLineCoderAliases.Any(alias => ContainsNormalized(whitelist, alias));
    }

    public static bool TryMatchCommandLine(
        string processName,
        string commandLine,
        IReadOnlyList<string> whitelist,
        out string match)
    {
        match = string.Empty;
        if (!IsCommandLineHostProcess(processName))
        {
            return false;
        }

        foreach (var alias in CommandLineCoderAliases)
        {
            if (ContainsNormalized(whitelist, alias) && CommandLineContainsAlias(commandLine, alias))
            {
                match = alias;
                return true;
            }
        }

        return false;
    }

    public static IReadOnlyList<string> FindMatches(
        IEnumerable<string> processNames,
        IReadOnlyList<string> whitelist)
    {
        return processNames
            .Select(name => TryMatchProcessName(name, whitelist, out var match) ? match : null)
            .Where(static match => match is not null)
            .Select(static match => match!)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(static name => name, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    public static string NormalizeProcessName(string processName)
    {
        var name = processName.Trim().ToLowerInvariant();
        foreach (var extension in new[] { ".exe", ".cmd", ".ps1" })
        {
            if (name.EndsWith(extension, StringComparison.OrdinalIgnoreCase))
            {
                return name[..^extension.Length];
            }
        }

        return name;
    }

    private static bool IsCommandLineHostProcess(string processName)
    {
        var normalized = NormalizeProcessName(processName);
        return CommandLineHostProcessNames.Any(host => NormalizeProcessName(host) == normalized);
    }

    private static bool ContainsNormalized(IReadOnlyList<string> values, string value)
    {
        var normalized = NormalizeProcessName(value);
        return values.Any(entry => NormalizeProcessName(entry) == normalized);
    }

    private static bool CommandLineContainsAlias(string commandLine, string alias)
    {
        var normalizedAlias = NormalizeProcessName(alias);
        foreach (var token in SplitCommandLine(commandLine))
        {
            foreach (var candidate in GetTokenCandidates(token))
            {
                if (NormalizeProcessName(candidate) == normalizedAlias)
                {
                    return true;
                }
            }
        }

        return false;
    }

    private static IEnumerable<string> SplitCommandLine(string commandLine)
    {
        var tokenStart = -1;
        var inQuotes = false;
        for (var index = 0; index < commandLine.Length; index++)
        {
            var character = commandLine[index];
            if (character == '"')
            {
                inQuotes = !inQuotes;
                tokenStart = tokenStart < 0 ? index : tokenStart;
                continue;
            }

            if (char.IsWhiteSpace(character) && !inQuotes)
            {
                if (tokenStart >= 0)
                {
                    yield return commandLine[tokenStart..index];
                    tokenStart = -1;
                }
            }
            else if (tokenStart < 0)
            {
                tokenStart = index;
            }
        }

        if (tokenStart >= 0)
        {
            yield return commandLine[tokenStart..];
        }
    }

    private static IEnumerable<string> GetTokenCandidates(string token)
    {
        var trimmed = token.Trim().Trim('"', '\'');
        if (trimmed.Length == 0)
        {
            yield break;
        }

        foreach (var part in trimmed.Split(new[] { '\\', '/', '=', ';' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = part.Trim().Trim('"', '\'');
            if (candidate.Length == 0)
            {
                continue;
            }

            var versionSeparator = candidate.IndexOf('@', 1);
            if (versionSeparator > 0)
            {
                candidate = candidate[..versionSeparator];
            }

            yield return candidate;

            var withoutExtension = Path.GetFileNameWithoutExtension(candidate);
            if (!string.IsNullOrWhiteSpace(withoutExtension) &&
                !string.Equals(withoutExtension, candidate, StringComparison.OrdinalIgnoreCase))
            {
                yield return withoutExtension;
            }
        }
    }
}
