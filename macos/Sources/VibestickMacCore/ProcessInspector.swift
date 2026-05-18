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
        guard let result = try? runner.runChecked("/bin/ps", ["-axo", "pid=,comm="]) else {
            return []
        }

        var byName: [String: LongTaskProcess] = [:]
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let pid = Int32(parts[0]) else {
                continue
            }
            let name = URL(fileURLWithPath: String(parts[1])).deletingPathExtension().lastPathComponent
            let normalized = Self.normalize(name)
            if whitelist.contains(where: { Self.normalize($0) == normalized }), byName[normalized] == nil {
                byName[normalized] = LongTaskProcess(processId: pid, name: name)
            }
        }

        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func normalize(_ processName: String) -> String {
        var name = processName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasSuffix(".exe") {
            name.removeLast(4)
        }
        return name
    }
}
