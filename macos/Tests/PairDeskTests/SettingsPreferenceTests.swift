import XCTest
@testable import PairDesk

final class SettingsPreferenceTests: XCTestCase {
    func testCameraQualityProfilesAndFallback() {
        XCTAssertEqual(CameraVideoQuality.allCases.map(\.dimensions.width), [640, 1280, 1920])
        XCTAssertEqual(CameraVideoQuality.allCases.map(\.dimensions.height), [360, 720, 1080])
        XCTAssertTrue(CameraVideoQuality.allCases.allSatisfy { $0.framesPerSecond == 30 })
        XCTAssertEqual(CameraVideoQuality.load(from: makeDefaults()), .balanced)

        let defaults = makeDefaults()
        defaults.set("unexpected", forKey: CameraVideoQuality.defaultsKey)
        XCTAssertEqual(CameraVideoQuality.load(from: defaults), .balanced)
    }

    func testAccessibilitySystemPromptIsOnlyRequestedOnceAcrossRelaunches() {
        let defaults = makeDefaults()
        let firstLaunch = AccessibilityPromptGate(defaults: defaults)
        XCTAssertTrue(firstLaunch.shouldPrompt(isTrusted: false))
        XCTAssertTrue(firstLaunch.wasRequested)

        let nextLaunch = AccessibilityPromptGate(defaults: defaults)
        XCTAssertFalse(nextLaunch.shouldPrompt(isTrusted: false))
        XCTAssertFalse(AccessibilityPromptGate(defaults: defaults).shouldPrompt(isTrusted: true))
    }

    func testMediaPermissionActionReflectsTheActualSystemAuthorizationState() {
        XCTAssertEqual(MediaPermissionAuthorization(.notDetermined).actionTitle, "Allow")
        XCTAssertEqual(MediaPermissionAuthorization(.authorized).actionTitle, "Settings")
        XCTAssertEqual(MediaPermissionAuthorization(.denied).actionTitle, "Open Settings")
        XCTAssertEqual(MediaPermissionAuthorization(.restricted).actionTitle, "Open Settings")
        XCTAssertTrue(MediaPermissionAuthorization(.authorized).isAuthorized)
        XCTAssertFalse(MediaPermissionAuthorization(.denied).isAuthorized)
    }

    @MainActor
    func testPrivacyVeilPreferencesPersistAndRemoveAppsByBundleIdentifier() throws {
        let defaults = makeDefaults()
        let items = [
            HiddenApplication(bundleIdentifier: "com.example.mail", name: "Mail"),
            HiddenApplication(bundleIdentifier: "com.example.mail", name: "Mail copy"),
            HiddenApplication(bundleIdentifier: "com.example.browser", name: "Browser")
        ]
        defaults.set(try JSONEncoder().encode(items), forKey: PrivacyVeilPreferences.defaultsKey)

        let preferences = PrivacyVeilPreferences(defaults: defaults)
        XCTAssertEqual(preferences.applications.count, 2)
        XCTAssertEqual(preferences.bundleIdentifiers, ["com.example.mail", "com.example.browser"])

        let mail = try XCTUnwrap(preferences.applications.first { $0.bundleIdentifier == "com.example.mail" })
        preferences.remove(mail)
        XCTAssertEqual(preferences.bundleIdentifiers, ["com.example.browser"])

        let reloaded = PrivacyVeilPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.bundleIdentifiers, ["com.example.browser"])
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "PairDesk.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
