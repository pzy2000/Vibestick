import Foundation
import XCTest
@testable import VibestickMacCore

final class VibestickMacCoreTests: XCTestCase {
    func testPmsetCustomParserReadsBatteryAndACSections() {
        let snapshot = PmsetParser.parseCustom("""
        Battery Power:
         lowpowermode         0
         sleep                1
         displaysleep         10
        AC Power:
         lowpowermode         0
         sleep                0
         displaysleep         20
        """)

        XCTAssertEqual(snapshot.value("sleep", source: .battery), "1")
        XCTAssertEqual(snapshot.value("displaysleep", source: .battery), "10")
        XCTAssertEqual(snapshot.value("sleep", source: .ac), "0")
        XCTAssertEqual(snapshot.value("displaysleep", source: .ac), "20")
    }

    func testApplyOnBacksUpAndRestoreReturnsOriginalSleepSettings() throws {
        let statePath = temporaryStatePath()
        let runner = FakeRunner()
        runner.customOutput = samplePmset
        runner.capOutput = sampleCapabilities
        let manager = PmsetPowerPolicyManager(runner: runner, statePath: statePath, requiresRootForMutations: false)

        let result = try manager.applyOn()
        XCTAssertEqual(result.appliedMode, .on)
        XCTAssertTrue(result.restorePending)
        XCTAssertTrue(runner.invocations.contains(["/usr/bin/pmset", "-a", "sleep", "0"]))

        let restore = try manager.restore()
        XCTAssertEqual(restore.appliedMode, .off)
        XCTAssertTrue(runner.invocations.contains(["/usr/bin/pmset", "-b", "sleep", "1"]))
        XCTAssertTrue(runner.invocations.contains(["/usr/bin/pmset", "-c", "sleep", "0"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: statePath.path))
    }

    func testApplyHyperOverridesBatterySleepPrioritiesWithoutBatteryThresholds() throws {
        let statePath = temporaryStatePath()
        let runner = FakeRunner()
        runner.customOutput = samplePmset
        runner.capOutput = sampleCapabilities
        let manager = PmsetPowerPolicyManager(runner: runner, statePath: statePath, requiresRootForMutations: false)

        let result = try manager.applyHyper()

        XCTAssertEqual(result.appliedMode, .hyper)
        XCTAssertEqual(result.warnings, [])
        XCTAssertTrue(runner.invocations.contains([
            "/usr/bin/pmset",
            "-a",
            "disksleep", "0",
            "lessbright", "0",
            "lowpowermode", "0",
            "sleep", "0",
            "standby", "0"
        ]))
    }

    func testSwitchingHyperToOnRestoresHyperOnlyBatteryOverrides() throws {
        let statePath = temporaryStatePath()
        let runner = FakeRunner()
        runner.customOutput = samplePmset
        runner.capOutput = sampleCapabilities
        let manager = PmsetPowerPolicyManager(runner: runner, statePath: statePath, requiresRootForMutations: false)

        _ = try manager.applyHyper()
        runner.invocations.removeAll()

        let result = try manager.applyOn()

        XCTAssertEqual(result.appliedMode, .on)
        XCTAssertTrue(runner.invocations.contains([
            "/usr/bin/pmset",
            "-b",
            "disksleep", "10",
            "lessbright", "1",
            "lowpowermode", "0",
            "sleep", "1",
            "standby", "1"
        ]))
        XCTAssertTrue(runner.invocations.contains([
            "/usr/bin/pmset",
            "-c",
            "disksleep", "0",
            "lowpowermode", "0",
            "sleep", "0",
            "standby", "1"
        ]))
        XCTAssertTrue(runner.invocations.contains(["/usr/bin/pmset", "-a", "sleep", "0"]))

        let backup = try XCTUnwrap(manager.readBackup())
        XCTAssertEqual(backup.activeMode, .on)
        XCTAssertEqual(backup.affectedKeys, ["sleep"])
    }

    func testSystemStatePathFailsBeforeWritingWhenNotRoot() throws {
        if geteuid() == 0 {
            throw XCTSkip("Root test environment does not exercise non-root preflight.")
        }

        let statePath = URL(fileURLWithPath: "/Library/Application Support/Vibestick/power-state.json")
        let runner = FakeRunner()
        runner.customOutput = samplePmset
        runner.capOutput = sampleCapabilities
        let manager = PmsetPowerPolicyManager(runner: runner, statePath: statePath, requiresRootForMutations: true)

        XCTAssertThrowsError(try manager.applyHyper()) { error in
            XCTAssertEqual(
                error as? PowerPolicyError,
                .privilegedHelperRequired(statePath: statePath.path))
        }
        XCTAssertEqual(runner.invocations, [])
    }

    func testSubprocessHelperClientUnwrapsHelperJsonError() {
        let runner = FakeRunner()
        runner.forcedResult = CommandResult(
            exitCode: 3,
            standardOutput: """
            {
              "message" : "Mac power policy changes require the privileged Vibestick helper.",
              "ok" : false,
              "state_path" : "/Library/Application Support/Vibestick/power-state.json"
            }
            """,
            standardError: "")
        let client = SubprocessHelperClient(helperPath: "/tmp/helper", runner: runner)

        XCTAssertThrowsError(try client.applyHyper()) { error in
            XCTAssertEqual(
                error as? HelperClientError,
                .helperFailed("Mac power policy changes require the privileged Vibestick helper."))
        }
    }

    func testSubprocessHelperClientRunsInstalledMutationsWithAdministratorPrivileges() throws {
        let runner = FakeRunner()
        runner.forcedResult = CommandResult(
            exitCode: 0,
            standardOutput: """
            {
              "requested_mode": "on",
              "applied_mode": "on",
              "restore_pending": true,
              "warnings": [],
              "message": "ON mode applied."
            }
            """,
            standardError: "")
        let client = SubprocessHelperClient(
            helperPath: VibestickPaths.installedHelperPath,
            runner: runner)

        let result = try client.applyOn()

        XCTAssertEqual(result.appliedMode, .on)
        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation[0], "/usr/bin/osascript")
        XCTAssertEqual(invocation[1], "-e")
        XCTAssertTrue(invocation[2].contains("with administrator privileges"))
        XCTAssertTrue(invocation[2].contains("'/Library/PrivilegedHelperTools/com.pzy.vibestick.helper' '--json' 'apply-on'"))
    }

    func testSubprocessHelperClientKeepsStatusUnprivilegedForInstalledHelper() throws {
        let runner = FakeRunner()
        runner.forcedResult = CommandResult(
            exitCode: 0,
            standardOutput: """
            {
              "ok": true,
              "snapshot": null,
              "backup": null,
              "state_path": "/Library/Application Support/Vibestick/power-state.json"
            }
            """,
            standardError: "")
        let client = SubprocessHelperClient(
            helperPath: VibestickPaths.installedHelperPath,
            runner: runner)

        let status = try client.status()

        XCTAssertTrue(status.ok)
        XCTAssertEqual(runner.invocations.first, [VibestickPaths.installedHelperPath, "--json", "status"])
    }

    func testSubprocessHelperClientUnwrapsPrivilegedHelperJsonError() {
        let runner = FakeRunner()
        runner.forcedResult = CommandResult(
            exitCode: 3,
            standardOutput: """
            {
              "message": "Mac power policy changes require the privileged Vibestick helper.",
              "ok": false,
              "state_path": "/Library/Application Support/Vibestick/power-state.json"
            }
            """,
            standardError: "")
        let client = SubprocessHelperClient(
            helperPath: VibestickPaths.installedHelperPath,
            runner: runner)

        XCTAssertThrowsError(try client.applyHyper()) { error in
            XCTAssertEqual(
                error as? HelperClientError,
                .helperFailed("Mac power policy changes require the privileged Vibestick helper."))
        }
        XCTAssertEqual(runner.invocations.first?[0], "/usr/bin/osascript")
    }

    func testHelperInstallerBuildsPrivilegedLaunchDaemonInstallScript() throws {
        let directory = temporaryDirectory()
        let sourceHelper = try createExecutable(named: "VibestickHelper", in: directory)
        let sourcePlist = directory.appendingPathComponent("com.pzy.vibestick.helper.plist")
        FileManager.default.createFile(atPath: sourcePlist.path, contents: Data("<plist/>".utf8))
        let runner = FakeRunner()
        runner.forcedResult = CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        let paths = HelperInstallPaths(
            sourceHelperPath: sourceHelper.path,
            sourcePlistPath: sourcePlist.path,
            installedHelperPath: "/tmp/com.pzy.vibestick.helper",
            installedPlistPath: "/tmp/com.pzy.vibestick.helper.plist")
        let installer = MacHelperInstaller(paths: paths, runner: runner)

        let result = try installer.install()

        XCTAssertEqual(result.installedHelperPath, "/tmp/com.pzy.vibestick.helper")
        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation[0], "/usr/bin/osascript")
        XCTAssertEqual(invocation[1], "-e")
        XCTAssertTrue(invocation[2].contains("with administrator privileges"))
        XCTAssertTrue(invocation[2].contains("install -o root -g wheel -m 755"))
        XCTAssertTrue(invocation[2].contains("/private/tmp/VibestickHelperInstall-"))
        XCTAssertFalse(invocation[2].contains(sourceHelper.path))
        XCTAssertFalse(invocation[2].contains(sourcePlist.path))
        XCTAssertTrue(invocation[2].contains("launchctl bootstrap system '/tmp/com.pzy.vibestick.helper.plist'"))
        XCTAssertTrue(invocation[2].contains("launchctl enable system/'com.pzy.vibestick.helper'"))
    }

    func testHelperInstallerStagesReadableFilesAndCleansThemAfterSmokeInstall() throws {
        let directory = temporaryDirectory()
        let sourceHelper = try createExecutable(named: "VibestickHelper", in: directory)
        let sourcePlist = directory.appendingPathComponent("com.pzy.vibestick.helper.plist")
        FileManager.default.createFile(atPath: sourcePlist.path, contents: Data("<plist/>".utf8))
        let runner = FakeRunner()
        var stagedDirectoryPath: String?
        runner.onRun = { executable, arguments in
            XCTAssertEqual(executable, "/usr/bin/osascript")
            let script = arguments.joined(separator: "\n")
            let stageDirectory = try XCTUnwrap(extractStagedDirectory(from: script))
            stagedDirectoryPath = stageDirectory
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: "\(stageDirectory)/com.pzy.vibestick.helper"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: "\(stageDirectory)/com.pzy.vibestick.helper.plist"))
            return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        let installer = MacHelperInstaller(
            paths: HelperInstallPaths(sourceHelperPath: sourceHelper.path, sourcePlistPath: sourcePlist.path),
            runner: runner)

        _ = try installer.install()

        XCTAssertNotNil(stagedDirectoryPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(stagedDirectoryPath)))
    }

    func testHelperInstallerCleansStagingDirectoryAfterPrivilegedFailure() throws {
        let directory = temporaryDirectory()
        let sourceHelper = try createExecutable(named: "VibestickHelper", in: directory)
        let sourcePlist = directory.appendingPathComponent("com.pzy.vibestick.helper.plist")
        FileManager.default.createFile(atPath: sourcePlist.path, contents: Data("<plist/>".utf8))
        let runner = FakeRunner()
        var stagedDirectoryPath: String?
        runner.onRun = { _, arguments in
            stagedDirectoryPath = try XCTUnwrap(extractStagedDirectory(from: arguments.joined(separator: "\n")))
            return CommandResult(exitCode: 1, standardOutput: "", standardError: "install failed")
        }
        let installer = MacHelperInstaller(
            paths: HelperInstallPaths(sourceHelperPath: sourceHelper.path, sourcePlistPath: sourcePlist.path),
            runner: runner)

        XCTAssertThrowsError(try installer.install())

        XCTAssertNotNil(stagedDirectoryPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(stagedDirectoryPath)))
    }

    func testHelperInstallerFailsPreflightWhenSourceHelperIsMissing() throws {
        let directory = temporaryDirectory()
        let sourcePlist = directory.appendingPathComponent("com.pzy.vibestick.helper.plist")
        FileManager.default.createFile(atPath: sourcePlist.path, contents: Data("<plist/>".utf8))
        let runner = FakeRunner()
        let installer = MacHelperInstaller(
            paths: HelperInstallPaths(
                sourceHelperPath: directory.appendingPathComponent("missing-helper").path,
                sourcePlistPath: sourcePlist.path),
            runner: runner)

        XCTAssertThrowsError(try installer.install()) { error in
            XCTAssertEqual(
                error as? HelperInstallError,
                .missingSourceHelper(directory.appendingPathComponent("missing-helper").path))
        }
        XCTAssertEqual(runner.invocations, [])
    }

    func testHelperInstallerMapsAdministratorCancelToFriendlyError() throws {
        let directory = temporaryDirectory()
        let sourceHelper = try createExecutable(named: "VibestickHelper", in: directory)
        let sourcePlist = directory.appendingPathComponent("com.pzy.vibestick.helper.plist")
        FileManager.default.createFile(atPath: sourcePlist.path, contents: Data("<plist/>".utf8))
        let runner = FakeRunner()
        runner.forcedResult = CommandResult(
            exitCode: 1,
            standardOutput: "",
            standardError: "execution error: User canceled. (-128)")
        let installer = MacHelperInstaller(
            paths: HelperInstallPaths(sourceHelperPath: sourceHelper.path, sourcePlistPath: sourcePlist.path),
            runner: runner)

        XCTAssertThrowsError(try installer.install()) { error in
            XCTAssertEqual(error.localizedDescription, "Helper 安装已取消。")
        }
    }

    func testDoctorReportsMissingHelperAndUnavailablePmsetInChinese() {
        let doctor = MacDoctorService(
            helper: FakeHelperClient(
                helperPath: "/tmp/vibestick-missing-helper",
                statusResult: .failure(HelperClientError.helperFailed("helper down"))),
            battery: FakeBatteryMonitor(),
            processInspector: FakeProcessInspector(),
            assertionManager: FakeAssertionManager())

        let report = doctor.run()

        let helper = report.checks.first { $0.name == "helper" }
        let pmset = report.checks.first { $0.name == "pmset" }
        XCTAssertEqual(helper?.passed, false)
        XCTAssertTrue(helper?.message.contains("Helper 未安装") == true)
        XCTAssertEqual(pmset?.passed, false)
        XCTAssertTrue(pmset?.message.contains("无法读取 pmset 状态") == true)
    }

    func testDoctorReportsNilPmsetSnapshotInChinese() {
        let doctor = MacDoctorService(
            helper: FakeHelperClient(
                helperPath: "direct",
                statusResult: .success(HelperStatus(ok: true, snapshot: nil, backup: nil, statePath: "/tmp/state.json"))),
            battery: FakeBatteryMonitor(),
            processInspector: FakeProcessInspector(),
            assertionManager: FakeAssertionManager())

        let report = doctor.run()

        let pmset = report.checks.first { $0.name == "pmset" }
        XCTAssertEqual(pmset?.passed, false)
        XCTAssertEqual(pmset?.message, "无法读取 pmset 快照。")
    }

    func testCoderStatusJsonUsesSnakeCaseCompatibleKeys() throws {
        let directory = temporaryDirectory()
        let writer = CoderStatusWriter(directory: directory)
        let source = JsonFileCoderStatusSource(directory: directory)

        _ = try writer.emit(
            agent: "codex",
            phase: .toolCalling,
            message: "Running tests",
            workspace: "/tmp/Vibestick",
            processId: 42,
            ttlSeconds: 120,
            sessionId: "session-1",
            taskSummary: "Port Mac",
            sourcePath: nil,
            taskDetail: "Swift test")

        let path = directory.appendingPathComponent("codex-session-1.json")
        let json = try String(contentsOf: path)
        XCTAssertTrue(json.contains("\"tool_calling\""))
        XCTAssertTrue(json.contains("\"updated_at_utc\""))
        XCTAssertTrue(json.contains("\"task_summary\""))

        let statuses = source.getStatuses(now: Date())
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses[0].phase, .toolCalling)
        XCTAssertEqual(statuses[0].taskSummary, "Port Mac")
    }

    func testCoderStatusIdentityUsesSessionWhenPresent() {
        XCTAssertEqual(
            coderStatus(agent: "codex", sessionId: "session-a").identity,
            "codex:session-a")
        XCTAssertEqual(
            coderStatus(agent: "codex", sessionId: nil).identity,
            "codex")
    }

    func testCompositeCoderStatusSourcePreservesMultipleSessionsForSameAgent() {
        let now = Date()
        let source = CompositeCoderStatusSource([
            StaticCoderStatusSource(statuses: [
                coderStatus(
                    agent: "codex",
                    phase: .reasoning,
                    updatedAtUtc: now,
                    sessionId: "session-a",
                    taskSummary: "First task"),
                coderStatus(
                    agent: "codex",
                    phase: .toolCalling,
                    updatedAtUtc: now.addingTimeInterval(1),
                    sessionId: "session-b",
                    taskSummary: "Second task")
            ])
        ])

        let statuses = source.getStatuses(now: now)

        XCTAssertEqual(statuses.count, 2)
        XCTAssertEqual(statuses.map(\.sessionId), ["session-b", "session-a"])
        XCTAssertEqual(statuses.map(\.taskSummary), ["Second task", "First task"])
    }

    func testCompositeCoderStatusSourceDeduplicatesSameSessionByPriorityAndTimestamp() {
        let now = Date()
        let source = CompositeCoderStatusSource([
            StaticCoderStatusSource(statuses: [
                coderStatus(
                    agent: "codex",
                    phase: .reasoning,
                    message: "newer reasoning",
                    updatedAtUtc: now.addingTimeInterval(3),
                    sessionId: "session-a",
                    taskSummary: "Reasoning task"),
                coderStatus(
                    agent: "codex",
                    phase: .toolCalling,
                    message: "older tool",
                    updatedAtUtc: now.addingTimeInterval(1),
                    sessionId: "session-a",
                    taskSummary: "Older tool task"),
                coderStatus(
                    agent: "codex",
                    phase: .toolCalling,
                    message: "newer tool",
                    updatedAtUtc: now.addingTimeInterval(2),
                    sessionId: "session-a",
                    taskSummary: "Newer tool task")
            ])
        ])

        let statuses = source.getStatuses(now: now)

        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses[0].sessionId, "session-a")
        XCTAssertEqual(statuses[0].phase, .toolCalling)
        XCTAssertEqual(statuses[0].message, "newer tool")
        XCTAssertEqual(statuses[0].taskSummary, "Newer tool task")
    }

    func testCodexSessionStatusSourceDetectsActiveToolCall() throws {
        let sessionsRoot = temporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        let now = Date()
        let timestamp = isoTimestamp(now.addingTimeInterval(-5))
        let sessionPath = try writeCodexSession(
            sessionsRoot: sessionsRoot,
            modifiedAt: now,
            contents: """
            {"type":"session_meta","payload":{"id":"session-a","cwd":"/Users/pzy/Desktop/Vibestick"}}
            {"type":"event_msg","payload":{"type":"user_message","message":"<environment_context>ignore</environment_context> 请帮我修复 Mac active codex task 探测"}}
            {"type":"event_msg","payload":{"type":"agent_message","message":"Running focused Mac checks"}}
            {"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"function_call","name":"shell_command","arguments":"cat secret.txt"}}
            """)
        let source = CodexSessionStatusSource(sessionsRoot: sessionsRoot)

        let statuses = source.getStatuses(now: now)

        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses[0].agent, "codex")
        XCTAssertEqual(statuses[0].phase, .toolCalling)
        XCTAssertEqual(statuses[0].message, "Using shell_command")
        XCTAssertEqual(statuses[0].workspace, "/Users/pzy/Desktop/Vibestick")
        XCTAssertEqual(statuses[0].sessionId, "session-a")
        XCTAssertEqual(statuses[0].taskSummary, "修复 Mac active codex task 探测")
        XCTAssertEqual(statuses[0].taskDetail, "Running focused Mac checks")
        XCTAssertEqual(
            URL(fileURLWithPath: try XCTUnwrap(statuses[0].sourcePath)).standardizedFileURL.path,
            sessionPath.standardizedFileURL.path)
        XCTAssertFalse(statuses[0].message?.localizedCaseInsensitiveContains("secret") == true)
    }

    func testCodexSessionStatusSourceIgnoresExpiredActiveEvent() throws {
        let sessionsRoot = temporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        let now = Date()
        let timestamp = isoTimestamp(now.addingTimeInterval(-301))
        try writeCodexSession(
            sessionsRoot: sessionsRoot,
            modifiedAt: now,
            contents: """
            {"type":"session_meta","payload":{"id":"session-a","cwd":"/tmp/repo"}}
            {"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"reasoning"}}
            """)
        let source = CodexSessionStatusSource(sessionsRoot: sessionsRoot)

        XCTAssertEqual(source.getStatuses(now: now), [])
    }

    func testCodexSessionStatusSourceUsesFileMtimeWhenTimestampIsMissing() throws {
        let sessionsRoot = temporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        let now = Date()
        try writeCodexSession(
            sessionsRoot: sessionsRoot,
            modifiedAt: now.addingTimeInterval(-301),
            contents: """
            {"type":"session_meta","payload":{"id":"session-a","cwd":"/tmp/repo"}}
            {"type":"response_item","payload":{"type":"reasoning"}}
            """)
        let source = CodexSessionStatusSource(sessionsRoot: sessionsRoot)

        XCTAssertEqual(source.getStatuses(now: now), [])
    }

    func testCompositeSourceUsesActiveCodexSessionBeforeSleepingProcessFallback() throws {
        let directory = temporaryDirectory()
        let sessionsRoot = temporaryDirectory().appendingPathComponent("sessions", isDirectory: true)
        let now = Date()
        let timestamp = isoTimestamp(now)
        try writeCodexSession(
            sessionsRoot: sessionsRoot,
            modifiedAt: now,
            contents: """
            {"type":"session_meta","payload":{"id":"session-a","cwd":"/tmp/repo"}}
            {"type":"event_msg","payload":{"type":"user_message","message":"Implement task cards"}}
            {"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"function_call","name":"shell_command"}}
            """)
        let source = CompositeCoderStatusSource([
            JsonFileCoderStatusSource(directory: directory),
            CodexSessionStatusSource(sessionsRoot: sessionsRoot),
            ProcessCoderStatusSource(
                processInspector: FakeProcessInspector(tasks: [LongTaskProcess(processId: 123, name: "codex")]),
                processNames: ["codex"])
        ])

        let statuses = source.getStatuses(now: now)

        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses[0].phase, .toolCalling)
        XCTAssertEqual(statuses[0].taskSummary, "Implement task cards")
    }

    func testDeviceDetectorLaunchesForFinalVibestickFirmware() {
        let detection = DeviceDetector.detect([
            DeviceSnapshot(instanceId: "USB\\VID_2E8A&PID_4002\\VS-RP2040-0002")
        ])
        let policy = DeviceAutoLaunchPolicy(debounce: 5)

        let decision = policy.evaluate(detection: detection, isGuiAlreadyRunning: false, now: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(detection.kind, .vibestickDevice)
        XCTAssertEqual(decision.action, .launch)
    }

    func testDeviceDetectorTreatsBootloaderIdentityAsBootloaderOnly() {
        let detection = DeviceDetector.detect([
            DeviceSnapshot(instanceId: "USB\\VID_2E8A&PID_0003")
        ])
        let policy = DeviceAutoLaunchPolicy(debounce: 5)

        let decision = policy.evaluate(detection: detection, isGuiAlreadyRunning: false, now: Date())

        XCTAssertEqual(detection.kind, .bootloader)
        XCTAssertEqual(decision.action, .bootloaderOnly)
    }

    func testDeviceDetectorTreatsRpiRp2VolumeAsBootloaderOnly() throws {
        let volumesRoot = temporaryDirectory()
        let bootloader = volumesRoot.appendingPathComponent("RPI-RP2", isDirectory: true)
        try FileManager.default.createDirectory(at: bootloader, withIntermediateDirectories: true)
        try "Board-ID: RPI-RP2\n".write(
            to: bootloader.appendingPathComponent("INFO_UF2.TXT"),
            atomically: true,
            encoding: .utf8)
        let source = MacUSBDeviceSnapshotSource(volumesRoot: volumesRoot, includeUSBDevices: false)

        let detection = DeviceDetector.detect(source.getSnapshots())

        XCTAssertEqual(detection.kind, .bootloader)
    }

    func testDeviceAutoLaunchPolicyReportsAlreadyRunningAndDebouncesRepeatedLaunches() {
        let detection = DeviceDetector.detect([
            DeviceSnapshot(vendorId: 0x2E8A, productId: 0x4002)
        ])
        let policy = DeviceAutoLaunchPolicy(debounce: 5)
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            policy.evaluate(detection: detection, isGuiAlreadyRunning: true, now: now).action,
            .alreadyRunning)
        XCTAssertEqual(
            policy.evaluate(detection: detection, isGuiAlreadyRunning: false, now: now).action,
            .launch)
        XCTAssertEqual(
            policy.evaluate(detection: detection, isGuiAlreadyRunning: false, now: now.addingTimeInterval(2)).action,
            .debounced)
    }

    func testDeviceWatcherInstallerBuildsPerUserLaunchAgentWithoutSudo() throws {
        let directory = temporaryDirectory()
        let watcher = try createExecutable(named: "VibestickDeviceWatcher", in: directory)
        let app = directory.appendingPathComponent("Vibestick.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist = directory.appendingPathComponent("com.pzy.vibestick.device-watcher.plist")
        let runner = FakeRunner()
        runner.forcedResult = CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        let installer = MacDeviceWatcherInstaller(
            paths: DeviceWatcherInstallPaths(
                watcherExecutablePath: watcher.path,
                appPath: app.path,
                plistPath: plist.path,
                logPath: directory.appendingPathComponent("watcher.log").path,
                errorLogPath: directory.appendingPathComponent("watcher.err").path),
            runner: runner,
            userId: 501)

        let result = try installer.install()

        XCTAssertEqual(result.plistPath, plist.path)
        let data = try Data(contentsOf: plist)
        let plistObject = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plistObject["Label"] as? String, "com.pzy.vibestick.device-watcher")
        XCTAssertEqual(plistObject["ProgramArguments"] as? [String], [watcher.path, "--app-path", app.path])
        XCTAssertEqual(plistObject["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plistObject["KeepAlive"] as? Bool, true)
        XCTAssertTrue(runner.invocations.contains(["/bin/launchctl", "bootstrap", "gui/501", plist.path]))
        XCTAssertTrue(runner.invocations.contains(["/bin/launchctl", "enable", "gui/501/com.pzy.vibestick.device-watcher"]))
        XCTAssertFalse(runner.invocations.contains { $0.contains("sudo") })
    }

    func testDeviceWatcherDefaultPathsPreferWatcherInsideConfiguredAppBundle() throws {
        let directory = temporaryDirectory()
        let appMacOS = directory
            .appendingPathComponent("Vibestick.app", isDirectory: true)
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: appMacOS, withIntermediateDirectories: true)
        let watcher = try createExecutable(named: "VibestickDeviceWatcher", in: appMacOS)

        let paths = DeviceWatcherInstallPaths.resolvedDefault(
            appPath: directory.appendingPathComponent("Vibestick.app").path)

        XCTAssertEqual(paths.watcherExecutablePath, watcher.path)
    }

    func testVibestickAppLauncherFocusesRunningAppAndOpensMissingProcess() throws {
        let directory = temporaryDirectory()
        let app = directory.appendingPathComponent("Vibestick.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let runningController = FakeApplicationController(isRunning: true)
        let runningLauncher = VibestickAppLauncher(appPath: app.path, controller: runningController)

        let focusResult = runningLauncher.launchOrFocus()

        XCTAssertEqual(focusResult.action, .focused)
        XCTAssertEqual(runningController.openedApps, [])
        XCTAssertEqual(runningController.activatedBundleIdentifiers, [VibestickPaths.bundleIdentifier])

        let stoppedController = FakeApplicationController(isRunning: false)
        let stoppedLauncher = VibestickAppLauncher(appPath: app.path, controller: stoppedController)

        let openResult = stoppedLauncher.launchOrFocus()

        XCTAssertEqual(openResult.action, .opened)
        XCTAssertEqual(stoppedController.openedApps, [app.path])
        XCTAssertEqual(stoppedController.openedArguments, [["--device-auto-start"]])
    }

    private var samplePmset: String {
        """
        Battery Power:
         lowpowermode         0
         standby              1
         lessbright           1
         disksleep            10
         sleep                1
        AC Power:
         lowpowermode         0
         standby              1
         disksleep            0
         sleep                0
        """
    }

    private var sampleCapabilities: String {
        """
        Capabilities for AC Power:
         displaysleep
         disksleep
         sleep
         standby
         lowpowermode
         lessbright
        """
    }

    private func temporaryStatePath() -> URL {
        temporaryDirectory().appendingPathComponent("power-state.json")
    }

    private func temporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VibestickMacTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func coderStatus(
        agent: String = "codex",
        phase: CoderAgentPhase = .reasoning,
        message: String? = nil,
        updatedAtUtc: Date = Date(),
        sessionId: String? = nil,
        taskSummary: String? = nil
    ) -> CoderAgentStatus {
        CoderAgentStatus(
            agent: agent,
            phase: phase,
            message: message,
            workspace: nil,
            processId: nil,
            updatedAtUtc: updatedAtUtc,
            ttlSeconds: 120,
            sessionId: sessionId,
            taskSummary: taskSummary,
            sourcePath: nil,
            taskDetail: nil)
    }

    private func createExecutable(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @discardableResult
    private func writeCodexSession(sessionsRoot: URL, modifiedAt: Date, contents: String) throws -> URL {
        let sessionDay = sessionsRoot
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("05", isDirectory: true)
            .appendingPathComponent("19", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDay, withIntermediateDirectories: true)
        let path = sessionDay.appendingPathComponent("rollout-2026-05-19T10-00-00-test.jsonl")
        try contents.appending("\n").write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: path.path)
        return path
    }

    private func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private final class FakeRunner: CommandRunning, @unchecked Sendable {
    var customOutput = ""
    var capOutput = ""
    var invocations: [[String]] = []
    var forcedResult: CommandResult?
    var onRun: ((String, [String]) throws -> CommandResult)?

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        invocations.append([executable] + arguments)
        if let onRun {
            return try onRun(executable, arguments)
        }
        if let forcedResult {
            return forcedResult
        }
        if executable == "/usr/bin/pmset", arguments == ["-g", "custom"] {
            return CommandResult(exitCode: 0, standardOutput: customOutput, standardError: "")
        }
        if executable == "/usr/bin/pmset", arguments == ["-g", "cap"] {
            return CommandResult(exitCode: 0, standardOutput: capOutput, standardError: "")
        }
        if executable == "/usr/bin/pmset", arguments.first?.hasPrefix("-") == true {
            return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        return CommandResult(exitCode: 1, standardOutput: "", standardError: "unexpected command")
    }
}

private final class FakeApplicationController: MacApplicationControlling, @unchecked Sendable {
    var isRunning: Bool
    var activatedBundleIdentifiers: [String] = []
    var openedApps: [String] = []
    var openedArguments: [[String]] = []

    init(isRunning: Bool) {
        self.isRunning = isRunning
    }

    func isApplicationRunning(bundleIdentifier: String) -> Bool {
        isRunning
    }

    func activateApplication(bundleIdentifier: String) -> Bool {
        activatedBundleIdentifiers.append(bundleIdentifier)
        return true
    }

    func openApplication(at appPath: String, arguments: [String]) throws {
        openedApps.append(appPath)
        openedArguments.append(arguments)
    }
}

private func extractStagedDirectory(from value: String) -> String? {
    guard let prefixRange = value.range(of: "/private/tmp/VibestickHelperInstall-") else {
        return nil
    }
    let suffix = value[prefixRange.lowerBound...]
    guard let slash = suffix.dropFirst("/private/tmp/VibestickHelperInstall-".count).firstIndex(of: "/") else {
        return String(suffix)
    }
    return String(suffix[..<slash])
}

private final class FakeHelperClient: HelperClienting, @unchecked Sendable {
    let helperPath: String
    var statusResult: Result<HelperStatus, Error>

    init(helperPath: String, statusResult: Result<HelperStatus, Error>) {
        self.helperPath = helperPath
        self.statusResult = statusResult
    }

    func status() throws -> HelperStatus {
        try statusResult.get()
    }

    func applyOn() throws -> ModeChangeResult {
        ModeChangeResult(requestedMode: .on, appliedMode: .on, restorePending: true, message: "on")
    }

    func applyHyper() throws -> ModeChangeResult {
        ModeChangeResult(requestedMode: .hyper, appliedMode: .hyper, restorePending: true, message: "hyper")
    }

    func restore() throws -> ModeChangeResult {
        ModeChangeResult(requestedMode: .off, appliedMode: .off, restorePending: false, message: "off")
    }
}

private final class FakeBatteryMonitor: BatteryMonitoring, @unchecked Sendable {
    func getBatteryInfo() -> BatteryInfo {
        BatteryInfo(percentage: 80, isACConnected: true, isAvailable: true)
    }
}

private final class FakeProcessInspector: ProcessInspecting, @unchecked Sendable {
    let tasks: [LongTaskProcess]

    init(tasks: [LongTaskProcess] = []) {
        self.tasks = tasks
    }

    func getLongTasks(whitelist: [String]) -> [LongTaskProcess] {
        tasks.filter { task in
            whitelist.contains { MacProcessInspector.normalize($0) == MacProcessInspector.normalize(task.name) }
        }
    }
}

private final class FakeAssertionManager: SleepAssertionManaging, @unchecked Sendable {
    func beginHyperAssertion() throws {}
    func endHyperAssertion() {}
    func isVibestickAssertionActive() -> Bool { false }
}

private struct StaticCoderStatusSource: CoderStatusSourcing {
    let statuses: [CoderAgentStatus]

    func getStatuses(now: Date) -> [CoderAgentStatus] {
        statuses
    }
}
