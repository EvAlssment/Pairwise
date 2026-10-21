import XCTest
@testable import PairDesk

final class ScreenPrivacyVeilTests: XCTestCase {
    func testOnlyEnumeratedApplicationIdentifiersCanBeExcluded() {
        let selected = PrivacyVeilSelection.resolve(
            ["com.example.private", "com.example.not-running"],
            availableBundleIDs: ["com.example.private", "com.example.editor"]
        )

        XCTAssertEqual(selected, ["com.example.private"])
    }

    func testEmptySelectionKeepsTheDisplayUnfiltered() {
        XCTAssertTrue(PrivacyVeilSelection.resolve([], availableBundleIDs: ["com.example.editor"]).isEmpty)
    }

    func testNotificationFilterRequiresNotificationCenterToBeDiscoverable() {
        XCTAssertNil(PrivacyVeilSelection.notificationBundleIdentifiersToExclude(
            hideNotifications: true, availableBundleIDs: ["com.example.editor"]
        ))
        XCTAssertEqual(PrivacyVeilSelection.notificationBundleIdentifiersToExclude(
            hideNotifications: true, availableBundleIDs: ["com.example.editor", "com.apple.notificationcenterui"]
        ), ["com.apple.notificationcenterui"])
        XCTAssertEqual(PrivacyVeilSelection.notificationBundleIdentifiersToExclude(
            hideNotifications: false, availableBundleIDs: ["com.example.editor"]
        ), [])
    }

    @MainActor
    func testNotificationPreferencePersistsAcrossSettingsReload() {
        let suiteName = "PairDeskPrivacyVeilTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = PrivacyVeilPreferences(defaults: defaults)
        XCTAssertFalse(first.hideNotificationBanners)
        first.hideNotificationBanners = true

        let reloaded = PrivacyVeilPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.hideNotificationBanners)
        XCTAssertTrue(reloaded.protectedBundleIdentifiers.contains("com.apple.notificationcenterui"))
    }
}
