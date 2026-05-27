import Foundation
import VibestickMacCore

let args = Array(CommandLine.arguments.dropFirst())
let json = hasFlag("--json")
let statusDirectory = option("--status-dir").map { URL(fileURLWithPath: $0) }
let codexSessionsDirectory = option("--codex-sessions-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? CodexSessionPaths.defaultSessionsRoot

let options = VibestickOptions()
let runner = ProcessCommandRunner()
let helper = SubprocessHelperClient(runner: runner)
let battery = MacBatteryMonitor(runner: runner)
let processInspector = MacProcessInspector(runner: runner)
let assertionManager = MacSleepAssertionManager(runner: runner)
let engine = VibestickMacEngine(
    helper: helper,
    battery: battery,
    processInspector: processInspector,
    assertionManager: assertionManager,
    options: options)
let doctor = MacDoctorService(
    helper: helper,
    battery: battery,
    processInspector: processInspector,
    assertionManager: assertionManager,
    options: options)
let coderDirectory = statusDirectory ?? VibestickPaths.coderStatusDirectory
let coderSource = CompositeCoderStatusSource([
    JsonFileCoderStatusSource(directory: coderDirectory),
    CodexSessionStatusSource(sessionsRoot: codexSessionsDirectory),
    ProcessCoderStatusSource(processInspector: processInspector, processNames: options.longTaskProcessNames)
])
let coderWriter = CoderStatusWriter(directory: coderDirectory)
let petResolver = PetStateResolver()

do {
    let exitCode = try run()
    exit(exitCode)
} catch {
    if json {
        writeJSON(ErrorResponse(ok: false, error: error.localizedDescription))
    } else {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    }
    exit(3)
}

func run() throws -> Int32 {
    guard let command = args.first, !["--help", "-h"].contains(command) else {
        printHelp()
        return 0
    }

    switch command.lowercased() {
    case "status":
        let status = engine.status()
        json ? writeJSON(status) : printStatus(status)
        return status.warnings.isEmpty ? 0 : 2

    case "doctor":
        let report = doctor.run()
        json ? writeJSON(report) : printDoctor(report)
        return report.isHealthy ? 0 : 2

    case "mode":
        guard args.count >= 2, let mode = VibestickMode(rawValue: args[1].lowercased()) else {
            throw ValidationError("Missing mode. Expected: off, on, hyper.")
        }
        let result = try engine.applyMode(mode)
        json ? writeJSON(result) : printModeResult(result)
        if mode == .hyper && result.appliedMode == .hyper && !hasFlag("--once") && !json {
            return try runHyperGuard()
        }
        return 0

    case "revert":
        let result = try engine.revert()
        json ? writeJSON(result) : printModeResult(result)
        return 0

    case "pet":
        return try runPet()

    case "coder":
        return try runCoder()

    default:
        throw ValidationError("Unknown command '\(command)'.")
    }
}

func runHyperGuard() throws -> Int32 {
    try assertionManager.beginHyperAssertion()
    print("HYPER guard is running. Mac wake priority is held by Vibestick.")
    print("Press Ctrl+C to stop the guard. Vibestick will restore ON policy state.")
    signal(SIGINT) { _ in
        exit(0)
    }
    while true {
        Thread.sleep(forTimeInterval: TimeInterval(options.hyperGuardIntervalSeconds))
    }
}

func runPet() throws -> Int32 {
    guard args.count >= 2, args[1].lowercased() == "status" else {
        throw ValidationError("Missing pet command. Expected: pet status [--json].")
    }
    let status = engine.status()
    let coders = coderSource.getStatuses(now: Date())
    let pet = petResolver.resolve(status: status, coders: coders)
    if json {
        writeJSON(PetStatusResponse(ok: true, statusDirectory: coderDirectory.path, pet: pet))
    } else {
        print("Vibestick pet")
        print("Mood:      \(pet.mood)")
        print("Title:     \(pet.title)")
        print("Message:   \(pet.message)")
        print("Coders:    \(pet.coders.isEmpty ? "-" : pet.coders.map { "\($0.agent):\($0.phase.rawValue)" }.joined(separator: ", "))")
    }
    return 0
}

func runCoder() throws -> Int32 {
    guard args.count >= 2 else {
        throw ValidationError("Missing coder command. Expected: coder emit|clear.")
    }

    switch args[1].lowercased() {
    case "emit":
        guard let phaseValue = option("--phase"), let phase = parsePhase(phaseValue) else {
            throw ValidationError("Missing or invalid --phase.")
        }
        let status = try coderWriter.emit(
            agent: option("--agent") ?? "codex",
            phase: phase,
            message: option("--message"),
            workspace: option("--workspace"),
            processId: option("--pid").flatMap(Int32.init),
            ttlSeconds: option("--ttl").flatMap(Int.init),
            sessionId: option("--session-id"),
            taskSummary: option("--summary"),
            sourcePath: option("--source-path"),
            taskDetail: option("--detail"))
        if json {
            writeJSON(CoderEmitResponse(ok: true, statusDirectory: coderDirectory.path, status: status))
        } else {
            print("Emitted \(status.agent):\(status.phase.rawValue) to \(coderDirectory.path).")
        }
        return 0

    case "clear":
        let deleted = try coderWriter.clear(agent: option("--agent"))
        if json {
            writeJSON(CoderClearResponse(ok: true, deleted: deleted, statusDirectory: coderDirectory.path))
        } else {
            print("Cleared \(deleted) coder status file(s).")
        }
        return 0

    default:
        throw ValidationError("Unknown coder command '\(args[1])'. Expected: emit, clear.")
    }
}

func printStatus(_ status: VibestickStatus) {
    print("Vibestick Mac")
    print("Mode:             \(status.activeMode.rawValue)")
    print("Restore pending:  \(yesNo(status.restorePending))")
    print("Assertion active: \(yesNo(status.assertionActive))")
    print("Battery:          \(formatBattery(status.battery))")
    print("Long tasks:       \(status.longTasks.isEmpty ? "-" : status.longTasks.map { "\($0.name)(\($0.processId.map(String.init) ?? "?"))" }.joined(separator: ", "))")
    if let pmset = status.pmset {
        print("pmset sleep:      battery=\(pmset.value("sleep", source: .battery) ?? "-"), ac=\(pmset.value("sleep", source: .ac) ?? "-")")
    }
    for warning in status.warnings {
        print("Warning: \(warning)")
    }
}

func printDoctor(_ report: DoctorReport) {
    print("Vibestick Mac doctor")
    for check in report.checks {
        print("\(check.passed ? "OK " : "ERR") \(check.name.padding(toLength: 15, withPad: " ", startingAt: 0)) \(check.message)")
    }
}

func printModeResult(_ result: ModeChangeResult) {
    print(result.message)
    print("Requested:        \(result.requestedMode.rawValue)")
    print("Applied:          \(result.appliedMode.rawValue)")
    print("Restore pending:  \(yesNo(result.restorePending))")
    for warning in result.warnings {
        print("Warning: \(warning)")
    }
}

func printHelp() {
    print("""
    Vibestick Mac

    Usage:
      vibestickctl status [--json]
      vibestickctl doctor [--json]
      vibestickctl mode off|on|hyper [--json] [--once]
      vibestickctl revert [--json]
      vibestickctl pet status [--json] [--status-dir <path>] [--codex-sessions-dir <path>]
      vibestickctl coder emit --phase <phase> [--agent <name>] [--message <text>] [--workspace <path>] [--pid <id>] [--ttl <seconds>] [--session-id <id>] [--summary <text>] [--detail <text>] [--source-path <path>] [--json] [--status-dir <path>]
      vibestickctl coder clear [--agent <name>] [--json] [--status-dir <path>]
    """)
}

func hasFlag(_ flag: String) -> Bool {
    args.contains { $0.caseInsensitiveCompare(flag) == .orderedSame }
}

func option(_ name: String) -> String? {
    for index in 0..<(args.count - 1) where args[index].caseInsensitiveCompare(name) == .orderedSame {
        return args[index + 1]
    }
    return nil
}

func parsePhase(_ value: String) -> CoderAgentPhase? {
    let normalized = value.replacingOccurrences(of: "-", with: "_").lowercased()
    return CoderAgentPhase.allCases.first { $0.rawValue == normalized }
}

func formatBattery(_ battery: BatteryInfo) -> String {
    guard battery.isAvailable else {
        return "unavailable"
    }
    return "\(battery.percentage.map { "\($0)%" } ?? "unknown"), AC connected=\(yesNo(battery.isACConnected))"
}

func yesNo(_ value: Bool) -> String {
    value ? "yes" : "no"
}

func writeJSON<T: Encodable>(_ value: T) {
    let data = try! VibestickJSON.encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

struct ValidationError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

struct ErrorResponse: Encodable {
    let ok: Bool
    let error: String
}

struct PetStatusResponse: Encodable {
    let ok: Bool
    let statusDirectory: String
    let pet: PetState
}

struct CoderEmitResponse: Encodable {
    let ok: Bool
    let statusDirectory: String
    let status: CoderAgentStatus
}

struct CoderClearResponse: Encodable {
    let ok: Bool
    let deleted: Int
    let statusDirectory: String
}
