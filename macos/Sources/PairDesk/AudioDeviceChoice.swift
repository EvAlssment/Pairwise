import Foundation

/// The SDK's default-route alias can have the same name as a physical device.
struct AudioDeviceChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let isDefault: Bool

    var title: String {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDefault { return label.isEmpty ? "System default" : "\(label) (System default)" }
        return label.isEmpty ? "Audio device" : label
    }

    static func unique(_ choices: [AudioDeviceChoice]) -> [AudioDeviceChoice] {
        var seen = Set<String>()
        return choices.filter { seen.insert($0.id).inserted }
    }

    static func resolvedSelection(currentID: String, choices: [AudioDeviceChoice]) -> String? {
        if choices.contains(where: { $0.id == currentID }) { return currentID }
        return choices.first(where: { $0.isDefault })?.id ?? choices.first?.id
    }
}

enum AudioDeviceAvailabilityNotice {
    static func transition(previousInputUnavailable: Bool, previousOutputUnavailable: Bool,
                           inputUnavailable: Bool, outputUnavailable: Bool) -> String? {
        let lostInput = inputUnavailable && !previousInputUnavailable
        let lostOutput = outputUnavailable && !previousOutputUnavailable
        let restoredInput = !inputUnavailable && previousInputUnavailable
        let restoredOutput = !outputUnavailable && previousOutputUnavailable

        if lostInput && lostOutput { return "Selected microphone and speaker unavailable; using system defaults." }
        if lostOutput { return "Selected speaker disconnected; using the system default." }
        if lostInput { return "Selected microphone disconnected; using the system default." }
        if restoredInput && restoredOutput { return "Selected microphone and speaker are available again." }
        if restoredOutput { return "Selected speaker is available again." }
        if restoredInput { return "Selected microphone is available again." }
        return nil
    }
}

struct AudioDeviceAvailabilityNoticeState: Equatable {
    private(set) var message: String?

    mutating func recordTransition(previousInputUnavailable: Bool, previousOutputUnavailable: Bool,
                                   inputUnavailable: Bool, outputUnavailable: Bool) {
        if let next = AudioDeviceAvailabilityNotice.transition(
            previousInputUnavailable: previousInputUnavailable,
            previousOutputUnavailable: previousOutputUnavailable,
            inputUnavailable: inputUnavailable,
            outputUnavailable: outputUnavailable
        ) {
            message = next
        }
    }

    mutating func dismiss() {
        message = nil
    }
}

/// Resolves a persisted CoreAudio device choice against the devices currently
/// visible to LiveKit. Keeping this policy independent of AudioManager lets us
/// cover remove/reconnect behavior without requiring a particular USB device.
struct SavedAudioDeviceSelection: Equatable {
    let selectedDeviceID: String
    let savedDeviceUnavailable: Bool
    let shouldApplyDevice: Bool

    static func resolve(savedDeviceID: String?, availableDeviceIDs: [String], currentDeviceID: String,
                        systemDefaultDeviceID: String) -> Self {
        let available = Set(availableDeviceIDs)
        let savedIsAvailable = savedDeviceID.map(available.contains) ?? false
        let selectedID: String
        if savedIsAvailable, let savedDeviceID {
            selectedID = savedDeviceID
        } else if available.contains(currentDeviceID) {
            selectedID = currentDeviceID
        } else if available.contains(systemDefaultDeviceID) {
            selectedID = systemDefaultDeviceID
        } else if let firstAvailable = availableDeviceIDs.first {
            selectedID = firstAvailable
        } else {
            // There is no valid route to apply. Keep the SDK's value for display
            // until CoreAudio reports a device again, but never claim a fallback.
            selectedID = currentDeviceID
        }

        return Self(selectedDeviceID: selectedID,
                    savedDeviceUnavailable: savedDeviceID != nil && !savedIsAvailable,
                    shouldApplyDevice: available.contains(selectedID) && currentDeviceID != selectedID &&
                        !(currentDeviceID.isEmpty && selectedID == systemDefaultDeviceID))
    }
}
