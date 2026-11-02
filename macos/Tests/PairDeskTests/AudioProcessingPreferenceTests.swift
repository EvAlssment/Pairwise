import XCTest
import LiveKit
@testable import PairDesk

final class AudioProcessingPreferenceTests: XCTestCase {
    func testNoiseSuppressionDefaultsToEnabledAndPersistsTheExplicitChoice() {
        let defaults = makeDefaults()
        XCTAssertTrue(AudioProcessingPreference.noiseSuppressionEnabled(defaults: defaults))

        AudioProcessingPreference.saveNoiseSuppressionEnabled(false, defaults: defaults)
        XCTAssertFalse(AudioProcessingPreference.noiseSuppressionEnabled(defaults: defaults))

        AudioProcessingPreference.saveNoiseSuppressionEnabled(true, defaults: defaults)
        XCTAssertTrue(AudioProcessingPreference.noiseSuppressionEnabled(defaults: defaults))
    }

    func testNoiseSuppressionStatusSeparatesPreferenceFromEffectiveProcessing() {
        XCTAssertEqual(
            NoiseSuppressionStatus.summary(preferenceEnabled: true, microphoneEnabled: false,
                                           effectiveImplementation: nil),
            "Applies when you turn on your microphone."
        )
        XCTAssertEqual(
            NoiseSuppressionStatus.summary(preferenceEnabled: false, microphoneEnabled: true,
                                           effectiveImplementation: .software),
            "Off for this call."
        )
        XCTAssertEqual(
            NoiseSuppressionStatus.summary(preferenceEnabled: false, microphoneEnabled: false,
                                           effectiveImplementation: nil),
            "Off; remains off when you enable your microphone."
        )
        XCTAssertEqual(
            NoiseSuppressionStatus.summary(preferenceEnabled: true, microphoneEnabled: true,
                                           effectiveImplementation: .platform),
            "Active · macOS voice processing"
        )
        XCTAssertEqual(
            NoiseSuppressionStatus.summary(preferenceEnabled: true, microphoneEnabled: true,
                                           effectiveImplementation: .disabled),
            "Requested, but no active processing path is reported."
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "PairDesk.AudioProcessingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
