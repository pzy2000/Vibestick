import Foundation
import XCTest
@testable import VibestickMacCore

final class AppActivityTests: XCTestCase {
    func testRuleMatchingUsesURLTitleBundleThenNamePrecedence() {
        let classifier = AppActivityClassifier(rules: [
            AppActivityRule(
                id: "name-distraction",
                category: .distraction,
                appNameFragments: ["Cursor"]),
            AppActivityRule(
                id: "bundle-study",
                category: .study,
                bundleIdentifiers: ["com.example.cursor"]),
            AppActivityRule(
                id: "title-distraction",
                category: .distraction,
                titleFragments: ["YouTube"]),
            AppActivityRule(
                id: "url-study",
                category: .study,
                urlHostSuffixes: ["scholar.google.com"])
        ])
        let app = AppActivityApplicationSnapshot(
            appName: "Cursor",
            bundleIdentifier: "com.example.cursor",
            processId: 42)

        var result = classifier.classify(
            application: app,
            browserTab: BrowserTabInfo(title: "YouTube", url: "https://scholar.google.com/citations"))

        XCTAssertEqual(result.category, .study)
        XCTAssertEqual(result.matchedRuleId, "url-study")
        XCTAssertEqual(result.matchedField, "url_host")

        result = classifier.classify(
            application: app,
            browserTab: BrowserTabInfo(title: "YouTube", url: nil))

        XCTAssertEqual(result.category, .distraction)
        XCTAssertEqual(result.matchedRuleId, "title-distraction")
        XCTAssertEqual(result.matchedField, "title")

        result = classifier.classify(application: app, browserTab: nil)

        XCTAssertEqual(result.category, .study)
        XCTAssertEqual(result.matchedRuleId, "bundle-study")
        XCTAssertEqual(result.matchedField, "bundle_identifier")
    }

    func testRuleStoreMergesUserOverridesAndDisabledRules() {
        let defaultRules = [
            AppActivityRule(
                id: "default-study",
                category: .study,
                appNameFragments: ["Codex"]),
            AppActivityRule(
                id: "default-distraction",
                category: .distraction,
                appNameFragments: ["Steam"])
        ]
        let userRules = [
            AppActivityRule(
                id: "default-study",
                category: .neutral,
                isEnabled: false),
            AppActivityRule(
                id: "custom-study",
                category: .study,
                bundleIdentifiers: ["com.example.Focus"])
        ]

        let merged = AppActivityRuleStore.merge(defaultRules: defaultRules, userRules: userRules)

        XCTAssertFalse(merged.contains { $0.id == "default-study" })
        XCTAssertTrue(merged.contains { $0.id == "default-distraction" })
        XCTAssertTrue(merged.contains { $0.id == "custom-study" })
    }

    func testRuleStoreInventorySeparatesBundledUserAndEffectiveRules() throws {
        let store = makeTemporaryRuleStore(bundledRules: [
            AppActivityRule(
                id: "default-study",
                category: .study,
                appNameFragments: ["Codex"])
        ])
        try store.saveUserRules([
            AppActivityRule(
                id: "custom-distraction",
                category: .distraction,
                urlHostSuffixes: ["video.example"])
        ])

        let inventory = store.loadInventory()

        XCTAssertEqual(inventory.bundledRules.map(\.id), ["default-study"])
        XCTAssertEqual(inventory.userRules.map(\.id), ["custom-distraction"])
        XCTAssertEqual(Set(inventory.effectiveRules.map(\.id)), ["default-study", "custom-distraction"])
        XCTAssertTrue(inventory.diagnostics.isEmpty)
    }

    func testRuleStoreCanDisableRestoreAndEditBundledRulesAsUserOverrides() throws {
        let store = makeTemporaryRuleStore(bundledRules: [
            AppActivityRule(
                id: "default-study",
                category: .study,
                appNameFragments: ["Codex"])
        ])

        try store.disableBundledRule(id: "default-study")
        XCTAssertFalse(store.loadInventory().effectiveRules.contains { $0.id == "default-study" })
        XCTAssertEqual(store.loadInventory().userRules.first?.isEnabled, false)

        try store.upsertUserRule(AppActivityRule(
            id: "default-study",
            category: .distraction,
            appNameFragments: ["Codex"]))
        let edited = try XCTUnwrap(store.loadInventory().effectiveRules.first { $0.id == "default-study" })
        XCTAssertEqual(edited.category, .distraction)

        try store.removeUserRule(id: "default-study")
        let restored = try XCTUnwrap(store.loadInventory().effectiveRules.first { $0.id == "default-study" })
        XCTAssertEqual(restored.category, .study)
    }

    func testRuleStoreCanAddEditAndDeleteCustomRules() throws {
        let store = makeTemporaryRuleStore(bundledRules: [])

        try store.upsertUserRule(AppActivityRule(
            id: "custom-study",
            category: .study,
            bundleIdentifiers: ["com.example.Focus"]))
        XCTAssertEqual(store.loadInventory().effectiveRules.first?.category, .study)

        try store.replaceUserRule(
            id: "custom-study",
            with: AppActivityRule(
                id: "custom-focus",
                category: .neutral,
                appNameFragments: ["Focus"]))
        XCTAssertNil(store.loadInventory().userRules.first { $0.id == "custom-study" })
        XCTAssertEqual(store.loadInventory().userRules.first?.id, "custom-focus")
        XCTAssertEqual(store.loadInventory().effectiveRules.first?.category, .neutral)

        try store.removeUserRule(id: "custom-focus")
        XCTAssertTrue(store.loadInventory().userRules.isEmpty)
    }

    func testRuleStoreValidationRejectsDuplicateIdsAndMissingMatchers() {
        XCTAssertThrowsError(try AppActivityRuleStore.validateUserRules([
            AppActivityRule(id: "dup", category: .study, appNameFragments: ["A"]),
            AppActivityRule(id: "dup", category: .study, appNameFragments: ["B"])
        ])) { error in
            XCTAssertEqual(error as? AppActivityRuleStoreError, .duplicateRuleIds(["dup"]))
        }

        XCTAssertThrowsError(try AppActivityRuleStore.validateUserRules([
            AppActivityRule(id: "empty-matchers", category: .study)
        ])) { error in
            XCTAssertEqual(error as? AppActivityRuleStoreError, .missingMatchers("empty-matchers"))
        }
    }

    func testRuleStoreInvalidUserJSONReportsDiagnosticAndKeepsBundledRules() throws {
        let store = makeTemporaryRuleStore(bundledRules: [
            AppActivityRule(id: "default-study", category: .study, appNameFragments: ["Codex"])
        ])
        try FileManager.default.createDirectory(
            at: store.userRulesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("{ invalid".utf8).write(to: store.userRulesURL)

        let inventory = store.loadInventory()

        XCTAssertEqual(inventory.effectiveRules.map(\.id), ["default-study"])
        XCTAssertTrue(inventory.diagnostics.contains { $0.contains("无法读取 App 活动规则覆盖文件") })
    }

    func testDecodeRulesSupportsSnakeCaseRuleFile() throws {
        let data = Data("""
        {
          "rules": [
            {
              "id": "snake",
              "category": "study",
              "is_enabled": true,
              "bundle_identifiers": ["com.example.App"],
              "app_name_fragments": ["Example"],
              "url_host_suffixes": ["example.com"],
              "url_contains": ["docs"],
              "title_fragments": ["Docs"]
            }
          ]
        }
        """.utf8)

        let rules = try AppActivityRuleStore.decodeRules(from: data)

        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].bundleIdentifiers, ["com.example.App"])
        XCTAssertEqual(rules[0].appNameFragments, ["Example"])
        XCTAssertEqual(rules[0].urlHostSuffixes, ["example.com"])
        XCTAssertEqual(rules[0].urlContains, ["docs"])
        XCTAssertEqual(rules[0].titleFragments, ["Docs"])
    }

    func testBrowserPermissionFailureReturnsNeutralDiagnostic() {
        let inspector = AppActivityInspector(
            ruleStore: AppActivityRuleStore(bundledRulesOverride: [
                AppActivityRule(
                    id: "edge-study",
                    category: .study,
                    bundleIdentifiers: ["com.microsoft.edgemac"])
            ]),
            applicationSource: StaticApplicationSource([
                AppActivityApplicationSnapshot(
                    appName: "Microsoft Edge",
                    bundleIdentifier: "com.microsoft.edgemac",
                    processId: 7)
            ]),
            browserTabReader: StaticBrowserTabReader(.permissionDenied("Automation denied.")))

        let observation = inspector.observe(now: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(observation.category, .neutral)
        XCTAssertEqual(observation.appName, "Microsoft Edge")
        XCTAssertEqual(observation.diagnostics, ["Automation denied."])
    }

    func testSelfAppUsesRecentNonSelfObservationThenFallsBackToNeutral() {
        let source = StaticApplicationSource([
            AppActivityApplicationSnapshot(
                appName: "Cursor",
                bundleIdentifier: "com.todesktop.230313mzl4w4u92",
                processId: 100),
            AppActivityApplicationSnapshot(
                appName: "Vibestick",
                bundleIdentifier: VibestickPaths.bundleIdentifier,
                processId: 101),
            AppActivityApplicationSnapshot(
                appName: "Vibestick",
                bundleIdentifier: VibestickPaths.bundleIdentifier,
                processId: 101)
        ])
        let inspector = AppActivityInspector(
            ruleStore: AppActivityRuleStore(bundledRulesOverride: [
                AppActivityRule(
                    id: "cursor-study",
                    category: .study,
                    bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"])
            ]),
            applicationSource: source,
            browserTabReader: StaticBrowserTabReader(.unsupported))

        let first = inspector.observe(now: Date(timeIntervalSince1970: 0))
        let recentSelf = inspector.observe(now: Date(timeIntervalSince1970: 2))
        let staleSelf = inspector.observe(now: Date(timeIntervalSince1970: 12))

        XCTAssertEqual(first.category, .study)
        XCTAssertEqual(recentSelf.category, .study)
        XCTAssertEqual(recentSelf.appName, "Cursor")
        XCTAssertTrue(recentSelf.diagnostics.contains { $0.contains("沿用最近一次非 Vibestick") })
        XCTAssertEqual(staleSelf.category, .neutral)
        XCTAssertEqual(staleSelf.appName, "Vibestick")
    }
}

private func makeTemporaryRuleStore(bundledRules: [AppActivityRule]) -> AppActivityRuleStore {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("vibestick-activity-rules-\(UUID().uuidString)", isDirectory: true)
    return AppActivityRuleStore(
        userRulesURL: directory.appendingPathComponent(AppActivityRuleStore.userRulesFileName),
        bundledRulesOverride: bundledRules)
}

private final class StaticApplicationSource: ForegroundApplicationSnapshotSourcing, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [AppActivityApplicationSnapshot]

    init(_ snapshots: [AppActivityApplicationSnapshot]) {
        self.snapshots = snapshots
    }

    func frontmostApplication() -> AppActivityApplicationSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard snapshots.count > 1 else {
            return snapshots.first
        }
        return snapshots.removeFirst()
    }
}

private struct StaticBrowserTabReader: BrowserTabReading {
    let result: BrowserTabReadResult

    init(_ result: BrowserTabReadResult) {
        self.result = result
    }

    func activeTab(for application: AppActivityApplicationSnapshot) -> BrowserTabReadResult {
        result
    }
}
