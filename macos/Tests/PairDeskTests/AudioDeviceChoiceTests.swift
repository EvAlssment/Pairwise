import XCTest
@testable import PairDesk

final class AudioDeviceChoiceTests: XCTestCase {
    func testSystemDefaultAliasDoesNotRepeatTheHardwareLabel() {
        let choices = AudioDeviceChoice.unique([
            .init(id: "default", name: "MacBook Pro Microphone", isDefault: true),
            .init(id: "built-in-mic", name: "MacBook Pro Microphone", isDefault: false),
            .init(id: "phone-mic", name: "iPhone Microphone", isDefault: false)
        ])
        XCTAssertEqual(choices.map(\.title), ["System default", "MacBook Pro Microphone", "iPhone Microphone"])
        XCTAssertEqual(choices.map(\.id), ["default", "built-in-mic", "phone-mic"])
    }

    func testRepeatedDeviceIDsAreRemovedWithoutHidingDistinctHardware() {
        let choices = AudioDeviceChoice.unique([
            .init(id: "default", name: "USB Speaker", isDefault: true),
            .init(id: "default", name: "USB Speaker", isDefault: true),
            .init(id: "usb-1", name: "USB Speaker", isDefault: false),
            .init(id: "usb-1", name: "USB Speaker", isDefault: false),
            .init(id: "usb-2", name: "USB Speaker", isDefault: false)
        ])
        XCTAssertEqual(choices.map(\.id), ["default", "usb-1", "usb-2"])
        XCTAssertEqual(choices.map(\.title), ["System default", "USB Speaker", "USB Speaker"])
    }

    func testDefaultRouteKeepsItsSelectionWhenTheSystemChangesDevices() {
        let builtIn = AudioDeviceChoice(id: "default", name: "MacBook Pro Speakers", isDefault: true)
        let headphones = AudioDeviceChoice(id: "default", name: "Headphones", isDefault: true)
        XCTAssertEqual(builtIn.id, headphones.id)
        XCTAssertEqual(builtIn.title, headphones.title)
        XCTAssertTrue(AudioDeviceChoice.unique([]).isEmpty)
    }

    func testSavedAudioDeviceFallsBackAndRestoresAcrossHotPlugSnapshots() {
        let attached = SavedAudioDeviceSelection.resolve(
            savedDeviceID: "usb-headset",
            availableDeviceIDs: ["system-default", "usb-headset"],
            currentDeviceID: "system-default",
            systemDefaultDeviceID: "system-default"
        )
        XCTAssertEqual(attached, SavedAudioDeviceSelection(selectedDeviceID: "usb-headset",
                                                           savedDeviceUnavailable: false,
                                                           shouldApplyDevice: true))

        let removed = SavedAudioDeviceSelection.resolve(
            savedDeviceID: "usb-headset",
            availableDeviceIDs: ["system-default"],
            currentDeviceID: "usb-headset",
            systemDefaultDeviceID: "system-default"
        )
        XCTAssertEqual(removed, SavedAudioDeviceSelection(selectedDeviceID: "system-default",
                                                          savedDeviceUnavailable: true,
                                                          shouldApplyDevice: true))

        let restored = SavedAudioDeviceSelection.resolve(
            savedDeviceID: "usb-headset",
            availableDeviceIDs: ["system-default", "usb-headset"],
            currentDeviceID: "system-default",
            systemDefaultDeviceID: "system-default"
        )
        XCTAssertEqual(restored, attached)
    }

    func testNoSavedAudioDeviceLeavesTheCurrentSystemRouteAlone() {
        XCTAssertEqual(SavedAudioDeviceSelection.resolve(savedDeviceID: nil,
                                                         availableDeviceIDs: ["system-default"],
                                                         currentDeviceID: "system-default",
                                                         systemDefaultDeviceID: "system-default"),
                       SavedAudioDeviceSelection(selectedDeviceID: "system-default",
                                                 savedDeviceUnavailable: false,
                                                 shouldApplyDevice: false))
    }

    func testStaleCurrentRouteFallsBackToSystemDefaultOrAnAvailableDevice() {
        let defaultRoute = SavedAudioDeviceSelection.resolve(savedDeviceID: nil,
                                                              availableDeviceIDs: ["system-default"],
                                                              currentDeviceID: "removed-device",
                                                              systemDefaultDeviceID: "system-default")
        XCTAssertEqual(defaultRoute, SavedAudioDeviceSelection(selectedDeviceID: "system-default",
                                                               savedDeviceUnavailable: false,
                                                               shouldApplyDevice: true))

        let firstAvailable = SavedAudioDeviceSelection.resolve(savedDeviceID: nil,
                                                                availableDeviceIDs: ["usb-speaker"],
                                                                currentDeviceID: "removed-device",
                                                                systemDefaultDeviceID: "also-removed")
        XCTAssertEqual(firstAvailable.selectedDeviceID, "usb-speaker")
        XCTAssertTrue(firstAvailable.shouldApplyDevice)
    }
}
