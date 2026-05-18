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

    public init(
        helperPath: String = ProcessInfo.processInfo.environment["VIBESTICK_HELPER_PATH"]
            ?? VibestickPaths.installedHelperPath,
        runner: CommandRunning = ProcessCommandRunner()
    ) {
        self.helperPath = helperPath
        self.runner = runner
    }

    public func status() throws -> HelperStatus {
        try runJSON(["--json", "status"], as: HelperStatus.self)
    }

    public func applyOn() throws -> ModeChangeResult {
        try runJSON(["--json", "apply-on"], as: ModeChangeResult.self)
    }

    public func applyHyper() throws -> ModeChangeResult {
        try runJSON(["--json", "apply-hyper"], as: ModeChangeResult.self)
    }

    public func restore() throws -> ModeChangeResult {
        try runJSON(["--json", "restore"], as: ModeChangeResult.self)
    }

    private func runJSON<T: Decodable>(_ arguments: [String], as type: T.Type) throws -> T {
        do {
            let result = try runner.runChecked(helperPath, arguments)
            return try VibestickJSON.decoder.decode(type, from: Data(result.standardOutput.utf8))
        } catch CommandRunError.nonZero(let result) {
            if let status = try? VibestickJSON.decoder.decode(HelperStatus.self, from: Data(result.standardOutput.utf8)),
               let message = status.message {
                throw HelperClientError.helperFailed(message)
            }
            throw CommandRunError.nonZero(result)
        }
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
