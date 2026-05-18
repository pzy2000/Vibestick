namespace Vibestick.Core;

public sealed class VibestickEngine
{
    private readonly IPowerPolicyManager _powerPolicy;
    private readonly IStateStore _stateStore;
    private readonly IBatteryMonitor _batteryMonitor;
    private readonly IProcessInspector _processInspector;
    private readonly VibestickOptions _options;
    private readonly BatterySafetyPolicy _batterySafety;

    public VibestickEngine(
        IPowerPolicyManager powerPolicy,
        IStateStore stateStore,
        IBatteryMonitor batteryMonitor,
        IProcessInspector processInspector,
        VibestickOptions? options = null)
    {
        _powerPolicy = powerPolicy;
        _stateStore = stateStore;
        _batteryMonitor = batteryMonitor;
        _processInspector = processInspector;
        _options = options ?? new VibestickOptions();
        _batterySafety = new BatterySafetyPolicy(_options);
    }

    public async Task<ModeChangeResult> ApplyModeAsync(
        VibestickMode requestedMode,
        CancellationToken cancellationToken = default)
    {
        if (requestedMode == VibestickMode.Off)
        {
            return await RevertAsync(cancellationToken).ConfigureAwait(false);
        }

        var warnings = new List<string>();
        var appliedMode = requestedMode;

        if (requestedMode == VibestickMode.Hyper)
        {
            var batteryDecision = _batterySafety.Evaluate(_batteryMonitor.GetBatteryInfo());
            switch (batteryDecision.Action)
            {
                case SafetyAction.RestoreNormalSleep:
                    var reverted = await RevertAsync(cancellationToken).ConfigureAwait(false);
                    warnings.Add(batteryDecision.Message);
                    warnings.AddRange(reverted.Warnings);
                    return new ModeChangeResult(
                        requestedMode,
                        VibestickMode.Off,
                        RestorePending: false,
                        warnings,
                        "HYPER was blocked by battery safety and normal sleep was restored.");

                case SafetyAction.DowngradeToOn:
                    warnings.Add(batteryDecision.Message);
                    appliedMode = VibestickMode.On;
                    break;

                case SafetyAction.Warn:
                    warnings.Add(batteryDecision.Message);
                    break;
            }
        }

        var stateLoad = await _stateStore.LoadAsync(cancellationToken).ConfigureAwait(false);
        if (stateLoad.Warning is not null)
        {
            warnings.Add(stateLoad.Warning);
        }

        var activeSchemeGuid = await _powerPolicy.GetActiveSchemeGuidAsync(cancellationToken).ConfigureAwait(false);
        var existingBackup = stateLoad.State.RestorePending && stateLoad.State.OriginalPolicy is not null;

        if (existingBackup &&
            !string.Equals(
                stateLoad.State.LastAppliedSchemeGuid,
                activeSchemeGuid,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new PowerPolicyException(
                "The active power scheme changed while a restore is pending. Run 'vibestick revert' before applying a new mode.");
        }

        var originalPolicy = existingBackup
            ? stateLoad.State.OriginalPolicy!
            : await _powerPolicy.ReadLidActionAsync(activeSchemeGuid, cancellationToken).ConfigureAwait(false);

        await _powerPolicy.SetLidActionAsync(
                activeSchemeGuid,
                PowerCfgPowerPolicyManager.LidActionDoNothing,
                PowerCfgPowerPolicyManager.LidActionDoNothing,
                cancellationToken)
            .ConfigureAwait(false);

        var nextState = new VibestickState
        {
            ActiveMode = appliedMode,
            LastAppliedSchemeGuid = activeSchemeGuid,
            OriginalPolicy = originalPolicy,
            RestorePending = true
        };

        await _stateStore.SaveAsync(nextState, cancellationToken).ConfigureAwait(false);

        return new ModeChangeResult(
            requestedMode,
            appliedMode,
            RestorePending: true,
            warnings,
            appliedMode == VibestickMode.Hyper
                ? "HYPER mode applied. Keep this process alive to block idle sleep."
                : "ON mode applied. Lid close action is set to Do Nothing.");
    }

    public async Task<ModeChangeResult> RevertAsync(CancellationToken cancellationToken = default)
    {
        var warnings = new List<string>();
        var stateLoad = await _stateStore.LoadAsync(cancellationToken).ConfigureAwait(false);
        if (stateLoad.Warning is not null)
        {
            warnings.Add(stateLoad.Warning);
        }

        if (stateLoad.State.RestorePending && stateLoad.State.OriginalPolicy is not null)
        {
            await _powerPolicy.RestoreLidActionAsync(stateLoad.State.OriginalPolicy, cancellationToken)
                .ConfigureAwait(false);
        }

        await _stateStore.SaveAsync(VibestickState.Empty(), cancellationToken).ConfigureAwait(false);

        return new ModeChangeResult(
            VibestickMode.Off,
            VibestickMode.Off,
            RestorePending: false,
            warnings,
            "Original lid close policy restored.");
    }

    public async Task<VibestickStatus> GetStatusAsync(CancellationToken cancellationToken = default)
    {
        var warnings = new List<string>();
        var stateLoad = await _stateStore.LoadAsync(cancellationToken).ConfigureAwait(false);
        if (stateLoad.Warning is not null)
        {
            warnings.Add(stateLoad.Warning);
        }

        string? currentSchemeGuid = null;
        PowerPolicySnapshot? currentPolicy = null;
        try
        {
            currentSchemeGuid = await _powerPolicy.GetActiveSchemeGuidAsync(cancellationToken).ConfigureAwait(false);
            currentPolicy = await _powerPolicy.ReadLidActionAsync(currentSchemeGuid, cancellationToken).ConfigureAwait(false);
        }
        catch (PowerPolicyException exception)
        {
            warnings.Add(exception.Message);
        }

        return new VibestickStatus(
            stateLoad.State.ActiveMode,
            stateLoad.State.RestorePending,
            stateLoad.State.LastAppliedSchemeGuid,
            stateLoad.State.OriginalPolicy,
            currentSchemeGuid,
            currentPolicy,
            _batteryMonitor.GetBatteryInfo(),
            _processInspector.GetLongTasks(_options.LongTaskProcessNames),
            warnings);
    }
}

