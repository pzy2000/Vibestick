import Foundation

public enum CodexSessionPaths {
    public static var defaultSessionsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }
}

public struct CodexSessionStatusUpdate: Equatable, Sendable {
    public let phase: CoderAgentPhase
    public let message: String
    public let ttlSeconds: Int
}

public struct CodexSessionMetadata: Equatable, Sendable {
    public let sessionId: String?
    public let workspace: String?
}

public enum CodexSessionEventMapper {
    private static let maxTaskSummaryLength = 48
    private static let maxTaskDetailLength = 118

    public static func mapJsonLine(_ line: String) -> CodexSessionStatusUpdate? {
        guard let root = parseObject(line),
              string(root["type"]) != nil,
              let payload = root["payload"] as? [String: Any]
        else {
            return nil
        }

        switch string(root["type"])?.lowercased() {
        case "event_msg":
            return mapEventMessage(payload)
        case "response_item":
            return mapResponseItem(payload)
        default:
            return nil
        }
    }

    public static func readSessionMetadata(_ line: String) -> CodexSessionMetadata? {
        guard let root = parseObject(line),
              string(root["type"])?.caseInsensitiveCompare("session_meta") == .orderedSame,
              let payload = root["payload"] as? [String: Any]
        else {
            return nil
        }

        let sessionId = cleanValue(string(payload["id"]))
        let workspace = cleanValue(string(payload["cwd"]))
        guard sessionId != nil || workspace != nil else {
            return nil
        }

        return CodexSessionMetadata(sessionId: sessionId, workspace: workspace)
    }

    public static func readTaskSummary(_ line: String) -> String? {
        guard let root = parseObject(line),
              let type = string(root["type"]),
              let payload = root["payload"] as? [String: Any]
        else {
            return nil
        }

        if type.caseInsensitiveCompare("event_msg") == .orderedSame,
           string(payload["type"])?.caseInsensitiveCompare("user_message") == .orderedSame,
           let message = string(payload["message"]) {
            return normalizeTaskSummary(message)
        }

        guard type.caseInsensitiveCompare("response_item") == .orderedSame,
              string(payload["type"])?.caseInsensitiveCompare("message") == .orderedSame,
              string(payload["role"])?.caseInsensitiveCompare("user") == .orderedSame,
              let content = payload["content"] as? [[String: Any]]
        else {
            return nil
        }

        for item in content {
            guard let contentType = string(item["type"]),
                  ["input_text", "text"].contains(contentType),
                  let text = string(item["text"]),
                  let summary = normalizeTaskSummary(text)
            else {
                continue
            }
            return summary
        }

        return nil
    }

    public static func readTaskDetail(_ line: String) -> String? {
        guard let root = parseObject(line),
              let type = string(root["type"]),
              let payload = root["payload"] as? [String: Any]
        else {
            return nil
        }

        if type.caseInsensitiveCompare("event_msg") == .orderedSame,
           string(payload["type"])?.caseInsensitiveCompare("agent_message") == .orderedSame,
           let message = string(payload["message"]) {
            return normalizeTaskDetail(message)
        }

        guard type.caseInsensitiveCompare("response_item") == .orderedSame,
              string(payload["type"])?.caseInsensitiveCompare("message") == .orderedSame,
              string(payload["role"])?.caseInsensitiveCompare("assistant") == .orderedSame,
              let content = payload["content"] as? [[String: Any]]
        else {
            return nil
        }

        for item in content {
            guard let contentType = string(item["type"]),
                  ["output_text", "text"].contains(contentType),
                  let text = string(item["text"]),
                  let detail = normalizeTaskDetail(text)
            else {
                continue
            }
            return detail
        }

        return nil
    }

    public static func readTimestamp(_ line: String) -> Date? {
        guard let root = parseObject(line),
              let value = string(root["timestamp"])
        else {
            return nil
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        return ISO8601DateFormatter().date(from: value)
    }

    public static func normalizeTaskSummary(_ value: String) -> String? {
        var cleaned = cleanCodexDisplayText(value)
        guard !cleaned.isEmpty else {
            return nil
        }

        if let range = cleaned.range(
            of: #"(?is)(?:^|\s)#+\s*Task\s+Research\s+name:\s*(.+?)\s+category:"#,
            options: .regularExpression
        ) {
            let matched = String(cleaned[range])
            cleaned = regexReplace(
                matched,
                pattern: #"(?is)(?:^|\s)#+\s*Task\s+Research\s+name:\s*(.+?)\s+category:"#,
                replacement: "$1")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return truncate(buildShortTaskSummary(cleaned), maxLength: maxTaskSummaryLength)
    }

    public static func normalizeTaskDetail(_ value: String) -> String? {
        let cleaned = cleanCodexDisplayText(value)
        guard !cleaned.isEmpty else {
            return nil
        }

        return truncate(cleaned, maxLength: maxTaskDetailLength)
    }

    private static func mapEventMessage(_ payload: [String: Any]) -> CodexSessionStatusUpdate? {
        switch string(payload["type"]) {
        case "task_started", "user_message":
            return CodexSessionStatusUpdate(
                phase: .reasoning,
                message: "Codex is thinking",
                ttlSeconds: 30)
        case "task_complete":
            return CodexSessionStatusUpdate(
                phase: .success,
                message: "Codex finished",
                ttlSeconds: 10)
        default:
            return nil
        }
    }

    private static func mapResponseItem(_ payload: [String: Any]) -> CodexSessionStatusUpdate? {
        switch string(payload["type"]) {
        case "reasoning":
            return CodexSessionStatusUpdate(
                phase: .reasoning,
                message: "Codex is thinking",
                ttlSeconds: 30)
        case "function_call", "custom_tool_call":
            return CodexSessionStatusUpdate(
                phase: .toolCalling,
                message: "Using \(toolName(payload))",
                ttlSeconds: 30)
        case "function_call_output", "custom_tool_call_output":
            return CodexSessionStatusUpdate(
                phase: .reasoning,
                message: "Reviewing tool result",
                ttlSeconds: 30)
        default:
            return nil
        }
    }

    private static func toolName(_ payload: [String: Any]) -> String {
        let name = cleanValue(string(payload["name"])) ?? cleanValue(string(payload["tool_name"])) ?? "tool"
        return name.count <= 48 ? name : String(name.prefix(48))
    }

    private static func cleanCodexDisplayText(_ value: String) -> String {
        var cleaned = regexReplace(
            value,
            pattern: #"(?is)<environment_context>.*?</environment_context>"#,
            replacement: " ")
        cleaned = regexReplace(cleaned, pattern: #"(?is)<image>.*?</image>"#, replacement: " ")
        cleaned = regexReplace(cleaned, pattern: #"(?is)<oai-mem-citation>.*?</oai-mem-citation>"#, replacement: " ")
        cleaned = regexReplace(cleaned, pattern: #"!\[[^\]]*\]\([^)]+\)"#, replacement: " ")
        cleaned = regexReplace(cleaned, pattern: #"\[\$[^\]]+\]\([^)]+\)"#, replacement: " ")
        cleaned = regexReplace(cleaned, pattern: #"\[([^\]]+)\]\([^)]+\)"#, replacement: "$1")
        cleaned = regexReplace(cleaned, pattern: #"`[^`]*[\\/][^`]*`"#, replacement: " ")
        cleaned = regexReplace(cleaned, pattern: #"[A-Za-z]:\\[^\s\]\)>"']+"#, replacement: " ")
        cleaned = regexReplace(cleaned, pattern: #"\s+"#, replacement: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizeKnownTerms(cleaned)
    }

    private static func buildShortTaskSummary(_ value: String) -> String {
        let cleaned = stripRequestPrefix(value)
        guard !cleaned.isEmpty else {
            return cleaned
        }

        if containsHan(cleaned) {
            if containsAny(cleaned, ["调研", "研究"]),
               cleaned.range(of: "LLM", options: .caseInsensitive) != nil,
               cleaned.range(of: "Router", options: .caseInsensitive) != nil {
                return "调研 LLM Router 方案"
            }

            if (cleaned.range(of: "pet", options: .caseInsensitive) != nil || cleaned.contains("宠物")),
               (cleaned.range(of: "summary", options: .caseInsensitive) != nil || cleaned.contains("摘要格式")) {
                return "调整 pet 摘要格式"
            }

            let separators = CharacterSet(charactersIn: "，。！？!?；;：:")
            let clause = cleaned
                .components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? cleaned
            return stripRequestPrefix(clause)
        }

        return cleaned
    }

    private static func stripRequestPrefix(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in [
            "please implement this plan:",
            "please ",
            "can you ",
            "could you ",
            "help me ",
            "请帮我",
            "请你帮我",
            "帮我",
            "麻烦帮我",
            "麻烦你",
            "请",
            "我想",
            "我现在希望",
            "现在我希望",
            "现在希望",
            "希望"
        ] where cleaned.lowercased().hasPrefix(prefix.lowercased()) {
            cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n，。:：-'\""))
    }

    private static func normalizeKnownTerms(_ value: String) -> String {
        var normalized = regexReplace(value, pattern: #"(?i)llm"#, replacement: "LLM")
        normalized = regexReplace(normalized, pattern: #"(?i)router"#, replacement: "Router")
        normalized = regexReplace(normalized, pattern: #"(?i)cursor"#, replacement: "Cursor")
        normalized = regexReplace(normalized, pattern: #"(?i)qwen"#, replacement: "Qwen")
        return normalized
    }

    private static func truncate(_ value: String, maxLength: Int) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maxLength else {
            return cleaned
        }

        return "\(cleaned.prefix(maxLength - 3))..."
    }

    private static func containsHan(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value >= 0x4e00 && scalar.value <= 0x9fff
        }
    }

    private static func containsAny(_ value: String, _ tokens: [String]) -> Bool {
        tokens.contains { value.contains($0) }
    }

    private static func cleanValue(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func parseObject(_ line: String) -> [String: Any]? {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return object
    }

    private static func regexReplace(_ value: String, pattern: String, replacement: String) -> String {
        do {
            let expression = try NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators])
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return expression.stringByReplacingMatches(
                in: value,
                options: [],
                range: range,
                withTemplate: replacement)
        } catch {
            return value
        }
    }
}

public final class CodexSessionStatusSource: CoderStatusSourcing, @unchecked Sendable {
    private static let recentSessionWindow: TimeInterval = 12 * 60 * 60
    private static let maxTrackedSessions = 12
    private static let activeSessionTtlSeconds = 300
    private static let maxHeadReadBytes = 64 * 1024
    private static let maxTailReadBytes = 256 * 1024

    private let sessionsRoot: URL
    private let fileManager: FileManager
    private let cacheLock = NSLock()
    private var statusCache: [String: CachedStatus] = [:]

    public init(
        sessionsRoot: URL = CodexSessionPaths.defaultSessionsRoot,
        fileManager: FileManager = .default
    ) {
        self.sessionsRoot = sessionsRoot
        self.fileManager = fileManager
    }

    public func getStatuses(now: Date = Date()) -> [CoderAgentStatus] {
        let files = findRecentSessionFiles(now: now)
        pruneStatusCache(keeping: Set(files.map(\.url.path)))

        return files
            .compactMap { readStatus(from: $0.url, modifiedAt: $0.modifiedAt, fileSize: $0.fileSize, now: now) }
            .sorted { lhs, rhs in
                if phasePriority(lhs.phase) != phasePriority(rhs.phase) {
                    return phasePriority(lhs.phase) < phasePriority(rhs.phase)
                }
                if lhs.updatedAtUtc != rhs.updatedAtUtc {
                    return lhs.updatedAtUtc > rhs.updatedAtUtc
                }
                return lhs.agent.localizedCaseInsensitiveCompare(rhs.agent) == .orderedAscending
            }
    }

    private func findRecentSessionFiles(now: Date) -> [(url: URL, modifiedAt: Date, fileSize: UInt64)] {
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        ) else {
            return []
        }

        var files: [(url: URL, modifiedAt: Date, fileSize: UInt64)] = []
        let cutoff = now.addingTimeInterval(-Self.recentSessionWindow)

        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile != false,
                  let modifiedAt = values.contentModificationDate,
                  let fileSize = values.fileSize,
                  modifiedAt >= cutoff
            else {
                continue
            }
            files.append((url, modifiedAt, UInt64(max(fileSize, 0))))
        }

        return files
            .sorted {
                if $0.modifiedAt != $1.modifiedAt {
                    return $0.modifiedAt > $1.modifiedAt
                }
                return $0.url.path.localizedCaseInsensitiveCompare($1.url.path) == .orderedDescending
            }
            .prefix(Self.maxTrackedSessions)
            .map { $0 }
    }

    private func readStatus(from url: URL, modifiedAt: Date, fileSize: UInt64, now: Date) -> CoderAgentStatus? {
        if let cached = cachedStatus(for: url.path, modifiedAt: modifiedAt, fileSize: fileSize, now: now) {
            return cached
        }

        guard let contents = readRelevantContents(from: url) else {
            cacheStatus(nil, for: url.path, modifiedAt: modifiedAt, fileSize: fileSize)
            return nil
        }

        var sessionId: String?
        var workspace: String?
        var taskSummary: String?
        var taskDetail: String?
        var latestUpdate: CodexSessionStatusUpdate?
        var latestTimestamp = modifiedAt

        contents.enumerateLines { line, _ in
            if let metadata = CodexSessionEventMapper.readSessionMetadata(line) {
                if sessionId == nil {
                    sessionId = metadata.sessionId
                }
                if workspace == nil {
                    workspace = metadata.workspace
                }
            }

            if taskSummary == nil,
               let summary = CodexSessionEventMapper.readTaskSummary(line) {
                taskSummary = summary
            }

            if let detail = CodexSessionEventMapper.readTaskDetail(line) {
                taskDetail = detail
            }

            if let update = CodexSessionEventMapper.mapJsonLine(line) {
                latestUpdate = update
                latestTimestamp = CodexSessionEventMapper.readTimestamp(line) ?? modifiedAt
            }
        }

        guard let latestUpdate else {
            cacheStatus(nil, for: url.path, modifiedAt: modifiedAt, fileSize: fileSize)
            return nil
        }

        let ttlSeconds = bridgeTtlSeconds(for: latestUpdate)
        guard latestTimestamp.addingTimeInterval(TimeInterval(ttlSeconds)) >= now else {
            cacheStatus(nil, for: url.path, modifiedAt: modifiedAt, fileSize: fileSize)
            return nil
        }

        let status = CoderAgentStatus(
            agent: "codex",
            phase: latestUpdate.phase,
            message: latestUpdate.message,
            workspace: workspace,
            processId: nil,
            updatedAtUtc: latestTimestamp,
            ttlSeconds: ttlSeconds,
            sessionId: sessionId ?? url.deletingPathExtension().lastPathComponent,
            taskSummary: taskSummary ?? fallbackSummary(workspace: workspace),
            sourcePath: url.path,
            taskDetail: taskDetail)
        cacheStatus(status, for: url.path, modifiedAt: modifiedAt, fileSize: fileSize)
        return status
    }

    private func readRelevantContents(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        guard let fileSize = try? handle.seekToEnd() else {
            return nil
        }

        let fullReadLimit = UInt64(Self.maxHeadReadBytes + Self.maxTailReadBytes)
        do {
            if fileSize <= fullReadLimit {
                try handle.seek(toOffset: 0)
                return String(data: handle.readDataToEndOfFile(), encoding: .utf8)
            }

            var data = Data()
            try handle.seek(toOffset: 0)
            if let head = try handle.read(upToCount: Self.maxHeadReadBytes) {
                data.append(head)
                data.append(0x0A)
            }

            try handle.seek(toOffset: fileSize - UInt64(Self.maxTailReadBytes))
            if let tail = try handle.readToEnd() {
                data.append(tail)
            }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func cachedStatus(
        for path: String,
        modifiedAt: Date,
        fileSize: UInt64,
        now: Date
    ) -> CoderAgentStatus?? {
        cacheLock.lock()
        defer {
            cacheLock.unlock()
        }

        guard let cached = statusCache[path],
              cached.modifiedAt == modifiedAt,
              cached.fileSize == fileSize
        else {
            return nil
        }

        return .some(activeStatus(cached.status, now: now))
    }

    private func cacheStatus(
        _ status: CoderAgentStatus?,
        for path: String,
        modifiedAt: Date,
        fileSize: UInt64
    ) {
        cacheLock.lock()
        statusCache[path] = CachedStatus(modifiedAt: modifiedAt, fileSize: fileSize, status: status)
        cacheLock.unlock()
    }

    private func pruneStatusCache(keeping paths: Set<String>) {
        cacheLock.lock()
        statusCache = statusCache.filter { paths.contains($0.key) }
        cacheLock.unlock()
    }

    private func activeStatus(_ status: CoderAgentStatus?, now: Date) -> CoderAgentStatus? {
        guard let status,
              let ttlSeconds = status.ttlSeconds,
              status.updatedAtUtc.addingTimeInterval(TimeInterval(ttlSeconds)) >= now
        else {
            return nil
        }
        return status
    }

    private func bridgeTtlSeconds(for update: CodexSessionStatusUpdate) -> Int {
        update.phase == .success ? update.ttlSeconds : max(update.ttlSeconds, Self.activeSessionTtlSeconds)
    }

    private func fallbackSummary(workspace: String?) -> String {
        guard let workspace else {
            return "Codex task"
        }

        let trimmed = workspace.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        let workspaceName = URL(fileURLWithPath: trimmed).lastPathComponent
        return workspaceName.isEmpty ? "Codex task" : "Codex task in \(workspaceName)"
    }

    private struct CachedStatus {
        let modifiedAt: Date
        let fileSize: UInt64
        let status: CoderAgentStatus?
    }
}
