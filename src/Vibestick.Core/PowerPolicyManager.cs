namespace Vibestick.Core;

public interface IPowerPolicyManager
{
    Task<string> GetActiveSchemeGuidAsync(CancellationToken cancellationToken = default);

    Task<PowerPolicySnapshot> ReadLidActionAsync(
        string schemeGuid,
        CancellationToken cancellationToken = default);

    Task SetLidActionAsync(
        string schemeGuid,
        int acLidAction,
        int dcLidAction,
        CancellationToken cancellationToken = default);

    Task RestoreLidActionAsync(
        PowerPolicySnapshot snapshot,
        CancellationToken cancellationToken = default);
}

public sealed class PowerPolicyException : Exception
{
    public PowerPolicyException(string message)
        : base(message)
    {
    }

    public PowerPolicyException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed class PowerCfgPowerPolicyManager : IPowerPolicyManager
{
    public const string SubButtonsGuid = "4f971e89-eebd-4455-a8de-9e59040e7347";
    public const string LidActionGuid = "5ca83367-6e45-459f-a27b-476b1d01c936";
    public const int LidActionDoNothing = 0;

    private readonly ICommandRunner _runner;

    public PowerCfgPowerPolicyManager(ICommandRunner runner)
    {
        _runner = runner;
    }

    public async Task<string> GetActiveSchemeGuidAsync(CancellationToken cancellationToken = default)
    {
        var result = await RunPowerCfgAsync("/GETACTIVESCHEME", "read active power scheme", cancellationToken)
            .ConfigureAwait(false);

        try
        {
            return PowerCfgParser.ParseFirstGuid(result.StandardOutput);
        }
        catch (FormatException exception)
        {
            throw new PowerPolicyException("Could not parse the active power scheme GUID.", exception);
        }
    }

    public async Task<PowerPolicySnapshot> ReadLidActionAsync(
        string schemeGuid,
        CancellationToken cancellationToken = default)
    {
        var normalizedScheme = NormalizeGuid(schemeGuid);
        var result = await RunPowerCfgAsync(
                $"/QH {normalizedScheme} {SubButtonsGuid} {LidActionGuid}",
                "read lid close action",
                cancellationToken)
            .ConfigureAwait(false);

        try
        {
            return PowerCfgParser.ParseLidActionSnapshot(normalizedScheme, result.StandardOutput);
        }
        catch (FormatException exception)
        {
            throw new PowerPolicyException("Could not parse the lid close action values.", exception);
        }
    }

    public async Task SetLidActionAsync(
        string schemeGuid,
        int acLidAction,
        int dcLidAction,
        CancellationToken cancellationToken = default)
    {
        var normalizedScheme = NormalizeGuid(schemeGuid);
        var original = await ReadLidActionAsync(normalizedScheme, cancellationToken).ConfigureAwait(false);

        try
        {
            await SetLidActionRawAsync(normalizedScheme, acLidAction, dcLidAction, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is PowerPolicyException)
        {
            try
            {
                await SetLidActionRawAsync(
                        normalizedScheme,
                        original.AcLidAction,
                        original.DcLidAction,
                        cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (PowerPolicyException)
            {
                // Preserve the original failure. The caller still keeps the backup state.
            }

            throw;
        }
    }

    public Task RestoreLidActionAsync(
        PowerPolicySnapshot snapshot,
        CancellationToken cancellationToken = default)
    {
        return SetLidActionRawAsync(
            snapshot.SchemeGuid,
            snapshot.AcLidAction,
            snapshot.DcLidAction,
            cancellationToken);
    }

    private async Task SetLidActionRawAsync(
        string schemeGuid,
        int acLidAction,
        int dcLidAction,
        CancellationToken cancellationToken)
    {
        var normalizedScheme = NormalizeGuid(schemeGuid);

        await RunPowerCfgAsync(
                $"/SETACVALUEINDEX {normalizedScheme} {SubButtonsGuid} {LidActionGuid} {acLidAction}",
                "set AC lid close action",
                cancellationToken)
            .ConfigureAwait(false);

        await RunPowerCfgAsync(
                $"/SETDCVALUEINDEX {normalizedScheme} {SubButtonsGuid} {LidActionGuid} {dcLidAction}",
                "set DC lid close action",
                cancellationToken)
            .ConfigureAwait(false);

        await RunPowerCfgAsync($"/SETACTIVE {normalizedScheme}", "activate updated power scheme", cancellationToken)
            .ConfigureAwait(false);
    }

    private async Task<CommandResult> RunPowerCfgAsync(
        string arguments,
        string operation,
        CancellationToken cancellationToken)
    {
        CommandResult result;
        try
        {
            result = await _runner.RunAsync("powercfg", arguments, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            throw new PowerPolicyException($"Failed to {operation}: {exception.Message}", exception);
        }

        if (result.ExitCode != 0)
        {
            var detail = string.Join(
                Environment.NewLine,
                new[] { result.StandardOutput.Trim(), result.StandardError.Trim() }.Where(static value => value.Length > 0));

            throw new PowerPolicyException($"Failed to {operation}. powercfg exited with {result.ExitCode}. {detail}");
        }

        return result;
    }

    private static string NormalizeGuid(string value)
    {
        return value.Trim().Trim('{', '}').ToLowerInvariant();
    }
}

