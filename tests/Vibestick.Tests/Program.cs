using System.Diagnostics;
using System.Text.Json.Nodes;
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
            ("Json state store recovers from corrupted state", TestCorruptedStateRecoveryAsync),
            ("Coder status adapter parses tool_calling and ignores stale entries", TestCoderStatusAdapterAsync),
            ("Codex session event mapper emits safe pet statuses", TestCodexSessionEventMapperAsync),
            ("Codex task summary extraction ignores environment context", TestCodexTaskSummaryExtractionAsync),
            ("Codex session bridge tails newest rollout", TestCodexSessionStatusBridgeAsync),
            ("Codex session bridge tracks multiple active rollouts", TestCodexSessionBridgeMultiSessionAsync),
            ("Pet resolver prioritizes urgent coder phases", TestPetResolverPhasePriorityAsync),
            ("Pet resolver maps tool calling mood", TestPetResolverToolCallingAsync),
            ("Pet resolver displays elapsed active coder time", TestPetResolverActiveElapsedTimeAsync),
            ("Pet resolver maps sleeping mood", TestPetResolverSleepingAsync),
            ("Pet resolver prioritizes tool calling over reasoning and running", TestPetResolverToolCallingPriorityAsync),
            ("Pet resolver falls back to idle without coders", TestPetResolverIdleFallbackAsync),
            ("Pet resolver lets critical power override coder mood", TestPetResolverPowerOverrideAsync),
            ("Pet resolver rotates charging power and full-time badge", TestPetResolverChargingBadgeRotationAsync),
            ("Pet resolver falls back to AC badge when charging estimate is missing", TestPetResolverChargingBadgeFallbackAsync),
            ("Composite coder source prefers adapter status over process fallback", TestCompositeCoderSourceAsync),
            ("Composite coder source preserves same-agent sessions", TestCompositeCoderSourcePreservesSessionsAsync),
            ("Process coder source treats idle Codex as sleeping", TestProcessCoderSourceCodexSleepingAsync),
            ("CLI coder emit, pet status, and clear smoke", TestCliCoderStatusSmokeAsync),
            ("GUI pet smoke exits cleanly", TestGuiPetSmokeAsync),
            ("GUI Codex monitor starts by default and can be disabled", TestGuiCodexMonitorDefaultAndOptOutAsync),
            ("Desktop pet e2e reflects state and bottom-right placement", TestDesktopPetE2EAsync),
            ("Desktop pet e2e renders collapsed multi-session cards", TestDesktopPetMultiSessionE2EAsync)
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

    private static Task TestCoderStatusAdapterAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"vibestick-coder-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var now = DateTimeOffset.Parse("2026-05-18T10:00:00Z");

        File.WriteAllText(
            Path.Combine(directory, "codex.json"),
            """
            {
              "agent": "codex",
              "phase": "tool_calling",
              "message": "Running rg",
              "workspace": "C:\\repo",
              "processId": 123,
              "updatedAtUtc": "2026-05-18T09:59:30Z",
              "ttlSeconds": 120
            }
            """);

        File.WriteAllText(
            Path.Combine(directory, "old.json"),
            """
            {
              "agent": "old",
              "phase": "error",
              "updatedAtUtc": "2026-05-18T09:00:00Z",
              "ttlSeconds": 10
            }
            """);

        var statuses = new JsonFileCoderStatusSource(directory).GetStatuses(now);
        AssertEqual(1, statuses.Count);
        AssertEqual("codex", statuses[0].Agent);
        AssertEqual(CoderAgentPhase.ToolCalling, statuses[0].Phase);
        AssertEqual("Running rg", statuses[0].Message);

        Directory.Delete(directory, recursive: true);
        return Task.CompletedTask;
    }

    private static Task TestCodexSessionEventMapperAsync()
    {
        AssertTrue(CodexSessionEventMapper.TryMapJsonLine(
            """{"type":"event_msg","payload":{"type":"task_started"}}""",
            out var taskStarted));
        AssertEqual(CoderAgentPhase.Reasoning, taskStarted.Phase);
        AssertEqual("Codex is thinking", taskStarted.Message);

        AssertTrue(CodexSessionEventMapper.TryMapJsonLine(
            """{"type":"response_item","payload":{"type":"function_call","name":"shell_command","arguments":"Get-Content secret.txt"}}""",
            out var toolCall));
        AssertEqual(CoderAgentPhase.ToolCalling, toolCall.Phase);
        AssertEqual("Using shell_command", toolCall.Message);
        AssertFalse(toolCall.Message.Contains("secret", StringComparison.OrdinalIgnoreCase));

        AssertTrue(CodexSessionEventMapper.TryMapJsonLine(
            """{"type":"response_item","payload":{"type":"function_call_output","output":"secret output"}}""",
            out var toolOutput));
        AssertEqual(CoderAgentPhase.Reasoning, toolOutput.Phase);
        AssertEqual("Reviewing tool result", toolOutput.Message);
        AssertFalse(toolOutput.Message.Contains("secret", StringComparison.OrdinalIgnoreCase));

        AssertTrue(CodexSessionEventMapper.TryMapJsonLine(
            """{"type":"event_msg","payload":{"type":"task_complete"}}""",
            out var taskComplete));
        AssertEqual(CoderAgentPhase.Success, taskComplete.Phase);
        AssertEqual(10, taskComplete.TtlSeconds);

        AssertFalse(CodexSessionEventMapper.TryMapJsonLine("{ this is not json", out _));
        return Task.CompletedTask;
    }

    private static Task TestCodexTaskSummaryExtractionAsync()
    {
        AssertTrue(CodexSessionEventMapper.TryReadTaskSummary(
            """
            {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>C:\\repo</cwd>\n</environment_context>\nImplement multi session cards\nwith summaries"}]}}
            """,
            out var summary));
        AssertEqual("Implement multi session cards with summaries", summary);

        AssertTrue(CodexSessionEventMapper.TryReadTaskSummary(
            """
            {"type":"event_msg","payload":{"type":"user_message","message":"<image>base64-noise</image>\nFix task cards"}}
            """,
            out var eventSummary));
        AssertEqual("Fix task cards", eventSummary);

        AssertFalse(CodexSessionEventMapper.TryReadTaskSummary(
            """
            {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>only env</environment_context>"}]}}
            """,
            out _));
        return Task.CompletedTask;
    }

    private static async Task TestCodexSessionStatusBridgeAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"vibestick-codex-bridge-{Guid.NewGuid():N}");
        var statusDirectory = Path.Combine(directory, "status");
        var sessionsRoot = Path.Combine(directory, "sessions");
        var sessionDay = Path.Combine(sessionsRoot, "2026", "05", "18");
        Directory.CreateDirectory(sessionDay);

        var oldSession = Path.Combine(sessionDay, "rollout-2026-05-18T09-00-00-old.jsonl");
        await File.WriteAllTextAsync(oldSession, string.Empty).ConfigureAwait(false);
        File.SetLastWriteTimeUtc(oldSession, DateTime.UtcNow.AddMinutes(-5));

        using var bridge = new CodexSessionStatusBridge(statusDirectory, sessionsRoot);
        bridge.Start();
        AssertEqual(oldSession, bridge.ActiveSessionPath);

        var newSession = Path.Combine(sessionDay, "rollout-2026-05-18T10-00-00-new.jsonl");
        await File.WriteAllTextAsync(
                newSession,
                """{"type":"response_item","payload":{"type":"function_call","name":"shell_command","arguments":"Get-Content secret.txt"}}""" + Environment.NewLine)
            .ConfigureAwait(false);

        var toolStatus = await WaitForCoderStatusAsync(statusDirectory, CoderAgentPhase.ToolCalling, TimeSpan.FromSeconds(5))
            .ConfigureAwait(false);
        AssertEqual("Using shell_command", toolStatus.Message);
        AssertFalse(toolStatus.Message?.Contains("secret", StringComparison.OrdinalIgnoreCase) ?? false);
        AssertEqual(newSession, bridge.ActiveSessionPath);

        await File.AppendAllTextAsync(
                newSession,
                "{ this is not json" + Environment.NewLine +
                """{"type":"response_item","payload":{"type":"function_call_output","output":"secret output"}}""" + Environment.NewLine)
            .ConfigureAwait(false);

        var reasoningStatus = await WaitForCoderStatusAsync(statusDirectory, CoderAgentPhase.Reasoning, TimeSpan.FromSeconds(5))
            .ConfigureAwait(false);
        AssertEqual("Reviewing tool result", reasoningStatus.Message);
        AssertFalse(reasoningStatus.Message?.Contains("secret", StringComparison.OrdinalIgnoreCase) ?? false);

        bridge.Dispose();
        Directory.Delete(directory, recursive: true);
    }

    private static async Task TestCodexSessionBridgeMultiSessionAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"vibestick-codex-multi-{Guid.NewGuid():N}");
        var statusDirectory = Path.Combine(directory, "status");
        var sessionsRoot = Path.Combine(directory, "sessions");
        var sessionDay = Path.Combine(sessionsRoot, "2026", "05", "18");
        Directory.CreateDirectory(sessionDay);

        try
        {
            using var bridge = new CodexSessionStatusBridge(statusDirectory, sessionsRoot);
            bridge.Start();

            var firstSession = Path.Combine(sessionDay, "rollout-2026-05-18T10-00-00-first.jsonl");
            await File.WriteAllTextAsync(
                    firstSession,
                    """
                    {"type":"session_meta","payload":{"id":"session-a","cwd":"C:\\repo-a"}}
                    {"type":"event_msg","payload":{"type":"user_message","message":"Implement first task"}}
                    {"type":"response_item","payload":{"type":"function_call","name":"shell_command"}}
                    """ + Environment.NewLine)
                .ConfigureAwait(false);

            var secondSession = Path.Combine(sessionDay, "rollout-2026-05-18T10-00-01-second.jsonl");
            await File.WriteAllTextAsync(
                    secondSession,
                    """
                    {"type":"session_meta","payload":{"id":"session-b","cwd":"C:\\repo-b"}}
                    {"type":"event_msg","payload":{"type":"user_message","message":"Implement second task"}}
                    {"type":"response_item","payload":{"type":"reasoning"}}
                    """ + Environment.NewLine)
                .ConfigureAwait(false);

            var statuses = await WaitForCoderStatusCountAsync(statusDirectory, 2, TimeSpan.FromSeconds(5))
                .ConfigureAwait(false);
            AssertSequence(new[] { "session-a", "session-b" }, statuses.Select(static status => status.SessionId!).Order().ToArray());
            AssertTrue(statuses.Any(static status => status.TaskSummary == "Implement first task"));
            AssertTrue(statuses.Any(static status => status.TaskSummary == "Implement second task"));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static Task TestPetResolverPhasePriorityAsync()
    {
        var resolver = new PetStateResolver();
        var state = resolver.Resolve(
            CreateStatus(),
            new[]
            {
                CreateCoder("codex", CoderAgentPhase.Running),
                CreateCoder("claude", CoderAgentPhase.Error, "Build failed")
            },
            isHyperGuardRunning: false,
            DateTimeOffset.UtcNow);

        AssertEqual(PetMood.Error, state.Mood);
        AssertEqual("claude", state.PrimaryCoder?.Agent);
        AssertEqual("Build failed", state.Message);
        return Task.CompletedTask;
    }

    private static Task TestPetResolverToolCallingAsync()
    {
        var state = new PetStateResolver().Resolve(
            CreateStatus(),
            new[] { CreateCoder("codex", CoderAgentPhase.ToolCalling) },
            isHyperGuardRunning: false,
            DateTimeOffset.UtcNow);

        AssertEqual(PetMood.ToolCalling, state.Mood);
        AssertEqual("Codex is using a tool", state.Title);
        AssertTrue(state.Message.StartsWith("The coder is using a tool for ", StringComparison.Ordinal));
        return Task.CompletedTask;
    }

    private static Task TestPetResolverActiveElapsedTimeAsync()
    {
        var now = DateTimeOffset.Parse("2026-05-18T10:00:42Z");
        var reasoningState = new PetStateResolver().Resolve(
            CreateStatus(),
            new[] { CreateCoder("codex", CoderAgentPhase.Reasoning, "Reading files", updatedAtUtc: now.AddSeconds(-12)) },
            isHyperGuardRunning: false,
            now);
        var toolState = new PetStateResolver().Resolve(
            CreateStatus(),
            new[] { CreateCoder("codex", CoderAgentPhase.ToolCalling, "Running rg", updatedAtUtc: now.AddSeconds(-75)) },
            isHyperGuardRunning: false,
            now);

        AssertEqual("Reading files for 12s", reasoningState.Message);
        AssertEqual("Running rg for 1m15s", toolState.Message);
        return Task.CompletedTask;
    }

    private static Task TestPetResolverSleepingAsync()
    {
        var state = new PetStateResolver().Resolve(
            CreateStatus(),
            new[] { CreateCoder("codex", CoderAgentPhase.Sleeping, "No active Codex task is running.") },
            isHyperGuardRunning: false,
            DateTimeOffset.UtcNow);

        AssertEqual(PetMood.Sleeping, state.Mood);
        AssertEqual("Codex is sleeping", state.Title);
        AssertEqual("No active Codex task is running.", state.Message);
        return Task.CompletedTask;
    }

    private static Task TestPetResolverToolCallingPriorityAsync()
    {
        var now = DateTimeOffset.UtcNow;
        var state = new PetStateResolver().Resolve(
            CreateStatus(),
            new[]
            {
                CreateCoder("codex", CoderAgentPhase.Running, updatedAtUtc: now.AddSeconds(2)),
                CreateCoder("codex", CoderAgentPhase.Reasoning, updatedAtUtc: now.AddSeconds(1)),
                CreateCoder("codex", CoderAgentPhase.ToolCalling, "Running rg", updatedAtUtc: now)
            },
            isHyperGuardRunning: false,
            now);

        AssertEqual(PetMood.ToolCalling, state.Mood);
        AssertEqual(CoderAgentPhase.ToolCalling, state.PrimaryCoder?.Phase);
        AssertEqual("Running rg for 0s", state.Message);
        return Task.CompletedTask;
    }

    private static Task TestPetResolverIdleFallbackAsync()
    {
        var state = new PetStateResolver().Resolve(
            CreateStatus(),
            Array.Empty<CoderAgentStatus>(),
            isHyperGuardRunning: false,
            DateTimeOffset.UtcNow);

        AssertEqual(PetMood.Idle, state.Mood);
        AssertEqual(0, state.Coders.Count);
        return Task.CompletedTask;
    }

    private static Task TestPetResolverPowerOverrideAsync()
    {
        var status = CreateStatus(
            mode: VibestickMode.Hyper,
            battery: new BatteryInfo(15, IsAcConnected: false, IsAvailable: true));
        var state = new PetStateResolver().Resolve(
            status,
            new[] { CreateCoder("codex", CoderAgentPhase.Reasoning) },
            isHyperGuardRunning: true,
            DateTimeOffset.UtcNow);

        AssertEqual(PetMood.PowerWarning, state.Mood);
        AssertTrue(state.Badges.Any(static badge => badge.Kind == PetBadgeKind.Guard));
        return Task.CompletedTask;
    }

    private static Task TestPetResolverChargingBadgeRotationAsync()
    {
        var battery = new BatteryInfo(
            80,
            IsAcConnected: true,
            IsAvailable: true,
            ChargeRateInMilliwatts: 24000,
            RemainingCapacityInMilliwattHours: 32000,
            FullChargeCapacityInMilliwattHours: 46000,
            EstimatedTimeToFull: TimeSpan.FromMinutes(35));

        var resolver = new PetStateResolver();
        var powerState = resolver.Resolve(
            CreateStatus(battery: battery),
            Array.Empty<CoderAgentStatus>(),
            isHyperGuardRunning: false,
            DateTimeOffset.FromUnixTimeSeconds(0));
        var etaState = resolver.Resolve(
            CreateStatus(battery: battery),
            Array.Empty<CoderAgentStatus>(),
            isHyperGuardRunning: false,
            DateTimeOffset.FromUnixTimeSeconds(4));

        AssertEqual("80% +24W", GetBatteryBadgeText(powerState));
        AssertEqual("80% ≈35m", GetBatteryBadgeText(etaState));
        return Task.CompletedTask;
    }

    private static Task TestPetResolverChargingBadgeFallbackAsync()
    {
        var missingEstimate = new BatteryInfo(
            80,
            IsAcConnected: true,
            IsAvailable: true,
            ChargeRateInMilliwatts: 24000);
        var onBattery = new BatteryInfo(
            80,
            IsAcConnected: false,
            IsAvailable: true,
            ChargeRateInMilliwatts: 24000,
            EstimatedTimeToFull: TimeSpan.FromMinutes(35));

        var resolver = new PetStateResolver();
        var missingEstimateState = resolver.Resolve(
            CreateStatus(battery: missingEstimate),
            Array.Empty<CoderAgentStatus>(),
            isHyperGuardRunning: false,
            DateTimeOffset.FromUnixTimeSeconds(0));
        var onBatteryState = resolver.Resolve(
            CreateStatus(battery: onBattery),
            Array.Empty<CoderAgentStatus>(),
            isHyperGuardRunning: false,
            DateTimeOffset.FromUnixTimeSeconds(0));

        AssertEqual("80% AC", GetBatteryBadgeText(missingEstimateState));
        AssertEqual("80%", GetBatteryBadgeText(onBatteryState));
        return Task.CompletedTask;
    }

    private static Task TestCompositeCoderSourceAsync()
    {
        var now = DateTimeOffset.UtcNow;
        var composite = new CompositeCoderStatusSource(
            new StaticCoderStatusSource(new[] { CreateCoder("codex", CoderAgentPhase.Idle, updatedAtUtc: now) }),
            new StaticCoderStatusSource(new[] { CreateCoder("codex", CoderAgentPhase.Running, updatedAtUtc: now.AddSeconds(1)) }));

        var statuses = composite.GetStatuses(now);
        AssertEqual(1, statuses.Count);
        AssertEqual(CoderAgentPhase.Idle, statuses[0].Phase);
        return Task.CompletedTask;
    }

    private static Task TestCompositeCoderSourcePreservesSessionsAsync()
    {
        var now = DateTimeOffset.UtcNow;
        var composite = new CompositeCoderStatusSource(
            new StaticCoderStatusSource(new[]
            {
                CreateCoder("codex", CoderAgentPhase.Reasoning, "first", updatedAtUtc: now, sessionId: "session-a", summary: "First task"),
                CreateCoder("codex", CoderAgentPhase.ToolCalling, "second", updatedAtUtc: now.AddSeconds(1), sessionId: "session-b", summary: "Second task"),
                CreateCoder("codex", CoderAgentPhase.Running, "fallback", updatedAtUtc: now.AddSeconds(2), sessionId: "session-a", summary: "Older duplicate")
            }));

        var statuses = composite.GetStatuses(now);
        AssertEqual(2, statuses.Count);
        AssertSequence(new[] { "session-b", "session-a" }, statuses.Select(static status => status.SessionId!).ToArray());
        AssertEqual(CoderAgentPhase.ToolCalling, statuses[0].Phase);
        AssertEqual(CoderAgentPhase.Reasoning, statuses[1].Phase);
        return Task.CompletedTask;
    }

    private static Task TestProcessCoderSourceCodexSleepingAsync()
    {
        var now = DateTimeOffset.Parse("2026-05-18T10:00:00Z");
        var source = new ProcessCoderStatusSource(
            new StaticProcessInspector(new[]
            {
                new LongTaskProcess(123, "codex"),
                new LongTaskProcess(456, "node")
            }),
            new[] { "codex", "node" });

        var statuses = source.GetStatuses(now);
        var codex = statuses.First(static status => status.Agent == "codex");
        var node = statuses.First(static status => status.Agent == "node");

        AssertEqual(CoderAgentPhase.Sleeping, codex.Phase);
        AssertEqual("No active Codex task is running.", codex.Message);
        AssertEqual(CoderAgentPhase.Running, node.Phase);
        return Task.CompletedTask;
    }

    private static async Task TestCliCoderStatusSmokeAsync()
    {
        var repoRoot = FindRepoRoot();
        var directory = Path.Combine(Path.GetTempPath(), $"vibestick-cli-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);

        var emit = await RunDotnetAsync(
            repoRoot,
            $"run --project src\\Vibestick.Cli --configuration Release -- coder emit --agent codex --phase reasoning --message \"thinking\" --ttl 60 --status-dir \"{directory}\" --json")
            .ConfigureAwait(false);
        AssertEqual(0, emit.ExitCode);

        var status = await RunDotnetAsync(
            repoRoot,
            $"run --project src\\Vibestick.Cli --configuration Release -- pet status --status-dir \"{directory}\" --json")
            .ConfigureAwait(false);
        AssertEqual(0, status.ExitCode);
        var json = JsonNode.Parse(status.StandardOutput) ?? throw new InvalidOperationException("Expected pet status JSON.");
        AssertEqual("reasoning", json["pet"]?["mood"]?.GetValue<string>());
        AssertNotNull(json["battery"]);

        var toolAlias = await RunDotnetAsync(
            repoRoot,
            $"run --project src\\Vibestick.Cli --configuration Release -- coder emit --agent codex --phase tool-calling --message \"tool\" --ttl 60 --status-dir \"{directory}\" --json")
            .ConfigureAwait(false);
        AssertEqual(0, toolAlias.ExitCode);
        var toolAliasJson = JsonNode.Parse(toolAlias.StandardOutput) ?? throw new InvalidOperationException("Expected tool alias JSON.");
        AssertEqual("tool_calling", toolAliasJson["status"]?["phase"]?.GetValue<string>());

        var toolStatus = await RunDotnetAsync(
            repoRoot,
            $"run --project src\\Vibestick.Cli --configuration Release -- pet status --status-dir \"{directory}\" --json")
            .ConfigureAwait(false);
        AssertEqual(0, toolStatus.ExitCode);
        var toolJson = JsonNode.Parse(toolStatus.StandardOutput) ?? throw new InvalidOperationException("Expected tool pet status JSON.");
        AssertEqual("tool_calling", toolJson["pet"]?["mood"]?.GetValue<string>());

        var compactToolAlias = await RunDotnetAsync(
            repoRoot,
            $"run --project src\\Vibestick.Cli --configuration Release -- coder emit --agent codex --phase toolcalling --message \"tool compact\" --ttl 60 --status-dir \"{directory}\" --json")
            .ConfigureAwait(false);
        AssertEqual(0, compactToolAlias.ExitCode);
        var compactToolJson = JsonNode.Parse(compactToolAlias.StandardOutput) ?? throw new InvalidOperationException("Expected compact tool alias JSON.");
        AssertEqual("tool_calling", compactToolJson["status"]?["phase"]?.GetValue<string>());

        var sessionEmit = await RunDotnetAsync(
            repoRoot,
            $"run --project src\\Vibestick.Cli --configuration Release -- coder emit --agent codex --phase reasoning --message \"session\" --session-id cli-session --summary \"CLI session task\" --ttl 60 --status-dir \"{directory}\" --json")
            .ConfigureAwait(false);
        AssertEqual(0, sessionEmit.ExitCode);
        var sessionJson = JsonNode.Parse(sessionEmit.StandardOutput) ?? throw new InvalidOperationException("Expected session emit JSON.");
        AssertEqual("cli-session", sessionJson["status"]?["sessionId"]?.GetValue<string>());
        AssertEqual("CLI session task", sessionJson["status"]?["taskSummary"]?.GetValue<string>());

        var clear = await RunDotnetAsync(
            repoRoot,
            $"run --project src\\Vibestick.Cli --configuration Release -- coder clear --agent codex --status-dir \"{directory}\" --json")
            .ConfigureAwait(false);
        AssertEqual(0, clear.ExitCode);
        var clearJson = JsonNode.Parse(clear.StandardOutput) ?? throw new InvalidOperationException("Expected clear JSON.");
        AssertEqual(2, clearJson["deleted"]?.GetValue<int>());

        Directory.Delete(directory, recursive: true);
    }

    private static async Task TestGuiPetSmokeAsync()
    {
        var repoRoot = FindRepoRoot();
        var directory = Path.Combine(Path.GetTempPath(), $"vibestick-gui-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var publishDirectory = Path.Combine(directory, "publish");

        try
        {
            var guiDll = await PublishGuiForSmokeAsync(repoRoot, publishDirectory).ConfigureAwait(false);
            var result = await RunProcessAsync(
                    GetDotnetPath(),
                    $"\"{guiDll}\" --smoke --no-codex-monitor --status-dir \"{directory}\" --placement-path \"{Path.Combine(directory, "placement.json")}\"",
                    repoRoot,
                    TimeSpan.FromSeconds(20))
                .ConfigureAwait(false);
            AssertEqual(0, result.ExitCode);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static async Task TestGuiCodexMonitorDefaultAndOptOutAsync()
    {
        var repoRoot = FindRepoRoot();
        var directory = Path.Combine(Path.GetTempPath(), $"vibestick-gui-codex-{Guid.NewGuid():N}");
        var publishDirectory = Path.Combine(directory, "publish");
        var enabledStatusDirectory = Path.Combine(directory, "enabled-status");
        var disabledStatusDirectory = Path.Combine(directory, "disabled-status");
        var sessionsRoot = Path.Combine(directory, "sessions");
        var sessionDay = Path.Combine(sessionsRoot, "2026", "05", "18");
        Directory.CreateDirectory(sessionDay);

        try
        {
            var guiDll = await PublishGuiForSmokeAsync(repoRoot, publishDirectory).ConfigureAwait(false);

            using (var enabled = Process.Start(new ProcessStartInfo
            {
                FileName = GetDotnetPath(),
                Arguments = $"\"{guiDll}\" --status-dir \"{enabledStatusDirectory}\" --placement-path \"{Path.Combine(directory, "enabled-placement.json")}\" --codex-sessions-dir \"{sessionsRoot}\"",
                WorkingDirectory = repoRoot,
                UseShellExecute = false,
                CreateNoWindow = true
            }) ?? throw new InvalidOperationException("Failed to start Vibestick GUI."))
            {
                try
                {
                    await WaitForPetSnapshotAnyAsync(enabledStatusDirectory, TimeSpan.FromSeconds(10)).ConfigureAwait(false);
                    var enabledSession = Path.Combine(sessionDay, "rollout-2026-05-18T10-00-00-enabled.jsonl");
                    await File.WriteAllTextAsync(
                            enabledSession,
                            """{"type":"response_item","payload":{"type":"function_call","name":"shell_command","arguments":"Get-Content secret.txt"}}""" + Environment.NewLine)
                        .ConfigureAwait(false);

                    await WaitForPetSnapshotAsync(enabledStatusDirectory, "tool_calling", TimeSpan.FromSeconds(10))
                        .ConfigureAwait(false);
                }
                finally
                {
                    KillProcessTree(enabled);
                }
            }

            using (var disabled = Process.Start(new ProcessStartInfo
            {
                FileName = GetDotnetPath(),
                Arguments = $"\"{guiDll}\" --status-dir \"{disabledStatusDirectory}\" --placement-path \"{Path.Combine(directory, "disabled-placement.json")}\" --codex-sessions-dir \"{sessionsRoot}\" --no-codex-monitor",
                WorkingDirectory = repoRoot,
                UseShellExecute = false,
                CreateNoWindow = true
            }) ?? throw new InvalidOperationException("Failed to start Vibestick GUI."))
            {
                try
                {
                    await WaitForPetSnapshotAnyAsync(disabledStatusDirectory, TimeSpan.FromSeconds(10)).ConfigureAwait(false);
                    var disabledSession = Path.Combine(sessionDay, "rollout-2026-05-18T10-00-01-disabled.jsonl");
                    await File.WriteAllTextAsync(
                            disabledSession,
                            """{"type":"response_item","payload":{"type":"function_call","name":"shell_command"}}""" + Environment.NewLine)
                        .ConfigureAwait(false);
                    await Task.Delay(TimeSpan.FromSeconds(1.5)).ConfigureAwait(false);
                    AssertFalse(File.Exists(CoderStatusPaths.GetStatusPath(disabledStatusDirectory, "codex")));
                }
                finally
                {
                    KillProcessTree(disabled);
                }
            }
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static async Task TestDesktopPetE2EAsync()
    {
        var repoRoot = FindRepoRoot();
        var directory = Path.Combine(Path.GetTempPath(), $"vibestick-e2e-{Guid.NewGuid():N}");
        var publishDirectory = Path.Combine(directory, "publish");
        var placementPath = Path.Combine(directory, "pet-window.json");
        Directory.CreateDirectory(directory);

        await new CoderStatusWriter(directory)
            .EmitAsync("codex", CoderAgentPhase.Reasoning, "reasoning", ttlSeconds: 60)
            .ConfigureAwait(false);

        var guiDll = await PublishGuiForSmokeAsync(repoRoot, publishDirectory).ConfigureAwait(false);

        using var process = Process.Start(new ProcessStartInfo
        {
            FileName = GetDotnetPath(),
            Arguments = $"\"{guiDll}\" --no-codex-monitor --status-dir \"{directory}\" --placement-path \"{placementPath}\"",
            WorkingDirectory = repoRoot,
            UseShellExecute = false,
            CreateNoWindow = true
        }) ?? throw new InvalidOperationException("Failed to start Vibestick GUI.");

        try
        {
            var reasoning = await WaitForPetSnapshotAsync(directory, "reasoning", TimeSpan.FromSeconds(10))
                .ConfigureAwait(false);
            AssertDefaultPetScale(reasoning);
            AssertNearBottomRight(reasoning);

            await new CoderStatusWriter(directory)
                .EmitAsync("codex", CoderAgentPhase.ToolCalling, "tool", processId: process.Id, ttlSeconds: 60)
                .ConfigureAwait(false);
            await WaitForPetSnapshotAsync(directory, "tool_calling", TimeSpan.FromSeconds(10))
                .ConfigureAwait(false);

            await new CoderStatusWriter(directory)
                .EmitAsync("codex", CoderAgentPhase.WaitingAuthorization, "approval", processId: process.Id, ttlSeconds: 60)
                .ConfigureAwait(false);
            await WaitForPetSnapshotAsync(directory, "waiting_authorization", TimeSpan.FromSeconds(10))
                .ConfigureAwait(false);
        }
        finally
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit(5000);
            }

            Directory.Delete(directory, recursive: true);
        }
    }

    private static async Task TestDesktopPetMultiSessionE2EAsync()
    {
        var repoRoot = FindRepoRoot();
        var directory = Path.Combine(Path.GetTempPath(), $"vibestick-e2e-multi-{Guid.NewGuid():N}");
        var publishDirectory = Path.Combine(directory, "publish");
        var placementPath = Path.Combine(directory, "pet-window.json");
        Directory.CreateDirectory(directory);

        var writer = new CoderStatusWriter(directory);
        await writer.EmitAsync("codex", CoderAgentPhase.WaitingAuthorization, "approval", ttlSeconds: 60, sessionId: "session-1", taskSummary: "Authorize deployment").ConfigureAwait(false);
        await writer.EmitAsync("codex", CoderAgentPhase.ToolCalling, "Using shell_command", ttlSeconds: 60, sessionId: "session-2", taskSummary: "Run focused tests").ConfigureAwait(false);
        await writer.EmitAsync("codex", CoderAgentPhase.Reasoning, "Thinking", ttlSeconds: 60, sessionId: "session-3", taskSummary: "Design pet task cards").ConfigureAwait(false);
        await writer.EmitAsync("codex", CoderAgentPhase.Running, "Running", ttlSeconds: 60, sessionId: "session-4", taskSummary: "Prepare docs").ConfigureAwait(false);

        var guiDll = await PublishGuiForSmokeAsync(repoRoot, publishDirectory).ConfigureAwait(false);

        using var process = Process.Start(new ProcessStartInfo
        {
            FileName = GetDotnetPath(),
            Arguments = $"\"{guiDll}\" --no-codex-monitor --status-dir \"{directory}\" --placement-path \"{placementPath}\"",
            WorkingDirectory = repoRoot,
            UseShellExecute = false,
            CreateNoWindow = true
        }) ?? throw new InvalidOperationException("Failed to start Vibestick GUI.");

        try
        {
            var snapshot = await WaitForPetTaskCardsAsync(directory, total: 4, visible: 3, hidden: 1, TimeSpan.FromSeconds(10))
                .ConfigureAwait(false);
            AssertEqual(false, snapshot["taskCards"]?["expanded"]?.GetValue<bool>());

            var items = snapshot["taskCards"]?["items"]?.AsArray() ??
                throw new InvalidOperationException("Snapshot missing task card items.");
            AssertEqual(3, items.Count);
            AssertEqual("Authorize deployment", items[0]?["summary"]?.GetValue<string>());
            AssertEqual("Run focused tests", items[1]?["summary"]?.GetValue<string>());
            AssertEqual("Design pet task cards", items[2]?["summary"]?.GetValue<string>());
        }
        finally
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit(5000);
            }

            Directory.Delete(directory, recursive: true);
        }
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

    private static VibestickStatus CreateStatus(
        VibestickMode mode = VibestickMode.On,
        BatteryInfo? battery = null,
        IReadOnlyList<string>? warnings = null)
    {
        return new VibestickStatus(
            mode,
            RestorePending: mode != VibestickMode.Off,
            LastAppliedSchemeGuid: "scheme-a",
            OriginalPolicy: null,
            CurrentSchemeGuid: "scheme-a",
            CurrentPolicy: new PowerPolicySnapshot("scheme-a", 0, 0),
            battery ?? new BatteryInfo(90, IsAcConnected: true, IsAvailable: true),
            Array.Empty<LongTaskProcess>(),
            warnings ?? Array.Empty<string>());
    }

    private static CoderAgentStatus CreateCoder(
        string agent,
        CoderAgentPhase phase,
        string? message = null,
        DateTimeOffset? updatedAtUtc = null,
        string? sessionId = null,
        string? summary = null,
        string? workspace = null,
        string? sourcePath = null)
    {
        return new CoderAgentStatus(
            agent,
            phase,
            message,
            workspace,
            ProcessId: null,
            updatedAtUtc ?? DateTimeOffset.UtcNow,
            TtlSeconds: 120,
            sessionId,
            summary,
            sourcePath);
    }

    private static string GetBatteryBadgeText(PetState state)
    {
        return state.Badges.FirstOrDefault(static badge => badge.Kind == PetBadgeKind.Battery)?.Text
            ?? throw new InvalidOperationException("Expected battery badge.");
    }

    private static string FindRepoRoot()
    {
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "Vibestick.sln")))
        {
            directory = directory.Parent;
        }

        return directory?.FullName ?? throw new InvalidOperationException("Could not locate Vibestick.sln.");
    }

    private static string GetDotnetPath()
    {
        var localDotnet = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".dotnet",
            "dotnet.exe");
        return File.Exists(localDotnet) ? localDotnet : "dotnet";
    }

    private static Task<CommandResult> RunDotnetAsync(string workingDirectory, string arguments)
    {
        return RunDotnetAsync(workingDirectory, arguments, TimeSpan.FromSeconds(60));
    }

    private static async Task<CommandResult> RunDotnetAsync(
        string workingDirectory,
        string arguments,
        TimeSpan timeout)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = GetDotnetPath(),
            Arguments = arguments,
            WorkingDirectory = workingDirectory,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("Failed to start dotnet.");
        var outputTask = process.StandardOutput.ReadToEndAsync();
        var errorTask = process.StandardError.ReadToEndAsync();
        using var timeoutSource = new CancellationTokenSource(timeout);
        try
        {
            await process.WaitForExitAsync(timeoutSource.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
            }

            throw new TimeoutException($"dotnet {arguments} did not exit within {timeout.TotalSeconds} seconds.");
        }

        var output = await outputTask.ConfigureAwait(false);
        var error = await errorTask.ConfigureAwait(false);
        return new CommandResult(process.ExitCode, output, error);
    }

    private static async Task<string> PublishGuiForSmokeAsync(string repoRoot, string publishDirectory)
    {
        var appDirectory = Path.Combine(publishDirectory, "app");
        var binDirectory = Path.Combine(publishDirectory, "bin");
        var objDirectory = Path.Combine(publishDirectory, "obj");
        var binPath = binDirectory.Replace('\\', '/') + "/";
        var objPath = objDirectory.Replace('\\', '/') + "/";
        var result = await RunDotnetAsync(
                repoRoot,
                $"publish src\\Vibestick.Gui --configuration Release --no-restore --no-dependencies -p:UseAppHost=false -p:OutputPath=\"{binPath}\" -p:IntermediateOutputPath=\"{objPath}\" --output \"{appDirectory}\"",
                TimeSpan.FromSeconds(60))
            .ConfigureAwait(false);
        AssertEqual(0, result.ExitCode);

        var dll = Path.Combine(appDirectory, "vibestick-gui.dll");
        if (!File.Exists(dll))
        {
            throw new InvalidOperationException($"Expected published GUI assembly at {dll}.");
        }

        return dll;
    }

    private static async Task<CommandResult> RunProcessAsync(
        string fileName,
        string arguments,
        string workingDirectory,
        TimeSpan timeout)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            WorkingDirectory = workingDirectory,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException($"Failed to start {fileName}.");
        var outputTask = process.StandardOutput.ReadToEndAsync();
        var errorTask = process.StandardError.ReadToEndAsync();
        using var timeoutSource = new CancellationTokenSource(timeout);
        try
        {
            await process.WaitForExitAsync(timeoutSource.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
            }

            throw new TimeoutException($"{fileName} {arguments} did not exit within {timeout.TotalSeconds} seconds.");
        }

        return new CommandResult(
            process.ExitCode,
            await outputTask.ConfigureAwait(false),
            await errorTask.ConfigureAwait(false));
    }

    private static async Task<CoderAgentStatus> WaitForCoderStatusAsync(
        string statusDirectory,
        CoderAgentPhase expectedPhase,
        TimeSpan timeout)
    {
        var source = new JsonFileCoderStatusSource(statusDirectory);
        var deadline = DateTimeOffset.UtcNow.Add(timeout);
        while (DateTimeOffset.UtcNow < deadline)
        {
            var status = source.GetStatuses(DateTimeOffset.UtcNow)
                .FirstOrDefault(static status => string.Equals(status.Agent, "codex", StringComparison.OrdinalIgnoreCase));
            if (status?.Phase == expectedPhase)
            {
                return status;
            }

            await Task.Delay(100).ConfigureAwait(false);
        }

        throw new TimeoutException($"Coder status did not reach phase '{expectedPhase}' within {timeout.TotalSeconds} seconds.");
    }

    private static async Task<IReadOnlyList<CoderAgentStatus>> WaitForCoderStatusCountAsync(
        string statusDirectory,
        int expectedCount,
        TimeSpan timeout)
    {
        var source = new JsonFileCoderStatusSource(statusDirectory);
        var deadline = DateTimeOffset.UtcNow.Add(timeout);
        while (DateTimeOffset.UtcNow < deadline)
        {
            var statuses = source.GetStatuses(DateTimeOffset.UtcNow);
            if (statuses.Count == expectedCount)
            {
                return statuses;
            }

            await Task.Delay(100).ConfigureAwait(false);
        }

        throw new TimeoutException($"Coder status count did not reach {expectedCount} within {timeout.TotalSeconds} seconds.");
    }

    private static async Task<JsonNode> WaitForPetSnapshotAnyAsync(
        string statusDirectory,
        TimeSpan timeout)
    {
        var path = Path.Combine(statusDirectory, "pet-runtime-state.snapshot");
        var deadline = DateTimeOffset.UtcNow.Add(timeout);
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (File.Exists(path))
            {
                try
                {
                    return JsonNode.Parse(await File.ReadAllTextAsync(path).ConfigureAwait(false)) ??
                        throw new InvalidOperationException("Expected snapshot JSON.");
                }
                catch (Exception exception) when (exception is IOException or System.Text.Json.JsonException)
                {
                }
            }

            await Task.Delay(250).ConfigureAwait(false);
        }

        throw new TimeoutException($"Pet snapshot was not written within {timeout.TotalSeconds} seconds.");
    }

    private static async Task<JsonNode> WaitForPetSnapshotAsync(
        string statusDirectory,
        string expectedMood,
        TimeSpan timeout)
    {
        var path = Path.Combine(statusDirectory, "pet-runtime-state.snapshot");
        var deadline = DateTimeOffset.UtcNow.Add(timeout);
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (File.Exists(path))
            {
                try
                {
                    var node = JsonNode.Parse(await File.ReadAllTextAsync(path).ConfigureAwait(false));
                    if (string.Equals(node?["mood"]?.GetValue<string>(), expectedMood, StringComparison.OrdinalIgnoreCase))
                    {
                        return node!;
                    }
                }
                catch (Exception exception) when (exception is IOException or System.Text.Json.JsonException)
                {
                }
            }

            await Task.Delay(250).ConfigureAwait(false);
        }

        throw new TimeoutException($"Pet snapshot did not reach mood '{expectedMood}' within {timeout.TotalSeconds} seconds.");
    }

    private static async Task<JsonNode> WaitForPetTaskCardsAsync(
        string statusDirectory,
        int total,
        int visible,
        int hidden,
        TimeSpan timeout)
    {
        var path = Path.Combine(statusDirectory, "pet-runtime-state.snapshot");
        var deadline = DateTimeOffset.UtcNow.Add(timeout);
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (File.Exists(path))
            {
                try
                {
                    var node = JsonNode.Parse(await File.ReadAllTextAsync(path).ConfigureAwait(false));
                    var taskCards = node?["taskCards"];
                    if (taskCards?["total"]?.GetValue<int>() == total &&
                        taskCards["visible"]?.GetValue<int>() == visible &&
                        taskCards["hidden"]?.GetValue<int>() == hidden)
                    {
                        return node!;
                    }
                }
                catch (Exception exception) when (exception is IOException or System.Text.Json.JsonException)
                {
                }
            }

            await Task.Delay(250).ConfigureAwait(false);
        }

        throw new TimeoutException($"Pet task cards did not reach total={total}, visible={visible}, hidden={hidden} within {timeout.TotalSeconds} seconds.");
    }

    private static void AssertNearBottomRight(JsonNode snapshot)
    {
        var left = snapshot["left"]?.GetValue<double>() ?? throw new InvalidOperationException("Snapshot missing left.");
        var top = snapshot["top"]?.GetValue<double>() ?? throw new InvalidOperationException("Snapshot missing top.");
        var width = snapshot["width"]?.GetValue<double>() ?? throw new InvalidOperationException("Snapshot missing width.");
        var height = snapshot["height"]?.GetValue<double>() ?? throw new InvalidOperationException("Snapshot missing height.");

        var rightGap = Math.Abs((NativeMethods.GetSystemMetric(NativeMethods.SmXVirtualScreen) +
            NativeMethods.GetSystemMetric(NativeMethods.SmCxVirtualScreen)) - (left + width));
        var bottomGap = Math.Abs((NativeMethods.GetSystemMetric(NativeMethods.SmYVirtualScreen) +
            NativeMethods.GetSystemMetric(NativeMethods.SmCyVirtualScreen)) - (top + height));

        if (rightGap > 320 || bottomGap > 320)
        {
            throw new InvalidOperationException($"Expected pet near bottom-right, got left={left}, top={top}, width={width}, height={height}.");
        }
    }

    private static void AssertDefaultPetScale(JsonNode snapshot)
    {
        var width = snapshot["width"]?.GetValue<double>() ?? throw new InvalidOperationException("Snapshot missing width.");
        var height = snapshot["height"]?.GetValue<double>() ?? throw new InvalidOperationException("Snapshot missing height.");
        var scale = snapshot["scale"]?.GetValue<double>() ?? throw new InvalidOperationException("Snapshot missing scale.");

        AssertNear(410, width, 0.5, "pet width");
        AssertNear(580, height, 0.5, "pet height");
        AssertNear(1.0, scale, 0.001, "pet scale");
    }

    private static void AssertNear(double expected, double actual, double tolerance, string name)
    {
        if (Math.Abs(expected - actual) > tolerance)
        {
            throw new InvalidOperationException($"Expected {name} near {expected}, got {actual}.");
        }
    }

    private static void KillProcessTree(Process process)
    {
        if (process.HasExited)
        {
            return;
        }

        process.Kill(entireProcessTree: true);
        process.WaitForExit(5000);
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

    private sealed class StaticCoderStatusSource : ICoderStatusSource
    {
        private readonly IReadOnlyList<CoderAgentStatus> _statuses;

        public StaticCoderStatusSource(IReadOnlyList<CoderAgentStatus> statuses)
        {
            _statuses = statuses;
        }

        public IReadOnlyList<CoderAgentStatus> GetStatuses(DateTimeOffset now) => _statuses;
    }

    private static class NativeMethods
    {
        public const int SmXVirtualScreen = 76;
        public const int SmYVirtualScreen = 77;
        public const int SmCxVirtualScreen = 78;
        public const int SmCyVirtualScreen = 79;

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern int GetSystemMetrics(int nIndex);

        public static int GetSystemMetric(int index) => GetSystemMetrics(index);
    }
}
