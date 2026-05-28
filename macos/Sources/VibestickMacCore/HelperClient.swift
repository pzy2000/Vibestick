import Foundation

public struct HelperStatus: Codable, Equatable, Sendable {
    public let ok: Bool
    public let snapshot: PmsetSnapshot?
    public let backup: PowerStateBackup?
    public let statePath: String
    public let message: String?

    public init(
        ok: Bool,
        snapshot: PmsetSnapshot?,
        backup: PowerStateBackup?,
        statePath: String,
        message: String? = nil
    ) {
        self.ok = ok
        self.snapshot = snapshot
        self.backup = backup
        self.statePath = statePath
        self.message = message
    }
}

public protocol HelperClienting: Sendable {
    var helperPath: String { get }
    func status() throws -> HelperStatus
    func applyOn() throws -> ModeChangeResult
    func applyHyper() throws -> ModeChangeResult
    func restore() throws -> ModeChangeResult
}

public enum HelperClientError: Error, LocalizedError, Equatable {
    case helperFailed(String)

    public var errorDescription: String? {
        switch self {
        case .helperFailed(let message):
            return message
        }
    }
}

public final class SubprocessHelperClient: HelperClienting, @unchecked Sendable {
    public let helperPath: String
    private let runner: CommandRunning
    private let statusRunner: CommandRunning
    private let authorizeMutatingCommands: Bool

    public init(
        helperPath: String = ProcessInfo.processInfo.environment["VIBESTICK_HELPER_PATH"]
            ?? VibestickPaths.installedHelperPath,
        runner: CommandRunning = ProcessCommandRunner(),
        statusRunner: CommandRunning? = nil,
        authorizeMutatingCommands: Bool? = nil
    ) {
        self.helperPath = helperPath
        self.runner = runner
        self.statusRunner = statusRunner ?? runner
        if let authorizeMutatingCommands {
            self.authorizeMutatingCommands = authorizeMutatingCommands
        } else {
            self.authorizeMutatingCommands =
                ProcessInfo.processInfo.environment["VIBESTICK_HELPER_USE_ADMIN"] == "1"
                || helperPath == VibestickPaths.installedHelperPath
        }
    }

    public func status() throws -> HelperStatus {
        try runJSON(["--json", "status"], as: HelperStatus.self, requiresPrivilege: false, runner: statusRunner)
    }

    public func applyOn() throws -> ModeChangeResult {
        try runJSON(["--json", "apply-on"], as: ModeChangeResult.self, requiresPrivilege: true, runner: runner)
    }

    public func applyHyper() throws -> ModeChangeResult {
        try runJSON(["--json", "apply-hyper"], as: ModeChangeResult.self, requiresPrivilege: true, runner: runner)
    }

    public func restore() throws -> ModeChangeResult {
        try runJSON(["--json", "restore"], as: ModeChangeResult.self, requiresPrivilege: true, runner: runner)
    }

    private func runJSON<T: Decodable>(
        _ arguments: [String],
        as type: T.Type,
        requiresPrivilege: Bool,
        runner: CommandRunning
    ) throws -> T {
        do {
            let result = try runHelper(arguments: arguments, requiresPrivilege: requiresPrivilege, runner: runner)
            return try VibestickJSON.decoder.decode(type, from: Data(result.standardOutput.utf8))
        } catch CommandRunError.nonZero(let result) {
            if let status = try? VibestickJSON.decoder.decode(HelperStatus.self, from: Data(result.standardOutput.utf8)),
               let message = status.message {
                throw HelperClientError.helperFailed(message)
            }
            throw CommandRunError.nonZero(result)
        }
    }

    private func runHelper(arguments: [String], requiresPrivilege: Bool, runner: CommandRunning) throws -> CommandResult {
        if requiresPrivilege && authorizeMutatingCommands {
            let command = ([helperPath] + arguments)
                .map(Self.shellQuote)
                .joined(separator: " ")
            let appleScript = "do shell script \"\(Self.escapeAppleScriptString(command))\" with administrator privileges"
            return try runner.runChecked("/usr/bin/osascript", ["-e", appleScript])
        }

        return try runner.runChecked(helperPath, arguments)
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func escapeAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public final class DirectHelperClient: HelperClienting, @unchecked Sendable {
    public let helperPath = "direct"
    private let manager: PowerPolicyManaging

    public init(manager: PowerPolicyManaging) {
        self.manager = manager
    }

    public func status() throws -> HelperStatus {
        HelperStatus(
            ok: true,
            snapshot: try manager.readSnapshot(),
            backup: try manager.readBackup(),
            statePath: (manager as? PmsetPowerPolicyManager)?.statePath.path ?? VibestickPaths.helperStatePath)
    }

    public func applyOn() throws -> ModeChangeResult {
        try manager.applyOn()
    }

    public func applyHyper() throws -> ModeChangeResult {
        try manager.applyHyper()
    }

    public func restore() throws -> ModeChangeResult {
        try manager.restore()
    }
}
