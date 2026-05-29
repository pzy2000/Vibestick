import Foundation

public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult
}

public enum CommandRunError: Error, LocalizedError {
    case failedToStart(String)
    case timedOut(String)
    case nonZero(CommandResult)

    public var errorDescription: String? {
        switch self {
        case .failedToStart(let executable):
            return "Failed to start \(executable)."
        case .timedOut(let executable):
            return "Command timed out: \(executable)."
        case .nonZero(let result):
            let detail = [result.standardOutput, result.standardError]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return "Command exited with \(result.exitCode). \(detail)"
        }
    }
}

public final class ProcessCommandRunner: CommandRunning, @unchecked Sendable {
    private let timeoutSeconds: TimeInterval?

    public init(timeoutSeconds: TimeInterval? = nil) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutCapture = PipeCapture()
        let stderrCapture = PipeCapture()
        let drainGroup = DispatchGroup()

        do {
            try process.run()
        } catch {
            throw CommandRunError.failedToStart(executable)
        }

        Self.drain(stdout, into: stdoutCapture, group: drainGroup)
        Self.drain(stderr, into: stderrCapture, group: drainGroup)

        if let timeoutSeconds {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }

            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                throw CommandRunError.timedOut(executable)
            }
        } else {
            process.waitUntilExit()
        }

        drainGroup.wait()

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(data: stdoutCapture.data, encoding: .utf8) ?? "",
            standardError: String(data: stderrCapture.data, encoding: .utf8) ?? "")
    }

    private static func drain(_ pipe: Pipe, into capture: PipeCapture, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            capture.set(pipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
    }
}

private final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }
}

public extension CommandRunning {
    func runChecked(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let result = try run(executable, arguments)
        if result.exitCode != 0 {
            throw CommandRunError.nonZero(result)
        }
        return result
    }
}
