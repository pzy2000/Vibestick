import Foundation

public protocol CoderStatusSourcing: Sendable {
    func getStatuses(now: Date) -> [CoderAgentStatus]
}

public final class JsonFileCoderStatusSource: CoderStatusSourcing, @unchecked Sendable {
    public static let defaultTTLSeconds = 120
    private let directory: URL

    public init(directory: URL = VibestickPaths.coderStatusDirectory) {
        self.directory = directory
    }

    public func getStatuses(now: Date = Date()) -> [CoderAgentStatus] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> CoderAgentStatus? in
                guard let data = try? Data(contentsOf: url),
                      let status = try? VibestickJSON.decoder.decode(CoderAgentStatus.self, from: data),
                      !Self.isStale(status, now: now)
                else {
                    return nil
                }
                return status
            }
            .sorted { lhs, rhs in
                if phasePriority(lhs.phase) != phasePriority(rhs.phase) {
                    return phasePriority(lhs.phase) < phasePriority(rhs.phase)
                }
                return lhs.updatedAtUtc > rhs.updatedAtUtc
            }
    }

    public static func isStale(_ status: CoderAgentStatus, now: Date) -> Bool {
        let ttl = status.ttlSeconds ?? defaultTTLSeconds
        if ttl <= 0 {
            return false
        }
        return status.updatedAtUtc.addingTimeInterval(TimeInterval(ttl)) < now
    }
}

public final class CoderStatusWriter: @unchecked Sendable {
    public let directory: URL

    public init(directory: URL = VibestickPaths.coderStatusDirectory) {
        self.directory = directory
    }

    public func emit(
        agent: String,
        phase: CoderAgentPhase,
        message: String?,
        workspace: String?,
        processId: Int32?,
        ttlSeconds: Int?,
        sessionId: String?,
        taskSummary: String?,
        sourcePath: String?,
        taskDetail: String?
    ) throws -> CoderAgentStatus {
        let status = CoderAgentStatus(
            agent: agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "coder" : agent,
            phase: phase,
            message: clean(message),
            workspace: clean(workspace),
            processId: processId,
            updatedAtUtc: Date(),
            ttlSeconds: ttlSeconds,
            sessionId: clean(sessionId),
            taskSummary: clean(taskSummary),
            sourcePath: clean(sourcePath),
            taskDetail: clean(taskDetail))

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = statusPath(agent: status.agent, sessionId: status.sessionId)
        let data = try VibestickJSON.encoder.encode(status)
        try data.write(to: path, options: [.atomic])
        return status
    }

    public func clear(agent: String?) throws -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }

        var deleted = 0
        for file in files where file.pathExtension == "json" {
            if let agent, !file.deletingPathExtension().lastPathComponent.hasPrefix(Self.sanitize(agent)) {
                continue
            }
            try FileManager.default.removeItem(at: file)
            deleted += 1
        }
        return deleted
    }

    private func statusPath(agent: String, sessionId: String?) -> URL {
        let stem = sessionId.flatMap { "\(Self.sanitize(agent))-\(Self.sanitize($0))" } ?? Self.sanitize(agent)
        return directory.appendingPathComponent("\(stem).json")
    }

    public static func sanitize(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }
}

public final class ProcessCoderStatusSource: CoderStatusSourcing, @unchecked Sendable {
    private let processInspector: ProcessInspecting
    private let processNames: [String]

    public init(processInspector: ProcessInspecting, processNames: [String]) {
        self.processInspector = processInspector
        self.processNames = processNames
    }

    public func getStatuses(now: Date) -> [CoderAgentStatus] {
        processInspector.getLongTasks(whitelist: processNames).map { task in
            CoderAgentStatus(
                agent: task.name,
                phase: task.name.localizedCaseInsensitiveCompare("codex") == .orderedSame ? .sleeping : .running,
                message: task.name.localizedCaseInsensitiveCompare("codex") == .orderedSame
                    ? "No active Codex task is running."
                    : "Detected running coder process.",
                workspace: nil,
                processId: task.processId,
                updatedAtUtc: now,
                ttlSeconds: nil)
        }
    }
}

public final class CompositeCoderStatusSource: CoderStatusSourcing, @unchecked Sendable {
    private let sources: [CoderStatusSourcing]

    public init(_ sources: [CoderStatusSourcing]) {
        self.sources = sources
    }

    public func getStatuses(now: Date) -> [CoderAgentStatus] {
        var byIdentity: [String: CoderAgentStatus] = [:]
        for source in sources {
            if !byIdentity.isEmpty {
                break
            }

            let statuses = source.getStatuses(now: now)
            for status in statuses {
                if let existing = byIdentity[status.identity],
                   Self.compareStatus(status, existing) == false {
                    continue
                }
                byIdentity[status.identity] = status
            }
        }

        return byIdentity.values.sorted { lhs, rhs in
            if phasePriority(lhs.phase) != phasePriority(rhs.phase) {
                return phasePriority(lhs.phase) < phasePriority(rhs.phase)
            }
            if lhs.updatedAtUtc != rhs.updatedAtUtc {
                return lhs.updatedAtUtc > rhs.updatedAtUtc
            }
            return lhs.agent.localizedCaseInsensitiveCompare(rhs.agent) == .orderedAscending
        }
    }

    private static func compareStatus(_ lhs: CoderAgentStatus, _ rhs: CoderAgentStatus) -> Bool {
        if phasePriority(lhs.phase) != phasePriority(rhs.phase) {
            return phasePriority(lhs.phase) < phasePriority(rhs.phase)
        }
        return lhs.updatedAtUtc > rhs.updatedAtUtc
    }
}

public func phasePriority(_ phase: CoderAgentPhase) -> Int {
    switch phase {
    case .error: 0
    case .waitingAuthorization: 1
    case .toolCalling: 2
    case .reasoning, .running: 3
    case .success: 4
    case .sleeping, .idle: 5
    case .offline, .unknown: 6
    }
}

private func clean(_ value: String?) -> String? {
    guard let value else {
        return nil
    }
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? nil : cleaned
}
