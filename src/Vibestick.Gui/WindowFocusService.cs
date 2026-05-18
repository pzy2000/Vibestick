using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using Vibestick.Core;

namespace Vibestick.Gui;

public static class WindowFocusService
{
    private static readonly string[] LikelyCoderProcesses = { "codex", "Code", "Cursor", "VSCodium" };
    private static readonly string[] CodexProcesses = { "codex", "Codex" };

    public static bool TryFocusCoderWindow(CoderAgentStatus? status)
    {
        if (status is null || !OperatingSystem.IsWindows())
        {
            return false;
        }

        if (TryFocusProcessWindow(status.ProcessId))
        {
            return true;
        }

        var workspaceName = GetWorkspaceName(status.Workspace);
        if (string.Equals(status.Agent, "codex", StringComparison.OrdinalIgnoreCase) &&
            TryFocusCodexAppWindow(status.Workspace))
        {
            return true;
        }

        foreach (var processName in LikelyCoderProcesses)
        {
            foreach (var process in GetUniqueProcessesByName(processName))
            {
                try
                {
                    if (process.MainWindowHandle == IntPtr.Zero)
                    {
                        continue;
                    }

                    var title = process.MainWindowTitle;
                    if (!string.IsNullOrWhiteSpace(workspaceName) &&
                        title.Contains(workspaceName, StringComparison.OrdinalIgnoreCase))
                    {
                        return TryFocusProcessWindow(process.Id);
                    }

                    if (string.Equals(status.Agent, "codex", StringComparison.OrdinalIgnoreCase) &&
                        IsCodexDesktopWindow(process, title))
                    {
                        return TryFocusProcessWindow(process.Id);
                    }
                }
                catch (Exception exception) when (exception is InvalidOperationException or ArgumentException)
                {
                }
            }
        }

        return false;
    }

    public static bool TryFocusCodexAppWindow(string? workspace = null)
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }

        var workspaceName = GetWorkspaceName(workspace);
        foreach (var process in GetUniqueProcessesByName(CodexProcesses))
        {
            try
            {
                if (process.MainWindowHandle == IntPtr.Zero)
                {
                    continue;
                }

                var title = process.MainWindowTitle;
                if (!string.IsNullOrWhiteSpace(workspaceName) &&
                    title.Contains(workspaceName, StringComparison.OrdinalIgnoreCase))
                {
                    return TryFocusWindowHandle(process.MainWindowHandle);
                }

                if (IsCodexDesktopWindow(process, title))
                {
                    return TryFocusWindowHandle(process.MainWindowHandle);
                }
            }
            catch (Exception exception) when (exception is InvalidOperationException or ArgumentException)
            {
            }
        }

        return false;
    }

    public static bool TryFocusProcessWindow(int? processId)
    {
        if (!processId.HasValue || !OperatingSystem.IsWindows())
        {
            return false;
        }

        try
        {
            var process = Process.GetProcessById(processId.Value);
            var handle = process.MainWindowHandle;
            if (handle == IntPtr.Zero)
            {
                return false;
            }

            return TryFocusWindowHandle(handle);
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException)
        {
            return false;
        }
    }

    private static string? GetWorkspaceName(string? workspace)
    {
        if (string.IsNullOrWhiteSpace(workspace))
        {
            return null;
        }

        return Path.GetFileName(workspace.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
    }

    private static IEnumerable<Process> GetUniqueProcessesByName(params string[] processNames)
    {
        var seen = new HashSet<int>();
        foreach (var processName in processNames)
        {
            foreach (var process in Process.GetProcessesByName(processName))
            {
                if (seen.Add(process.Id))
                {
                    yield return process;
                }
            }
        }
    }

    private static bool TryFocusWindowHandle(IntPtr handle)
    {
        NativeMethods.ShowWindowAsync(handle, NativeMethods.SwRestore);
        return NativeMethods.SetForegroundWindow(handle);
    }

    private static bool IsCodexDesktopWindow(Process process, string title)
    {
        return string.Equals(process.ProcessName, "Codex", StringComparison.Ordinal) ||
            title.Contains("Codex", StringComparison.OrdinalIgnoreCase);
    }

    private static class NativeMethods
    {
        internal const int SwRestore = 9;

        [DllImport("user32.dll")]
        internal static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        internal static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    }
}
