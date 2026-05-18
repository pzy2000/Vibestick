import Foundation
import Darwin

public enum PowerSource: String, Codable, CaseIterable, Sendable {
    case battery = "Battery Power"
    case ac = "AC Power"

    public var pmsetFlag: String {
        switch self {
        case .battery: "-b"
        case .ac: "-c"
        }
    }
}

public struct PmsetSnapshot: Codable, Equatable, Sendable {
    public var settings: [PowerSource: [String: String]]

    public init(settings: [PowerSource: [String: String]]) {
        self.settings = settings
    }

    public func value(_ key: String, source: PowerSource) -> String? {
        settings[source]?[key]
    }

    private enum CodingKeys: String, CodingKey {
        case batteryPower
        case acPower
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        settings = [
            .battery: try container.decodeIfPresent([String: String].self, forKey: .batteryPower) ?? [:],
            .ac: try container.decodeIfPresent([String: String].self, forKey: .acPower) ?? [:]
        ]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(settings[.battery] ?? [:], forKey: .batteryPower)
        try container.encode(settings[.ac] ?? [:], forKey: .acPower)
    }
}

public enum PmsetParser {
    public static func parseCustom(_ text: String) -> PmsetSnapshot {
        var settings: [PowerSource: [String: String]] = [:]
        var currentSource: PowerSource?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }

            if let source = PowerSource(rawValue: trimmed.replacingOccurrences(of: ":", with: "")) {
                currentSource = source
                settings[source, default: [:]] = settings[source, default: [:]]
                continue
            }

            guard let currentSource else {
                continue
            }

            let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else {
                continue
            }

            settings[currentSource, default: [:]][String(parts[0])] = String(parts[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return PmsetSnapshot(settings: settings)
    }

    public static func parseCapabilities(_ text: String) -> Set<String> {
        Set(text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Capabilities") })
    }
}

public struct PowerStateBackup: Codable, Equatable, Sendable {
    public var activeMode: VibestickMode
    public var originalSnapshot: PmsetSnapshot
    public var affectedKeys: [String]
    public var updatedAtUtc: Date

    public init(
        activeMode: VibestickMode,
        originalSnapshot: PmsetSnapshot,
        affectedKeys: [String],
        updatedAtUtc: Date = Date()
    ) {
        self.activeMode = activeMode
        self.originalSnapshot = originalSnapshot
        self.affectedKeys = affectedKeys
        self.updatedAtUtc = updatedAtUtc
    }
}

public protocol PowerPolicyManaging: Sendable {
    func readSnapshot() throws -> PmsetSnapshot
    func readCapabilities() throws -> Set<String>
    func readBackup() throws -> PowerStateBackup?
    func applyOn() throws -> ModeChangeResult
    func applyHyper() throws -> ModeChangeResult
    func restore() throws -> ModeChangeResult
}

public enum PowerPolicyError: Error, LocalizedError, Equatable {
    case privilegedHelperRequired(statePath: String)

    public var errorDescription: String? {
        switch self {
        case .privilegedHelperRequired(let statePath):
            return "Mac power policy changes require the privileged Vibestick helper. Install it with 'macos/scripts/install-helper.sh' or run the helper as root. State path: \(statePath)"
        }
    }
}

public final class PmsetPowerPolicyManager: PowerPolicyManaging, @unchecked Sendable {
    private let runner: CommandRunning
    public let statePath: URL
    private let requiresRootForMutations: Bool

    public init(
        runner: CommandRunning = ProcessCommandRunner(),
        statePath: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VIBESTICK_HELPER_STATE_PATH"] ?? VibestickPaths.helperStatePath),
        requiresRootForMutations: Bool? = nil
    ) {
        self.runner = runner
        self.statePath = statePath
        self.requiresRootForMutations = requiresRootForMutations ?? statePath.path.hasPrefix("/Library/")
    }

    public func readSnapshot() throws -> PmsetSnapshot {
        let result = try runner.runChecked("/usr/bin/pmset", ["-g", "custom"])
        return PmsetParser.parseCustom(result.standardOutput)
    }

    public func readCapabilities() throws -> Set<String> {
        let result = try runner.runChecked("/usr/bin/pmset", ["-g", "cap"])
        return PmsetParser.parseCapabilities(result.standardOutput)
    }

    public func readBackup() throws -> PowerStateBackup? {
        guard FileManager.default.fileExists(atPath: statePath.path) else {
            return nil
        }
        let data = try Data(contentsOf: statePath)
        return try VibestickJSON.decoder.decode(PowerStateBackup.self, from: data)
    }

    public func applyOn() throws -> ModeChangeResult {
        try ensureCanMutateSystemPolicy()
        return try apply(mode: .on, settings: ["sleep": "0"])
    }

    public func applyHyper() throws -> ModeChangeResult {
        try ensureCanMutateSystemPolicy()
        let capabilities = try readCapabilities()
        var settings = ["sleep": "0"]
        for key in ["lowpowermode", "lessbright", "standby", "disksleep"] where capabilities.contains(key) {
            settings[key] = "0"
        }
        return try apply(mode: .hyper, settings: settings)
    }

    public func restore() throws -> ModeChangeResult {
        try ensureCanMutateSystemPolicy()
        guard let backup = try readBackup() else {
            return ModeChangeResult(
                requestedMode: .off,
                appliedMode: .off,
                restorePending: false,
                message: "No Mac power policy restore was pending.")
        }

        try restoreBackup(backup)
        try? FileManager.default.removeItem(at: statePath)
        return ModeChangeResult(
            requestedMode: .off,
            appliedMode: .off,
            restorePending: false,
            message: "Original Mac power policy restored.")
    }

    private func apply(mode: VibestickMode, settings: [String: String]) throws -> ModeChangeResult {
        let current = try readSnapshot()
        let existingBackup = try readBackup()
        if mode == .on, let existingBackup, existingBackup.activeMode == .hyper {
            try restoreBackup(existingBackup)
        }

        let baseBackup = mode == .on && existingBackup?.activeMode == .hyper
            ? nil
            : existingBackup
        let backup = baseBackup ?? PowerStateBackup(
            activeMode: mode,
            originalSnapshot: existingBackup?.originalSnapshot ?? current,
            affectedKeys: Array(settings.keys).sorted())
        let affectedKeys = mode == .on
            ? Array(settings.keys).sorted()
            : Array(Set(backup.affectedKeys + settings.keys)).sorted()
        try saveBackup(backup.withMode(mode, affectedKeys: affectedKeys))

        do {
            try runPmset("-a", settings)
        } catch {
            if existingBackup == nil {
                try? restoreBackup(backup)
                try? FileManager.default.removeItem(at: statePath)
            }
            throw error
        }

        return ModeChangeResult(
            requestedMode: mode,
            appliedMode: mode,
            restorePending: true,
            message: mode == .hyper
                ? "HYPER mode applied. Vibestick will keep wake priority while the guard is running."
                : "ON mode applied. Mac system sleep policy is controlled by Vibestick.")
    }

    private func restoreBackup(_ backup: PowerStateBackup) throws {
        for source in PowerSource.allCases {
            let sourceSettings = backup.originalSnapshot.settings[source] ?? [:]
            var restoreSettings: [String: String] = [:]
            for key in backup.affectedKeys {
                if let value = sourceSettings[key] {
                    restoreSettings[key] = value
                }
            }
            if !restoreSettings.isEmpty {
                try runPmset(source.pmsetFlag, restoreSettings)
            }
        }
    }

    private func runPmset(_ scopeFlag: String, _ settings: [String: String]) throws {
        let arguments = [scopeFlag] + settings
            .sorted { $0.key < $1.key }
            .flatMap { [$0.key, $0.value] }
        _ = try runner.runChecked("/usr/bin/pmset", arguments)
    }

    private func saveBackup(_ backup: PowerStateBackup) throws {
        try FileManager.default.createDirectory(
            at: statePath.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try VibestickJSON.encoder.encode(backup)
        try data.write(to: statePath, options: [.atomic])
    }

    private func ensureCanMutateSystemPolicy() throws {
        if requiresRootForMutations && geteuid() != 0 {
            throw PowerPolicyError.privilegedHelperRequired(statePath: statePath.path)
        }
    }
}

private extension PowerStateBackup {
    func withMode(_ mode: VibestickMode, affectedKeys: [String]) -> PowerStateBackup {
        PowerStateBackup(
            activeMode: mode,
            originalSnapshot: originalSnapshot,
            affectedKeys: affectedKeys,
            updatedAtUtc: Date())
    }
}
