import XCTest
@testable import VibestickApp

final class AppLocalizationTests: XCTestCase {
    func testLanguagePreferenceParsesKnownValuesAndFallsBackToSystem() {
        XCTAssertEqual(AppLanguagePreference.parse("system"), .system)
        XCTAssertEqual(AppLanguagePreference.parse("zh"), .zh)
        XCTAssertEqual(AppLanguagePreference.parse("en"), .en)
        XCTAssertEqual(AppLanguagePreference.parse("bogus"), .system)
        XCTAssertEqual(AppLanguagePreference.parse(nil), .system)
    }

    func testSystemLanguageUsesChineseOnlyForChinesePreferredLocale() {
        XCTAssertEqual(AppLanguagePreference.systemLanguage(preferredLanguages: ["zh-Hans-CN"]), .zh)
        XCTAssertEqual(AppLanguagePreference.systemLanguage(preferredLanguages: ["zh-Hant-TW"]), .zh)
        XCTAssertEqual(AppLanguagePreference.systemLanguage(preferredLanguages: ["en-US"]), .en)
        XCTAssertEqual(AppLanguagePreference.systemLanguage(preferredLanguages: []), .en)
    }

    func testLanguagePreferencePersistsInUserDefaults() {
        let suiteName = "VibestickAppLocalizationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppLanguagePreference.load(defaults: defaults), .system)
        AppLanguagePreference.zh.save(defaults: defaults)
        XCTAssertEqual(AppLanguagePreference.load(defaults: defaults), .zh)
        AppLanguagePreference.en.save(defaults: defaults)
        XCTAssertEqual(AppLanguagePreference.load(defaults: defaults), .en)
    }

    func testLocalizedTextProvidesMainMenuLabels() {
        let zh = LocalizedText(language: .zh)
        let en = LocalizedText(language: .en)

        XCTAssertEqual(zh.openControlPanel, "打开控制面板")
        XCTAssertEqual(en.openControlPanel, "Open Control Panel")
        XCTAssertEqual(zh.languagePreferenceLabel(.system), "跟随系统")
        XCTAssertEqual(en.languagePreferenceLabel(.system), "System")
    }
}
