import AppKit
import Testing
@testable import PairDesk

@Suite(.serialized)
struct ScreenShareDisplayConfigurationTests {
    @Test @MainActor
    func unchangedScreenNotificationsAndAppSwitchesKeepSharingAndControl() async throws {
        _ = NSApplication.shared
        let rtc = RTCService()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        rtc.debugConfigureScreenClipboard(pasteboard: pasteboard, peer: "viewer", epoch: "lease",
                                           sharing: true, postShortcut: { _ in true })
        #expect(rtc.automaticControlEnabled)
        #expect(rtc.debugControlEpoch == "lease")

        for name in [NSApplication.didResignActiveNotification,
                     NSApplication.didChangeScreenParametersNotification,
                     NSApplication.didChangeScreenParametersNotification] {
            NotificationCenter.default.post(name: name, object: NSApplication.shared)
            try await Task.sleep(for: .milliseconds(50))
            #expect(rtc.isSharing)
            #expect(rtc.automaticControlEnabled, "An unchanged desktop must not pause control or stop capture")
            #expect(rtc.debugControlEpoch == "lease")
        }
    }

    @Test @MainActor
    func realDisplayChangesStillRevokeControl() async throws {
        _ = NSApplication.shared
        let baseline = ScreenShareDisplayConfiguration.current
        let id = try #require(baseline.displays.keys.first)
        let display = try #require(baseline.displays[id])
        var removed = baseline.displays
        removed.removeValue(forKey: id)
        var added = baseline.displays
        added[CGDirectDisplayID.max] = display
        var moved = baseline.displays
        moved[id] = .init(bounds: display.bounds.offsetBy(dx: 100, dy: 0),
                          pixelWidth: display.pixelWidth, pixelHeight: display.pixelHeight, rotation: display.rotation)
        var scaled = baseline.displays
        scaled[id] = .init(bounds: display.bounds, pixelWidth: display.pixelWidth + 100,
                           pixelHeight: display.pixelHeight, rotation: display.rotation)
        var rotated = baseline.displays
        rotated[id] = .init(bounds: display.bounds, pixelWidth: display.pixelWidth,
                            pixelHeight: display.pixelHeight, rotation: display.rotation + 90)
        let changes = [
            ScreenShareDisplayConfiguration(mainDisplayID: baseline.mainDisplayID, displays: removed),
            .init(mainDisplayID: baseline.mainDisplayID, displays: added),
            .init(mainDisplayID: baseline.mainDisplayID, displays: moved),
            .init(mainDisplayID: baseline.mainDisplayID, displays: scaled),
            .init(mainDisplayID: baseline.mainDisplayID, displays: rotated),
            .init(mainDisplayID: CGDirectDisplayID.max, displays: baseline.displays),
        ]

        let rtc = RTCService()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for change in changes {
            rtc.debugConfigureScreenClipboard(pasteboard: pasteboard, peer: "viewer", epoch: "lease",
                                               sharing: true, postShortcut: { _ in true })
            await rtc.handleScreenParametersChange(baseline)
            #expect(rtc.automaticControlEnabled)
            await rtc.handleScreenParametersChange(change)
            #expect(!rtc.automaticControlEnabled, "Changed display geometry must immediately revoke input")
            #expect(rtc.debugControlEpoch == nil)
        }
    }
}
