import Foundation
import LiveKit

enum AudioProcessingPreference {
    static let noiseSuppressionKey = "audioNoiseSuppressionEnabled.v1"

    static func noiseSuppressionEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: noiseSuppressionKey) as? Bool ?? true
    }

    static func saveNoiseSuppressionEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: noiseSuppressionKey)
    }
}

enum NoiseSuppressionStatus {
    static func summary(preferenceEnabled: Bool,
                       microphoneEnabled: Bool,
                       effectiveImplementation: AudioProcessingImplementation?) -> String {
        guard preferenceEnabled else {
            return microphoneEnabled ? "Off for this call." : "Off; remains off when you enable your microphone."
        }
        guard microphoneEnabled else { return "Applies when you turn on your microphone." }

        return switch effectiveImplementation {
        case .software?: "Active · software processing"
        case .platform?: "Active · macOS voice processing"
        case .softwareAndPlatform?: "Active · software and macOS processing"
        case .disabled?: "Requested, but no active processing path is reported."
        case .unknown?, nil: "Requested · live status unavailable"
        }
    }
}
