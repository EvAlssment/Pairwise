import XCTest
@testable import PairDesk

final class ParticipantAudioVolumeTests: XCTestCase {
    func testVolumeClampsToSafeLocalRangeAndDefaultsInvalidValuesToNormal() {
        XCTAssertEqual(ParticipantAudioVolume.clamped(-1), 0)
        XCTAssertEqual(ParticipantAudioVolume.clamped(0.75), 0.75)
        XCTAssertEqual(ParticipantAudioVolume.clamped(8), 1.5)
        XCTAssertEqual(ParticipantAudioVolume.clamped(.nan), 1)
        XCTAssertEqual(ParticipantAudioVolume.clamped(.infinity), 1)
    }

    func testPresetsCoverMuteNormalAndModestBoost() {
        XCTAssertEqual(ParticipantAudioVolumePreset.allCases.map(\.rawValue), [0, 0.5, 0.75, 1, 1.25, 1.5])
        XCTAssertEqual(ParticipantAudioVolumePreset.normal.title, "Normal · 100%")
        XCTAssertEqual(ParticipantAudioVolumePreset.boosted.title, "Boost · 150%")
    }

    func testVolumeIconTracksMutedReducedAndBoostedStates() {
        XCTAssertEqual(ParticipantAudioVolume.symbol(for: 0), "speaker.slash.fill")
        XCTAssertEqual(ParticipantAudioVolume.symbol(for: 0.5), "speaker.wave.1.fill")
        XCTAssertEqual(ParticipantAudioVolume.symbol(for: 1), "speaker.wave.2.fill")
        XCTAssertEqual(ParticipantAudioVolume.symbol(for: 1.25), "speaker.wave.3.fill")
    }

    func testVolumePreferencesPersistPerServerUserAndTeammate() {
        let suite = "PairDesk.ParticipantVolumeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ParticipantAudioVolumePreferences(defaults: defaults)

        let harshit = ParticipantAudioVolumePreferences.scope(
            localIdentity: "harshit", mediaServerURL: "wss://rtc.example.com"
        )!
        let saurab = ParticipantAudioVolumePreferences.scope(
            localIdentity: "saurab", mediaServerURL: "wss://rtc.example.com"
        )!
        preferences.save(["bharat": 0.5, "akshat": 1.5], scope: harshit)
        preferences.save(["bharat": 0.75], scope: saurab)

        XCTAssertEqual(preferences.load(scope: harshit), ["bharat": 0.5, "akshat": 1.5])
        XCTAssertEqual(preferences.load(scope: saurab), ["bharat": 0.75])
        XCTAssertEqual(preferences.load(scope: "unknown@wss://rtc.example.com"), [:])
    }

    func testVolumePreferencesDoNotBleedAcrossMediaServers() {
        let suite = "PairDesk.ParticipantVolumeServerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ParticipantAudioVolumePreferences(defaults: defaults)
        let production = ParticipantAudioVolumePreferences.scope(
            localIdentity: "harshit", mediaServerURL: "wss://RTC.example.com"
        )!
        let staging = ParticipantAudioVolumePreferences.scope(
            localIdentity: "harshit", mediaServerURL: "wss://rtc.example.net"
        )!

        preferences.save(["bharat": 0.5], scope: production)

        XCTAssertEqual(preferences.load(scope: production), ["bharat": 0.5])
        XCTAssertEqual(preferences.load(scope: staging), [:])
        XCTAssertEqual(production, "harshit@wss://rtc.example.com")
    }

    func testVolumePreferenceScopeIncludesPortAndTenantPathButNotQuery() {
        XCTAssertEqual(
            ParticipantAudioVolumePreferences.scope(
                localIdentity: "harshit", mediaServerURL: "wss://rtc.example.com:7880/team-a?token=secret"
            ),
            "harshit@wss://rtc.example.com:7880/team-a"
        )
        XCTAssertNil(ParticipantAudioVolumePreferences.scope(localIdentity: "harshit", mediaServerURL: "invalid"))
    }
}
