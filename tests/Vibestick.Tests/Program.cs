using Vibestick.Core;

namespace Vibestick.Tests;

internal static class Program
{
    public static async Task<int> Main()
    {
        var tests = new (string Name, Func<Task> Run)[]
        {
            ("PowerCfgParser parses Chinese lid action output", TestPowerCfgParserChineseAsync),
            ("PowerCfgParser parses English lid action output", TestPowerCfgParserEnglishAsync),
            ("ON creates backup and HYPER does not overwrite it", TestBackupIsNotOverwrittenAsync),
            ("Active scheme change blocks new mode while restore is pending", TestActiveSchemeChangeBlocksApplyAsync),
            ("HYPER downgrades to ON below battery downgrade threshold", TestHyperDowngradesOnLowBatteryAsync),
            ("HYPER restores normal sleep below critical battery threshold", TestHyperRestoresOnCriticalBatteryAsync),
            ("Long task detector matches normalized process names", TestLongTaskDetectorAsync),
            ("Json state store recovers from corrupted state", TestCorruptedStateRecoveryAsync)
        };

        var failed = 0;
        foreach (var test in tests)
        {
            try
            {
                await test.Run().ConfigureAwait(false);
                Console.WriteLine($"PASS {test.Name}");
            }
            catch (Exception exception)
            {
                failed++;
                Console.WriteLine($"FAIL {test.Name}");
                Console.WriteLine(exception);
            }
        }

        Console.WriteLine();
        Console.WriteLine(failed == 0 ? $"All {tests.Length} tests passed." : $"{failed} test(s) failed.");
        return failed == 0 ? 0 : 1;
    }

    private static Task TestPowerCfgParserChineseAsync()
    {
        const string output = """
            电源方案 GUID: 27fa6203-3987-4dcc-918d-748559d549ec  (Performance)
              子组 GUID: 4f971e89-eebd-4455-a8de-9e59040e7347  (电源按钮和盖子)
                电源设置 GUID: 5ca83367-6e45-459f-a27b-476b1d01c936  (合上盖子操作)
                当前交流电源设置索引: 0x00000001
                当前直流电源设置索引: 0x00000002
            """;

        var snapshot = PowerCfgParser.ParseLidActionSnapshot("27fa6203-3987-4dcc-918d-748559d549ec", output);
        AssertEqual(1, snapshot.AcLidAction);
        AssertEqual(2, snapshot.DcLidAction);
        return Task.CompletedTask;
    }

    private static Task TestPowerCfgParserEnglishAsync()
    {
        const string output = """
            Power Scheme GUID: 27fa6203-3987-4dcc-918d-748559d549ec  (Performance)
              Subgroup GUID: 4f971e89-eebd-4455-a8de-9e59040e7347  (Power buttons and lid)
                Power Setting GUID: 5ca83367-6e45-459f-a27b-476b1d01c936  (Lid close action)
                Current AC Power Setting Index: 0x00000000
                Current DC Power Setting Index: 0x00000001
            """;

        var scheme = PowerCfgParser.ParseFirstGuid(output);
        var snapshot = PowerCfgParser.ParseLidActionSnapshot(scheme, output);
        AssertEqual("27fa6203-3987-4dcc-918d-748559d549ec", scheme);
        AssertEqual(0, snapshot.AcLidAction);
        AssertEqual(1, snapshot.DcLidAction);
        return Task.CompletedTask;
    }

    private static async Task TestBackupIsNotOverwrittenAsync()
    {
        var policy = new FakePowerPolicyManager("scheme-a", new PowerPolicySnapshot("scheme-a", 1, 1));
        var store = new MemoryStateStore();
        var engine = CreateEngine(policy, store, new BatteryInfo(90, IsAcConnected: true, IsAvailable: true));

        await engine.ApplyModeAsync(VibestickMode.On).ConfigureAwait(false);
        AssertEqual(0, policy.CurrentSnapshot.AcLidAction);
        AssertEqual(0, policy.CurrentSnapshot.DcLidAction);

        await engine.ApplyModeAsync(VibestickMode.Hyper).ConfigureAwait(false);
        AssertNotNull(store.State.OriginalPolicy);
        AssertEqual(1, store.State.OriginalPolicy!.AcLidAction);
        AssertEqual(1, store.State.OriginalPolicy.DcLidAction);

        await engine.RevertAsync().ConfigureAwait(false);
        AssertEqual(1, policy.CurrentSnapshot.AcLidAction);
        AssertEqual(1, policy.CurrentSnapshot.DcLidAction);
        AssertFalse(store.State.RestorePending);
    }

    private static async Task TestActiveSchemeChangeBlocksApplyAsync()
    {
        var policy = new FakePowerPolicyManager("scheme-a", new PowerPolicySnapshot("scheme-a", 1, 1));
        policy.AddScheme("scheme-b", new PowerPolicySnapshot("scheme-b", 1, 1));
        var store = new MemoryStateStore();
        var engine = CreateEngine(policy, store, new BatteryInfo(90, IsAcConnected: true, IsAvailable: true));

        await engine.ApplyModeAsync(VibestickMode.On).ConfigureAwait(false);
        policy.ActiveSchemeGuid = "scheme-b";

        await AssertThrowsAsync<PowerPolicyException>(() => engine.ApplyModeAsync(VibestickMode.On)).ConfigureAwait(false);
    }

    private static async Task TestHyperDowngradesOnLowBatteryAsync()
    {
        var policy = new FakePowerPolicyManager("scheme-a", new PowerPolicySnapshot("scheme-a", 1, 1));
        var store = new MemoryStateStore();
        var engine = CreateEngine(policy, store, new BatteryInfo(15, IsAcConnected: false, IsAvailable: true));

        var result = await engine.ApplyModeAsync(VibestickMode.Hyper).ConfigureAwait(false);

        AssertEqual(VibestickMode.Hyper, result.RequestedMode);
        AssertEqual(VibestickMode.On, result.AppliedMode);
        AssertEqual(VibestickMode.On, store.State.ActiveMode);
        AssertTrue(result.Warnings.Any(warning => warning.Contains("downgrading", StringComparison.OrdinalIgnoreCase)));
    }

    private static async Task TestHyperRestoresOnCriticalBatteryAsync()
    {
        var policy = new FakePowerPolicyManager("scheme-a", new PowerPolicySnapshot("scheme-a", 0, 0));
        var store = new MemoryStateStore(new VibestickState
        {
            ActiveMode = VibestickMode.Hyper,
            LastAppliedSchemeGuid = "scheme-a",
            OriginalPolicy = new PowerPolicySnapshot("scheme-a", 1, 1),
            RestorePending = true
        });
        var engine = CreateEngine(policy, store, new BatteryInfo(9, IsAcConnected: false, IsAvailable: true));

        var result = await engine.ApplyModeAsync(VibestickMode.Hyper).ConfigureAwait(false);

        AssertEqual(VibestickMode.Off, result.AppliedMode);
        AssertEqual(1, policy.CurrentSnapshot.AcLidAction);
        AssertEqual(1, policy.CurrentSnapshot.DcLidAction);
        AssertFalse(store.State.RestorePending);
    }

    private static Task TestLongTaskDetectorAsync()
    {
        var options = new VibestickOptions();
        var matches = LongTaskDetector.FindMatches(
            new[] { "node.exe", "explorer", "PYTHON", "docker.exe", "notepad" },
            options.LongTaskProcessNames);

        AssertSequence(new[] { "docker", "node", "python" }, matches);
        return Task.CompletedTask;
    }

    private static async Task TestCorruptedStateRecoveryAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"vibestick-tests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var statePath = Path.Combine(directory, "state.json");
        await File.WriteAllTextAsync(statePath, "{ this is not json").ConfigureAwait(false);

        var store = new JsonFileStateStore(statePath);
        var load = await store.LoadAsync().ConfigureAwait(false);

        AssertTrue(load.WasCorrupted);
        AssertEqual(VibestickMode.Off, load.State.ActiveMode);
        AssertNotNull(load.Warning);

        Directory.Delete(directory, recursive: true);
    }

    private static VibestickEngine CreateEngine(
        IPowerPolicyManager policy,
        IStateStore store,
        BatteryInfo battery)
    {
        return new VibestickEngine(
            policy,
            store,
            new StaticBatteryMonitor(battery),
            new StaticProcessInspector(Array.Empty<LongTaskProcess>()));
    }

    private static async Task AssertThrowsAsync<TException>(Func<Task> action)
        where TException : Exception
    {
        try
        {
            await action().ConfigureAwait(false);
        }
        catch (TException)
        {
            return;
        }

        throw new InvalidOperationException($"Expected exception {typeof(TException).Name}.");
    }

    private static void AssertEqual<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"Expected '{expected}', got '{actual}'.");
        }
    }

    private static void AssertSequence<T>(IReadOnlyList<T> expected, IReadOnlyList<T> actual)
    {
        AssertEqual(expected.Count, actual.Count);
        for (var index = 0; index < expected.Count; index++)
        {
            AssertEqual(expected[index], actual[index]);
        }
    }

    private static void AssertTrue(bool value)
    {
        if (!value)
        {
            throw new InvalidOperationException("Expected true.");
        }
    }

    private static void AssertFalse(bool value)
    {
        if (value)
        {
            throw new InvalidOperationException("Expected false.");
        }
    }

    private static void AssertNotNull(object? value)
    {
        if (value is null)
        {
            throw new InvalidOperationException("Expected non-null value.");
        }
    }

    private sealed class FakePowerPolicyManager : IPowerPolicyManager
    {
        private readonly Dictionary<string, PowerPolicySnapshot> _snapshots = new(StringComparer.OrdinalIgnoreCase);

        public FakePowerPolicyManager(string activeSchemeGuid, PowerPolicySnapshot snapshot)
        {
            ActiveSchemeGuid = activeSchemeGuid;
            AddScheme(activeSchemeGuid, snapshot);
        }

        public string ActiveSchemeGuid { get; set; }

        public PowerPolicySnapshot CurrentSnapshot => _snapshots[ActiveSchemeGuid];

        public void AddScheme(string schemeGuid, PowerPolicySnapshot snapshot)
        {
            _snapshots[schemeGuid] = snapshot;
        }

        public Task<string> GetActiveSchemeGuidAsync(CancellationToken cancellationToken = default)
        {
            return Task.FromResult(ActiveSchemeGuid);
        }

        public Task<PowerPolicySnapshot> ReadLidActionAsync(
            string schemeGuid,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(_snapshots[schemeGuid]);
        }

        public Task SetLidActionAsync(
            string schemeGuid,
            int acLidAction,
            int dcLidAction,
            CancellationToken cancellationToken = default)
        {
            _snapshots[schemeGuid] = new PowerPolicySnapshot(schemeGuid, acLidAction, dcLidAction);
            return Task.CompletedTask;
        }

        public Task RestoreLidActionAsync(
            PowerPolicySnapshot snapshot,
            CancellationToken cancellationToken = default)
        {
            _snapshots[snapshot.SchemeGuid] = snapshot;
            return Task.CompletedTask;
        }
    }

    private sealed class MemoryStateStore : IStateStore
    {
        public MemoryStateStore()
            : this(VibestickState.Empty())
        {
        }

        public MemoryStateStore(VibestickState state)
        {
            State = Clone(state);
        }

        public string StatePath => "memory";

        public VibestickState State { get; private set; }

        public Task<StateLoadResult> LoadAsync(CancellationToken cancellationToken = default)
        {
            return Task.FromResult(new StateLoadResult(Clone(State), WasCorrupted: false, Warning: null));
        }

        public Task SaveAsync(VibestickState state, CancellationToken cancellationToken = default)
        {
            State = Clone(state);
            return Task.CompletedTask;
        }

        private static VibestickState Clone(VibestickState state)
        {
            return new VibestickState
            {
                ActiveMode = state.ActiveMode,
                LastAppliedSchemeGuid = state.LastAppliedSchemeGuid,
                OriginalPolicy = state.OriginalPolicy is null
                    ? null
                    : new PowerPolicySnapshot(
                        state.OriginalPolicy.SchemeGuid,
                        state.OriginalPolicy.AcLidAction,
                        state.OriginalPolicy.DcLidAction),
                RestorePending = state.RestorePending,
                UpdatedAtUtc = state.UpdatedAtUtc
            };
        }
    }

    private sealed class StaticBatteryMonitor : IBatteryMonitor
    {
        private readonly BatteryInfo _battery;

        public StaticBatteryMonitor(BatteryInfo battery)
        {
            _battery = battery;
        }

        public BatteryInfo GetBatteryInfo() => _battery;
    }

    private sealed class StaticProcessInspector : IProcessInspector
    {
        private readonly IReadOnlyList<LongTaskProcess> _tasks;

        public StaticProcessInspector(IReadOnlyList<LongTaskProcess> tasks)
        {
            _tasks = tasks;
        }

        public IReadOnlyList<LongTaskProcess> GetLongTasks(IReadOnlyList<string> whitelist) => _tasks;
    }
}

