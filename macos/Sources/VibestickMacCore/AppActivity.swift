import AppKit
import Foundation

public enum AppActivityCategory: String, Codable, CaseIterable, Sendable {
    case study
    case distraction
    case neutral
}

public struct AppActivityApplicationSnapshot: Codable, Equatable, Sendable {
    public let appName: String?
    public let bundleIdentifier: String?
    public let processId: Int32?

    public init(appName: String?, bundleIdentifier: String?, processId: Int32?) {
        self.appName = Self.clean(appName)
        self.bundleIdentifier = Self.clean(bundleIdentifier)
        self.processId = processId
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct BrowserTabInfo: Codable, Equatable, Sendable {
    public let title: String?
    public let url: String?

    public init(title: String?, url: String?) {
        self.title = Self.clean(title)
        self.url = Self.clean(url)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct AppActivityObservation: Codable, Equatable, Sendable {
    public let observedAtUtc: Date
    public let category: AppActivityCategory
    public let appName: String?
    public let bundleIdentifier: String?
    public let processId: Int32?
    public let browserTitle: String?
    public let browserURL: String?
    public let matchedRuleId: String?
    public let matchedField: String?
    public let matchedValue: String?
    public let diagnostics: [String]

    public init(
        observedAtUtc: Date,
        category: AppActivityCategory,
        appName: String?,
        bundleIdentifier: String?,
        processId: Int32?,
        browserTitle: String?,
        browserURL: String?,
        matchedRuleId: String? = nil,
        matchedField: String? = nil,
        matchedValue: String? = nil,
        diagnostics: [String] = []
    ) {
        self.observedAtUtc = observedAtUtc
        self.category = category
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.processId = processId
        self.browserTitle = browserTitle
        self.browserURL = browserURL
        self.matchedRuleId = matchedRuleId
        self.matchedField = matchedField
        self.matchedValue = matchedValue
        self.diagnostics = diagnostics
    }

    public func withDiagnostics(_ diagnostics: [String], observedAtUtc: Date) -> AppActivityObservation {
        AppActivityObservation(
            observedAtUtc: observedAtUtc,
            category: category,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            processId: processId,
            browserTitle: browserTitle,
            browserURL: browserURL,
            matchedRuleId: matchedRuleId,
            matchedField: matchedField,
            matchedValue: matchedValue,
            diagnostics: self.diagnostics + diagnostics)
    }
}

public struct AppActivityRule: Codable, Equatable, Sendable {
    public let id: String
    public let category: AppActivityCategory
    public let isEnabled: Bool
    public let bundleIdentifiers: [String]
    public let appNameFragments: [String]
    public let urlHostSuffixes: [String]
    public let urlContains: [String]
    public let titleFragments: [String]

    public init(
        id: String,
        category: AppActivityCategory,
        isEnabled: Bool = true,
        bundleIdentifiers: [String] = [],
        appNameFragments: [String] = [],
        urlHostSuffixes: [String] = [],
        urlContains: [String] = [],
        titleFragments: [String] = []
    ) {
        self.id = id
        self.category = category
        self.isEnabled = isEnabled
        self.bundleIdentifiers = bundleIdentifiers
        self.appNameFragments = appNameFragments
        self.urlHostSuffixes = urlHostSuffixes
        self.urlContains = urlContains
        self.titleFragments = titleFragments
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case category
        case isEnabled
        case bundleIdentifiers
        case appNameFragments
        case urlHostSuffixes
        case urlContains
        case titleFragments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        category = try container.decode(AppActivityCategory.self, forKey: .category)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        bundleIdentifiers = try container.decodeIfPresent([String].self, forKey: .bundleIdentifiers) ?? []
        appNameFragments = try container.decodeIfPresent([String].self, forKey: .appNameFragments) ?? []
        urlHostSuffixes = try container.decodeIfPresent([String].self, forKey: .urlHostSuffixes) ?? []
        urlContains = try container.decodeIfPresent([String].self, forKey: .urlContains) ?? []
        titleFragments = try container.decodeIfPresent([String].self, forKey: .titleFragments) ?? []
    }

    public var hasMatchers: Bool {
        Self.hasNonEmptyValue(bundleIdentifiers)
            || Self.hasNonEmptyValue(appNameFragments)
            || Self.hasNonEmptyValue(urlHostSuffixes)
            || Self.hasNonEmptyValue(urlContains)
            || Self.hasNonEmptyValue(titleFragments)
    }

    public var normalizedForStorage: AppActivityRule {
        AppActivityRule(
            id: id.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            isEnabled: isEnabled,
            bundleIdentifiers: Self.cleanValues(bundleIdentifiers),
            appNameFragments: Self.cleanValues(appNameFragments),
            urlHostSuffixes: Self.cleanValues(urlHostSuffixes),
            urlContains: Self.cleanValues(urlContains),
            titleFragments: Self.cleanValues(titleFragments))
    }

    private static func cleanValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var cleaned: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            cleaned.append(trimmed)
        }
        return cleaned
    }

    private static func hasNonEmptyValue(_ values: [String]) -> Bool {
        values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

public struct AppActivityRuleFile: Codable, Equatable, Sendable {
    public let rules: [AppActivityRule]

    public init(rules: [AppActivityRule]) {
        self.rules = rules
    }
}

public struct AppActivityRuleLoadResult: Equatable, Sendable {
    public let rules: [AppActivityRule]
    public let diagnostics: [String]

    public init(rules: [AppActivityRule], diagnostics: [String] = []) {
        self.rules = rules
        self.diagnostics = diagnostics
    }
}

public struct AppActivityRuleInventory: Equatable, Sendable {
    public let bundledRules: [AppActivityRule]
    public let userRules: [AppActivityRule]
    public let effectiveRules: [AppActivityRule]
    public let userRulesURL: URL
    public let diagnostics: [String]

    public init(
        bundledRules: [AppActivityRule],
        userRules: [AppActivityRule],
        effectiveRules: [AppActivityRule],
        userRulesURL: URL,
        diagnostics: [String] = []
    ) {
        self.bundledRules = bundledRules
        self.userRules = userRules
        self.effectiveRules = effectiveRules
        self.userRulesURL = userRulesURL
        self.diagnostics = diagnostics
    }
}

public enum AppActivityRuleStoreError: Error, Equatable, LocalizedError, Sendable {
    case emptyRuleId
    case duplicateRuleIds([String])
    case missingMatchers(String)
    case bundledRuleNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .emptyRuleId:
            return "规则 id 不能为空。"
        case .duplicateRuleIds(let ids):
            return "规则 id 不能重复：\(ids.joined(separator: ", "))。"
        case .missingMatchers(let id):
            return "规则 \(id) 至少需要一个匹配项。"
        case .bundledRuleNotFound(let id):
            return "没有找到内置规则：\(id)。"
        }
    }
}

public struct AppActivityRuleStore: Sendable {
    public static let userRulesFileName = "app-activity-rules.json"

    public let userRulesURL: URL
    private let bundledRulesOverride: [AppActivityRule]?

    public init(
        userRulesURL: URL = VibestickPaths.userApplicationSupportDirectory.appendingPathComponent(userRulesFileName),
        bundledRulesOverride: [AppActivityRule]? = nil
    ) {
        self.userRulesURL = userRulesURL
        self.bundledRulesOverride = bundledRulesOverride
    }

    public func loadRules() -> AppActivityRuleLoadResult {
        let inventory = loadInventory()
        return AppActivityRuleLoadResult(rules: inventory.effectiveRules, diagnostics: inventory.diagnostics)
    }

    public func loadInventory() -> AppActivityRuleInventory {
        var diagnostics: [String] = []
        let bundledRules = bundledRulesOverride ?? Self.readBundledRules(diagnostics: &diagnostics)
        var userRules: [AppActivityRule] = []

        if FileManager.default.fileExists(atPath: userRulesURL.path) {
            do {
                userRules = try Self.decodeRules(from: Data(contentsOf: userRulesURL))
                try Self.validateUserRules(userRules)
            } catch {
                diagnostics.append("无法读取 App 活动规则覆盖文件：\(error.localizedDescription)")
                userRules = []
            }
        }

        return AppActivityRuleInventory(
            bundledRules: bundledRules,
            userRules: userRules,
            effectiveRules: Self.merge(defaultRules: bundledRules, userRules: userRules),
            userRulesURL: userRulesURL,
            diagnostics: diagnostics)
    }

    public func loadBundledRules() -> AppActivityRuleLoadResult {
        var diagnostics: [String] = []
        return AppActivityRuleLoadResult(
            rules: bundledRulesOverride ?? Self.readBundledRules(diagnostics: &diagnostics),
            diagnostics: diagnostics)
    }

    public func loadUserRules() -> AppActivityRuleLoadResult {
        do {
            let rules = try readUserRulesForEditing()
            return AppActivityRuleLoadResult(rules: rules)
        } catch {
            return AppActivityRuleLoadResult(
                rules: [],
                diagnostics: ["无法读取 App 活动规则覆盖文件：\(error.localizedDescription)"])
        }
    }

    @discardableResult
    public func saveUserRules(_ rules: [AppActivityRule]) throws -> [AppActivityRule] {
        let normalizedRules = rules.map(\.normalizedForStorage)
        try Self.validateUserRules(normalizedRules)
        try FileManager.default.createDirectory(
            at: userRulesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try VibestickJSON.encoder.encode(AppActivityRuleFile(rules: normalizedRules))
        try data.write(to: userRulesURL, options: .atomic)
        return normalizedRules
    }

    @discardableResult
    public func upsertUserRule(_ rule: AppActivityRule) throws -> [AppActivityRule] {
        var rules = try readUserRulesForEditing()
        let normalizedRule = rule.normalizedForStorage
        if let index = rules.firstIndex(where: { $0.id == normalizedRule.id }) {
            rules[index] = normalizedRule
        } else {
            rules.append(normalizedRule)
        }
        return try saveUserRules(rules)
    }

    @discardableResult
    public func replaceUserRule(id: String, with rule: AppActivityRule) throws -> [AppActivityRule] {
        let normalizedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        var rules = try readUserRulesForEditing().filter { $0.id != normalizedId }
        let normalizedRule = rule.normalizedForStorage
        if let index = rules.firstIndex(where: { $0.id == normalizedRule.id }) {
            rules[index] = normalizedRule
        } else {
            rules.append(normalizedRule)
        }
        return try saveUserRules(rules)
    }

    @discardableResult
    public func removeUserRule(id: String) throws -> [AppActivityRule] {
        let normalizedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let rules = try readUserRulesForEditing().filter { $0.id != normalizedId }
        return try saveUserRules(rules)
    }

    @discardableResult
    public func disableBundledRule(id: String) throws -> [AppActivityRule] {
        let normalizedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundledRules = loadBundledRules().rules
        guard let bundledRule = bundledRules.first(where: { $0.id == normalizedId }) else {
            throw AppActivityRuleStoreError.bundledRuleNotFound(normalizedId)
        }
        let disabledRule = AppActivityRule(
            id: bundledRule.id,
            category: bundledRule.category,
            isEnabled: false)
        return try upsertUserRule(disabledRule)
    }

    public func resetUserRules() throws {
        guard FileManager.default.fileExists(atPath: userRulesURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: userRulesURL)
    }

    public static func decodeRules(from data: Data) throws -> [AppActivityRule] {
        let decoder = VibestickJSON.decoder
        if let file = try? decoder.decode(AppActivityRuleFile.self, from: data) {
            return file.rules
        }
        return try decoder.decode([AppActivityRule].self, from: data)
    }

    public static func merge(defaultRules: [AppActivityRule], userRules: [AppActivityRule]) -> [AppActivityRule] {
        var merged = defaultRules
        for userRule in userRules {
            if let existingIndex = merged.firstIndex(where: { $0.id == userRule.id }) {
                if userRule.isEnabled {
                    merged[existingIndex] = userRule
                } else {
                    merged.remove(at: existingIndex)
                }
            } else if userRule.isEnabled {
                merged.append(userRule)
            }
        }
        return merged
    }

    public static func validateUserRules(_ rules: [AppActivityRule]) throws {
        try validate(rules: rules, requireMatchersForDisabledRules: false)
    }

    public static func validateEffectiveRules(_ rules: [AppActivityRule]) throws {
        try validate(rules: rules, requireMatchersForDisabledRules: true)
    }

    private func readUserRulesForEditing() throws -> [AppActivityRule] {
        guard FileManager.default.fileExists(atPath: userRulesURL.path) else {
            return []
        }
        let rules = try Self.decodeRules(from: Data(contentsOf: userRulesURL))
        try Self.validateUserRules(rules)
        return rules
    }

    private static func validate(rules: [AppActivityRule], requireMatchersForDisabledRules: Bool) throws {
        let normalizedRules = rules.map(\.normalizedForStorage)
        var seen = Set<String>()
        var duplicateIds: [String] = []
        for rule in normalizedRules {
            guard !rule.id.isEmpty else {
                throw AppActivityRuleStoreError.emptyRuleId
            }
            if !seen.insert(rule.id).inserted {
                duplicateIds.append(rule.id)
            }
            if (rule.isEnabled || requireMatchersForDisabledRules) && !rule.hasMatchers {
                throw AppActivityRuleStoreError.missingMatchers(rule.id)
            }
        }
        if !duplicateIds.isEmpty {
            throw AppActivityRuleStoreError.duplicateRuleIds(Array(Set(duplicateIds)).sorted())
        }
    }

    private static func readBundledRules(diagnostics: inout [String]) -> [AppActivityRule] {
        guard let url = Bundle.module.url(forResource: "AppActivityRules", withExtension: "json") else {
            diagnostics.append("内置 App 活动规则文件缺失。")
            return []
        }

        do {
            let rules = try decodeRules(from: Data(contentsOf: url))
            try validateEffectiveRules(rules)
            return rules
        } catch {
            diagnostics.append("内置 App 活动规则文件无法解析：\(error.localizedDescription)")
            return []
        }
    }
}

public struct AppActivityClassification: Codable, Equatable, Sendable {
    public let category: AppActivityCategory
    public let matchedRuleId: String?
    public let matchedField: String?
    public let matchedValue: String?

    public init(
        category: AppActivityCategory,
        matchedRuleId: String? = nil,
        matchedField: String? = nil,
        matchedValue: String? = nil
    ) {
        self.category = category
        self.matchedRuleId = matchedRuleId
        self.matchedField = matchedField
        self.matchedValue = matchedValue
    }
}

public struct AppActivityClassifier: Sendable {
    private let rules: [AppActivityRule]

    public init(rules: [AppActivityRule]) {
        self.rules = rules.filter(\.isEnabled)
    }

    public func classify(
        application: AppActivityApplicationSnapshot,
        browserTab: BrowserTabInfo?
    ) -> AppActivityClassification {
        if let url = browserTab?.url,
           let match = matchURLHost(url) ?? matchURLContains(url) {
            return match
        }

        if let title = browserTab?.title,
           let match = matchField(title, field: "title", keyPath: \.titleFragments, exact: false) {
            return match
        }

        if let bundleIdentifier = application.bundleIdentifier,
           let match = matchField(bundleIdentifier, field: "bundle_identifier", keyPath: \.bundleIdentifiers, exact: true) {
            return match
        }

        if let appName = application.appName,
           let match = matchField(appName, field: "app_name", keyPath: \.appNameFragments, exact: false) {
            return match
        }

        return AppActivityClassification(category: .neutral)
    }

    private func matchURLHost(_ url: String) -> AppActivityClassification? {
        guard let host = URLComponents(string: url)?.host?.lowercased() else {
            return nil
        }

        for rule in rules {
            for suffix in rule.urlHostSuffixes {
                let normalizedSuffix = suffix.lowercased()
                if host == normalizedSuffix || host.hasSuffix(".\(normalizedSuffix)") {
                    return AppActivityClassification(
                        category: rule.category,
                        matchedRuleId: rule.id,
                        matchedField: "url_host",
                        matchedValue: suffix)
                }
            }
        }
        return nil
    }

    private func matchURLContains(_ url: String) -> AppActivityClassification? {
        matchField(url, field: "url", keyPath: \.urlContains, exact: false)
    }

    private func matchField(
        _ value: String,
        field: String,
        keyPath: KeyPath<AppActivityRule, [String]>,
        exact: Bool
    ) -> AppActivityClassification? {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty else {
            return nil
        }

        for rule in rules {
            for candidate in rule[keyPath: keyPath] {
                let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedCandidate.isEmpty else {
                    continue
                }

                let matches = exact
                    ? normalizedValue.caseInsensitiveCompare(normalizedCandidate) == .orderedSame
                    : normalizedValue.range(
                        of: normalizedCandidate,
                        options: [.caseInsensitive, .diacriticInsensitive]) != nil
                if matches {
                    return AppActivityClassification(
                        category: rule.category,
                        matchedRuleId: rule.id,
                        matchedField: field,
                        matchedValue: candidate)
                }
            }
        }
        return nil
    }
}

public protocol ForegroundApplicationSnapshotSourcing: Sendable {
    func frontmostApplication() -> AppActivityApplicationSnapshot?
}

public final class MacForegroundApplicationSnapshotSource: ForegroundApplicationSnapshotSourcing, @unchecked Sendable {
    public init() {}

    public func frontmostApplication() -> AppActivityApplicationSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return AppActivityApplicationSnapshot(
            appName: app.localizedName,
            bundleIdentifier: app.bundleIdentifier,
            processId: app.processIdentifier)
    }
}

public enum BrowserTabReadResult: Equatable, Sendable {
    case success(BrowserTabInfo)
    case noTab
    case unsupported
    case permissionDenied(String)
    case failed(String)
}

public protocol BrowserTabReading: Sendable {
    func activeTab(for application: AppActivityApplicationSnapshot) -> BrowserTabReadResult
}

public final class AppleScriptBrowserTabReader: BrowserTabReading, @unchecked Sendable {
    private enum BrowserKind {
        case chromium
        case safari
    }

    private let runner: CommandRunning

    public init(runner: CommandRunning = ProcessCommandRunner(timeoutSeconds: 2)) {
        self.runner = runner
    }

    public func activeTab(for application: AppActivityApplicationSnapshot) -> BrowserTabReadResult {
        guard let bundleIdentifier = application.bundleIdentifier,
              let kind = Self.browserKind(bundleIdentifier)
        else {
            return .unsupported
        }

        let script = Self.script(bundleIdentifier: bundleIdentifier, kind: kind)
        do {
            let result = try runner.run("/usr/bin/osascript", ["-e", script])
            if result.exitCode != 0 {
                let detail = [result.standardError, result.standardOutput]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                if Self.isPermissionError(detail) {
                    return .permissionDenied("需要允许 Vibestick 自动化读取 \(application.appName ?? "浏览器") 的当前标签页。")
                }
                return .failed(detail.isEmpty ? "无法读取当前浏览器标签页。" : detail)
            }

            let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else {
                return .noTab
            }

            let parts = output.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                return .failed("浏览器标签页输出格式无法解析。")
            }

            return .success(BrowserTabInfo(title: String(parts[0]), url: String(parts[1])))
        } catch CommandRunError.timedOut {
            return .failed("读取浏览器标签页超时。")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func browserKind(_ bundleIdentifier: String) -> BrowserKind? {
        switch bundleIdentifier.lowercased() {
        case "com.apple.safari":
            .safari
        case "com.microsoft.edgemac",
             "com.google.chrome",
             "com.google.chrome.canary",
             "com.brave.browser",
             "company.thebrowser.browser",
             "com.vivaldi.vivaldi":
            .chromium
        default:
            nil
        }
    }

    private static func script(bundleIdentifier: String, kind: BrowserKind) -> String {
        switch kind {
        case .chromium:
            """
            tell application id "\(escapeAppleScriptString(bundleIdentifier))"
                if (count of windows) = 0 then return ""
                set activeTitle to title of active tab of front window
                set activeURL to URL of active tab of front window
                return activeTitle & (ASCII character 31) & activeURL
            end tell
            """
        case .safari:
            """
            tell application id "\(escapeAppleScriptString(bundleIdentifier))"
                if (count of windows) = 0 then return ""
                set activeTitle to name of current tab of front window
                set activeURL to URL of current tab of front window
                return activeTitle & (ASCII character 31) & activeURL
            end tell
            """
        }
    }

    private static func isPermissionError(_ detail: String) -> Bool {
        let lowercased = detail.lowercased()
        return lowercased.contains("not authorized")
            || lowercased.contains("not permitted")
            || lowercased.contains("not allowed")
            || lowercased.contains("errAEEventNotPermitted".lowercased())
            || lowercased.contains("不能自动化")
            || lowercased.contains("未被授权")
    }

    private static func escapeAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public final class AppActivityInspector: @unchecked Sendable {
    private static let selfObservationGrace: TimeInterval = 5

    private let ruleStore: AppActivityRuleStore
    private let applicationSource: ForegroundApplicationSnapshotSourcing
    private let browserTabReader: BrowserTabReading
    private let lock = NSLock()
    private var lastNonSelfObservation: AppActivityObservation?

    public init(
        ruleStore: AppActivityRuleStore = AppActivityRuleStore(),
        applicationSource: ForegroundApplicationSnapshotSourcing = MacForegroundApplicationSnapshotSource(),
        browserTabReader: BrowserTabReading = AppleScriptBrowserTabReader()
    ) {
        self.ruleStore = ruleStore
        self.applicationSource = applicationSource
        self.browserTabReader = browserTabReader
    }

    public func observe(now: Date = Date()) -> AppActivityObservation {
        let loadResult = ruleStore.loadRules()
        let classifier = AppActivityClassifier(rules: loadResult.rules)

        guard let application = applicationSource.frontmostApplication() else {
            return neutralObservation(
                now: now,
                application: nil,
                browserTab: nil,
                diagnostics: loadResult.diagnostics + ["没有检测到当前前台 App。"])
        }

        if application.bundleIdentifier?.caseInsensitiveCompare("com.apple.loginwindow") == .orderedSame {
            return neutralObservation(
                now: now,
                application: application,
                browserTab: nil,
                diagnostics: loadResult.diagnostics + ["当前前台是登录窗口，可能处于锁屏或非交互会话。"])
        }

        if application.bundleIdentifier?.caseInsensitiveCompare(VibestickPaths.bundleIdentifier) == .orderedSame {
            if let previous = recentLastNonSelfObservation(now: now) {
                return previous.withDiagnostics(
                    loadResult.diagnostics + ["Vibestick 当前在前台，沿用最近一次非 Vibestick App 活动。"],
                    observedAtUtc: now)
            }
            return neutralObservation(
                now: now,
                application: application,
                browserTab: nil,
                diagnostics: loadResult.diagnostics + ["Vibestick 当前在前台，暂无可沿用的 App 活动。"])
        }

        let browserResult = browserTabReader.activeTab(for: application)
        let browserTab: BrowserTabInfo?
        let diagnostics: [String]
        switch browserResult {
        case .success(let tab):
            browserTab = tab
            diagnostics = loadResult.diagnostics
        case .unsupported:
            browserTab = nil
            diagnostics = loadResult.diagnostics
        case .noTab:
            browserTab = nil
            diagnostics = loadResult.diagnostics + ["浏览器当前没有可读取的标签页。"]
        case .permissionDenied(let message):
            let observation = neutralObservation(
                now: now,
                application: application,
                browserTab: nil,
                diagnostics: loadResult.diagnostics + [message])
            rememberNonSelfObservation(observation)
            return observation
        case .failed(let message):
            let observation = neutralObservation(
                now: now,
                application: application,
                browserTab: nil,
                diagnostics: loadResult.diagnostics + [message])
            rememberNonSelfObservation(observation)
            return observation
        }

        let classification = classifier.classify(application: application, browserTab: browserTab)
        let observation = AppActivityObservation(
            observedAtUtc: now,
            category: classification.category,
            appName: application.appName,
            bundleIdentifier: application.bundleIdentifier,
            processId: application.processId,
            browserTitle: browserTab?.title,
            browserURL: browserTab?.url,
            matchedRuleId: classification.matchedRuleId,
            matchedField: classification.matchedField,
            matchedValue: classification.matchedValue,
            diagnostics: diagnostics)
        rememberNonSelfObservation(observation)
        return observation
    }

    private func neutralObservation(
        now: Date,
        application: AppActivityApplicationSnapshot?,
        browserTab: BrowserTabInfo?,
        diagnostics: [String]
    ) -> AppActivityObservation {
        AppActivityObservation(
            observedAtUtc: now,
            category: .neutral,
            appName: application?.appName,
            bundleIdentifier: application?.bundleIdentifier,
            processId: application?.processId,
            browserTitle: browserTab?.title,
            browserURL: browserTab?.url,
            diagnostics: diagnostics)
    }

    private func recentLastNonSelfObservation(now: Date) -> AppActivityObservation? {
        lock.lock()
        defer { lock.unlock() }
        guard let observation = lastNonSelfObservation,
              now.timeIntervalSince(observation.observedAtUtc) <= Self.selfObservationGrace
        else {
            return nil
        }
        return observation
    }

    private func rememberNonSelfObservation(_ observation: AppActivityObservation) {
        lock.lock()
        lastNonSelfObservation = observation
        lock.unlock()
    }
}
