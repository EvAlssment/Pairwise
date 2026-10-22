import Foundation

/// The SDK's default-route alias can have the same name as a physical device.
struct AudioDeviceChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let isDefault: Bool

    var title: String { isDefault ? "System default" : name }

    static func unique(_ choices: [AudioDeviceChoice]) -> [AudioDeviceChoice] {
        var seen = Set<String>()
        return choices.filter { seen.insert($0.id).inserted }
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
                    shouldApplyDevice: available.contains(selectedID) && currentDeviceID != selectedID)
    }
}
