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
}

private final class FakeRunner: CommandRunning, @unchecked Sendable {
    var customOutput = ""
    var capOutput = ""
    var invocations: [[String]] = []
    var forcedResult: CommandResult?

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        invocations.append([executable] + arguments)
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
