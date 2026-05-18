using System.Diagnostics;

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
        foreach (var process in Process.GetProcesses())
        {
            try
            {
                if (LongTaskDetector.IsMatch(process.ProcessName, whitelist))
                {
                    matches.Add(new LongTaskProcess(process.Id, process.ProcessName));
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

    private static string Normalize(string value) => LongTaskDetector.NormalizeProcessName(value);
}

public static class LongTaskDetector
{
    public static bool IsMatch(string processName, IReadOnlyList<string> whitelist)
    {
        var normalized = NormalizeProcessName(processName);
        return whitelist.Any(entry => NormalizeProcessName(entry) == normalized);
    }

    public static IReadOnlyList<string> FindMatches(
        IEnumerable<string> processNames,
        IReadOnlyList<string> whitelist)
    {
        return processNames
            .Where(name => IsMatch(name, whitelist))
            .Select(NormalizeProcessName)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(static name => name, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    public static string NormalizeProcessName(string processName)
    {
        var name = processName.Trim().ToLowerInvariant();
        return name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
            ? name[..^4]
            : name;
    }
}

