import Foundation

public enum VibestickMode: String, Codable, Sendable {
    case off
    case on
    case hyper
}

public struct CommandResult: Codable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public struct BatteryInfo: Codable, Equatable, Sendable {
    public let percentage: Int?
    public let isACConnected: Bool
    public let isAvailable: Bool
    public let chargeRateInMilliwatts: Int?
    public let estimatedTimeToFullSeconds: Int?

    public init(
        percentage: Int?,
        isACConnected: Bool,
        isAvailable: Bool,
        chargeRateInMilliwatts: Int? = nil,
        estimatedTimeToFullSeconds: Int? = nil
    ) {
        self.percentage = percentage
        self.isACConnected = isACConnected
        self.isAvailable = isAvailable
        self.chargeRateInMilliwatts = chargeRateInMilliwatts
        self.estimatedTimeToFullSeconds = estimatedTimeToFullSeconds
    }
}

public struct DoctorCheck: Codable, Equatable, Sendable {
    public let name: String
    public let passed: Bool
    public let message: String

    public init(_ name: String, _ passed: Bool, _ message: String) {
        self.name = name
        self.passed = passed
        self.message = message
    }
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public let isHealthy: Bool
    public let checks: [DoctorCheck]

    public init(checks: [DoctorCheck]) {
        self.checks = checks
        self.isHealthy = checks.allSatisfy(\.passed)
    }
}

public struct ModeChangeResult: Codable, Equatable, Sendable {
    public let requestedMode: VibestickMode
    public let appliedMode: VibestickMode
    public let restorePending: Bool
    public let warnings: [String]
    public let message: String

    public init(
        requestedMode: VibestickMode,
        appliedMode: VibestickMode,
        restorePending: Bool,
        warnings: [String] = [],
        message: String
    ) {
        self.requestedMode = requestedMode
        self.appliedMode = appliedMode
        self.restorePending = restorePending
        self.warnings = warnings
        self.message = message
    }
}

public struct VibestickStatus: Codable, Equatable, Sendable {
    public let activeMode: VibestickMode
    public let restorePending: Bool
    public let pmset: PmsetSnapshot?
    public let battery: BatteryInfo
    public let longTasks: [LongTaskProcess]
    public let assertionActive: Bool
    public let warnings: [String]

    public init(
        activeMode: VibestickMode,
        restorePending: Bool,
        pmset: PmsetSnapshot?,
        battery: BatteryInfo,
        longTasks: [LongTaskProcess],
        assertionActive: Bool,
        warnings: [String] = []
    ) {
        self.activeMode = activeMode
        self.restorePending = restorePending
        self.pmset = pmset
        self.battery = battery
        self.longTasks = longTasks
        self.assertionActive = assertionActive
        self.warnings = warnings
    }
}

public struct LongTaskProcess: Codable, Equatable, Sendable {
    public let processId: Int32?
    public let name: String

    public init(processId: Int32?, name: String) {
        self.processId = processId
        self.name = name
    }
}

public enum CoderAgentPhase: String, Codable, CaseIterable, Sendable {
    case idle
    case sleeping
    case running
    case reasoning
    case toolCalling = "tool_calling"
    case waitingAuthorization = "waiting_authorization"
    case error
    case success
    case offline
    case unknown
}

public struct CoderAgentStatus: Codable, Equatable, Sendable {
    public let agent: String
    public let phase: CoderAgentPhase
    public let message: String?
    public let workspace: String?
    public let processId: Int32?
    public let updatedAtUtc: Date
    public let ttlSeconds: Int?
    public let sessionId: String?
    public let taskSummary: String?
    public let sourcePath: String?
    public let taskDetail: String?

    public var identity: String {
        let cleanAgent = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        let identityAgent = cleanAgent.isEmpty ? "coder" : cleanAgent
        guard let sessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty
        else {
            return identityAgent
        }
        return "\(identityAgent):\(sessionId)"
    }

    public init(
        agent: String,
        phase: CoderAgentPhase,
        message: String?,
        workspace: String?,
        processId: Int32?,
        updatedAtUtc: Date,
        ttlSeconds: Int?,
        sessionId: String? = nil,
        taskSummary: String? = nil,
        sourcePath: String? = nil,
        taskDetail: String? = nil
    ) {
        self.agent = agent
        self.phase = phase
        self.message = message
        self.workspace = workspace
        self.processId = processId
        self.updatedAtUtc = updatedAtUtc
        self.ttlSeconds = ttlSeconds
        self.sessionId = sessionId
        self.taskSummary = taskSummary
        self.sourcePath = sourcePath
        self.taskDetail = taskDetail
    }
}

public struct PetState: Codable, Equatable, Sendable {
    public let mood: String
    public let title: String
    public let message: String
    public let coders: [CoderAgentStatus]
}

public struct VibestickOptions: Sendable {
    public let longTaskProcessNames: [String]
    public let hyperGuardIntervalSeconds: UInt64

    public init(
        longTaskProcessNames: [String] = [
            "cargo", "pytest", "docker", "uv", "npm", "pnpm",
            "claude", "claude-code", "codex", "hermes", "nanobot",
            "openclaw", "openclaw-cli", "openclaw-doctor", "opencode", "openhands"
        ],
        hyperGuardIntervalSeconds: UInt64 = 30
    ) {
        self.longTaskProcessNames = longTaskProcessNames
        self.hyperGuardIntervalSeconds = hyperGuardIntervalSeconds
    }
}
