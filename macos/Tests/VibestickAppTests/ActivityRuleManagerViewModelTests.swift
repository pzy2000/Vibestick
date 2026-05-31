import XCTest
import VibestickMacCore
@testable import VibestickApp

@MainActor
final class ActivityRuleManagerViewModelTests: XCTestCase {
    func testViewModelFiltersAndSelectsRules() throws {
        let store = makeTemporaryRuleStore(bundledRules: [
            AppActivityRule(id: "default-study", category: .study, appNameFragments: ["Codex"]),
            AppActivityRule(id: "default-distraction", category: .distraction, appNameFragments: ["Steam"])
        ])
        try store.saveUserRules([
            AppActivityRule(id: "default-study", category: .study, isEnabled: false),
            AppActivityRule(id: "custom-neutral", category: .neutral, appNameFragments: ["Break"])
        ])
        let viewModel = ActivityRuleManagerViewModel(store: store)

        XCTAssertEqual(viewModel.rows.count, 3)
        XCTAssertEqual(viewModel.effectiveRuleCount, 2)

        viewModel.filter = .disabled
        XCTAssertEqual(viewModel.filteredRows.map(\.id), ["default-study"])
        XCTAssertEqual(viewModel.draft?.id, "default-study")
        XCTAssertEqual(viewModel.draft?.isEnabled, false)

        viewModel.filter = .custom
        XCTAssertEqual(viewModel.filteredRows.map(\.id), ["custom-neutral"])
        XCTAssertEqual(viewModel.draft?.id, "custom-neutral")
    }

    func testEditingBuiltInRuleWritesSameIdUserOverride() throws {
        let store = makeTemporaryRuleStore(bundledRules: [
            AppActivityRule(id: "default-study", category: .study, appNameFragments: ["Codex"])
        ])
        let viewModel = ActivityRuleManagerViewModel(store: store)

        viewModel.selectRule(id: "default-study")
        viewModel.updateDraft { draft in
            draft.category = .distraction
            draft.urlHostSuffixesText = "video.example"
        }
        viewModel.saveDraft()

        let override = try XCTUnwrap(store.loadInventory().userRules.first)
        XCTAssertEqual(override.id, "default-study")
        XCTAssertEqual(override.category, .distraction)
        XCTAssertEqual(override.urlHostSuffixes, ["video.example"])
        XCTAssertEqual(viewModel.selectedRuleID, "default-study")
    }

    func testDisableRestoreAndResetOverrides() throws {
        let store = makeTemporaryRuleStore(bundledRules: [
            AppActivityRule(id: "default-study", category: .study, appNameFragments: ["Codex"])
        ])
        let viewModel = ActivityRuleManagerViewModel(store: store)

        viewModel.selectRule(id: "default-study")
        viewModel.disableSelectedRule()
        XCTAssertFalse(try XCTUnwrap(store.loadInventory().userRules.first).isEnabled)
        XCTAssertTrue(store.loadInventory().effectiveRules.isEmpty)

        viewModel.restoreSelectedRule()
        XCTAssertTrue(store.loadInventory().userRules.isEmpty)
        XCTAssertEqual(store.loadInventory().effectiveRules.map(\.id), ["default-study"])

        viewModel.newCustomRule()
        viewModel.updateDraft { draft in
            draft.id = "custom-focus"
            draft.bundleIdentifiersText = "com.example.Focus"
        }
        viewModel.saveDraft()
        XCTAssertEqual(store.loadInventory().userRules.map(\.id), ["custom-focus"])

        viewModel.resetAllOverrides()
        XCTAssertTrue(store.loadInventory().userRules.isEmpty)
    }

    func testDraftValidationRejectsDuplicateIdAndMissingMatchers() throws {
        let store = makeTemporaryRuleStore(bundledRules: [
            AppActivityRule(id: "default-study", category: .study, appNameFragments: ["Codex"])
        ])
        try store.saveUserRules([
            AppActivityRule(id: "custom-focus", category: .study, appNameFragments: ["Focus"])
        ])
        let viewModel = ActivityRuleManagerViewModel(store: store)

        viewModel.newCustomRule()
        viewModel.updateDraft { draft in
            draft.id = "default-study"
            draft.appNameFragmentsText = "Other"
        }
        viewModel.saveDraft()
        XCTAssertTrue(viewModel.statusMessage.contains("已存在"))

        viewModel.updateDraft { draft in
            draft.id = "custom-empty"
            draft.appNameFragmentsText = ""
        }
        viewModel.saveDraft()
        XCTAssertTrue(viewModel.statusMessage.contains("至少需要一个匹配项"))
    }
}

private func makeTemporaryRuleStore(bundledRules: [AppActivityRule]) -> AppActivityRuleStore {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("vibestick-activity-rule-manager-\(UUID().uuidString)", isDirectory: true)
    return AppActivityRuleStore(
        userRulesURL: directory.appendingPathComponent(AppActivityRuleStore.userRulesFileName),
        bundledRulesOverride: bundledRules)
}
