using System.Runtime.InteropServices;

namespace Vibestick.Core;

public interface ISleepBlocker
{
    IDisposable BlockSystemSleep();
}

public sealed class WindowsSleepBlocker : ISleepBlocker
{
    public IDisposable BlockSystemSleep()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Sleep blocking is only supported on Windows in this MVP.");
        }

        var result = NativeMethods.SetThreadExecutionState(
            ExecutionState.EsContinuous | ExecutionState.EsSystemRequired);

        if (result == 0)
        {
            throw new InvalidOperationException("SetThreadExecutionState failed.");
        }

        return new SleepBlockRelease();
    }

    private sealed class SleepBlockRelease : IDisposable
    {
        private bool _disposed;

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            NativeMethods.SetThreadExecutionState(ExecutionState.EsContinuous);
            _disposed = true;
        }
    }

    [Flags]
    private enum ExecutionState : uint
    {
        EsSystemRequired = 0x00000001,
        EsContinuous = 0x80000000
    }

    private static class NativeMethods
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern ExecutionState SetThreadExecutionState(ExecutionState flags);
    }
}

