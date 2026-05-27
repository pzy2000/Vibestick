import Foundation

public protocol ProcessInspecting: Sendable {
    func getLongTasks(whitelist: [String]) -> [LongTaskProcess]
}

public final class MacProcessInspector: ProcessInspecting, @unchecked Sendable {
    private let runner: CommandRunning

    public init(runner: CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func getLongTasks(whitelist: [String]) -> [LongTaskProcess] {
        guard let result = try? runner.runChecked("/bin/ps", ["-axo", "pid=,comm=,args="]) else {
            return []
        }

        var byName: [String: LongTaskProcess] = [:]
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard parts.count >= 2, let pid = Int32(parts[0]) else {
                continue
            }
            let name = URL(fileURLWithPath: String(parts[1])).deletingPathExtension().lastPathComponent
            let commandLine = parts.count == 3 ? String(parts[2]) : ""
            if let match = Self.matchProcessName(name, whitelist: whitelist), byName[match] == nil {
                byName[match] = LongTaskProcess(processId: pid, name: match)
            } else if let commandMatch = Self.matchCommandLine(processName: name, commandLine: commandLine, whitelist: whitelist),
                      byName[commandMatch] == nil {
                byName[commandMatch] = LongTaskProcess(processId: pid, name: commandMatch)
            }
        }

        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func normalize(_ processName: String) -> String {
        var name = processName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for suffix in [".exe", ".cmd", ".ps1"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        return name
    }

    private static let commandLineHostProcessNames = [
        "node", "python", "python3", "bun", "deno", "npm", "npx", "pnpm", "cmd", "powershell", "pwsh"
    ]

    private static let commandLineCoderAliases = [
        "claude", "claude-code", "opencode", "openclaw", "openclaw-cli", "openclaw-doctor", "hermes", "nanobot"
    ]

    private static func matchProcessName(_ processName: String, whitelist: [String]) -> String? {
        let normalized = normalize(processName)
        return whitelist.map(normalize).first { $0 == normalized }
    }

    private static func matchCommandLine(processName: String, commandLine: String, whitelist: [String]) -> String? {
        guard commandLineHostProcessNames.contains(normalize(processName)) else {
            return nil
        }

        for alias in commandLineCoderAliases where whitelist.map(normalize).contains(normalize(alias)) {
            if commandLineContainsAlias(commandLine, alias: alias) {
                return normalize(alias)
            }
        }

        return nil
    }

    private static func commandLineContainsAlias(_ commandLine: String, alias: String) -> Bool {
        let normalizedAlias = normalize(alias)
        for token in commandLine.split(whereSeparator: \.isWhitespace) {
            for candidate in tokenCandidates(String(token)) where normalize(candidate) == normalizedAlias {
                return true
            }
        }

        return false
    }

    private static func tokenCandidates(_ token: String) -> [String] {
        var candidates: [String] = []
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        for rawPart in trimmed.components(separatedBy: CharacterSet(charactersIn: "\\/=;")) {
            var candidate = rawPart.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if candidate.isEmpty {
                continue
            }

            if let versionSeparator = candidate.dropFirst().firstIndex(of: "@") {
                candidate = String(candidate[..<versionSeparator])
            }

            candidates.append(candidate)
            let withoutExtension = URL(fileURLWithPath: candidate).deletingPathExtension().lastPathComponent
            if !withoutExtension.isEmpty && withoutExtension.localizedCaseInsensitiveCompare(candidate) != .orderedSame {
                candidates.append(withoutExtension)
            }
        }

        return candidates
    }
}
