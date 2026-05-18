using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Vibestick.Gui;

public static class WindowFocusService
{
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

            NativeMethods.ShowWindowAsync(handle, NativeMethods.SwRestore);
            return NativeMethods.SetForegroundWindow(handle);
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException)
        {
            return false;
        }
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
