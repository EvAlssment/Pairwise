import AppKit
import Testing
@preconcurrency import LiveKit
@testable import PairDesk

@Suite(.serialized)
struct SharedScreenPresentationTests {
    @MainActor
    private func fixture() -> (AppStore, AppWindows, NSWindow) {
        _ = NSApplication.shared
        let store = AppStore(callAudio: CallAudioFeedback { _ in nil })
        store.serverAddress = "snapshot.invalid"
        store.rtc.debugSetCall(participants: [], microphoneEnabled: false)
        store.activeRoom = PairRoom(id: "room", name: "Test call", participantCount: 2, participants: [])
        let windows = AppWindows()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.register("screen", window)
        return (store, windows, window)
    }

    @MainActor
    private func settle() async throws { try await Task.sleep(for: .milliseconds(50)) }

    @MainActor
    private final class CloseObserver: NSObject, NSWindowDelegate {
        var didClose = false
        func windowWillClose(_ notification: Notification) { didClose = true }
    }

    @Test @MainActor
    func shareStopClosesViewerAndRestartReopensItWithoutEndingCall() async throws {
        let (store, windows, window) = fixture()
        defer { window.close() }
        let presenter = SharedScreenPresenter(store: store, windows: windows)
        let observer = CloseObserver()
        window.delegate = observer
        let track = await LocalVideoTrack.createBufferTrack(source: .screenShareVideo)
        store.rtc.debugSetScreenShare(track: track, sharer: "peer")
        try await settle()
        #expect(windows.isShown("screen"))
        // The unsubscribe can arrive before the sharer identity is cleared.
        store.rtc.debugSetScreenShare(track: nil, sharer: "peer")
        try await settle()
        #expect(!windows.isShown("screen"))
        #expect(observer.didClose, "Stop sharing must close the native window, not leave an empty viewer")
        #expect(store.rtc.connected)
        #expect(store.activeRoom?.id == "room")
        store.rtc.debugSetScreenShare(track: track, sharer: "peer")
        try await settle()
        #expect(windows.isShown("screen"))
        store.rtc.debugSetScreenShare(track: nil, sharer: nil)
        try await settle()
        #expect(!windows.isShown("screen"))
        withExtendedLifetime(presenter) {}
    }

    @Test @MainActor
    func manualCloseStaysDismissedUntilANewShareArrives() async throws {
        let (store, windows, window) = fixture()
        defer { window.close() }
        let presenter = SharedScreenPresenter(store: store, windows: windows)
        let first = await LocalVideoTrack.createBufferTrack(source: .screenShareVideo)
        store.rtc.debugSetScreenShare(track: first, sharer: "peer")
        try await settle()
        #expect(windows.isShown("screen"))
        window.close()
        store.rtc.debugSetScreenShare(track: first, sharer: "peer")
        try await settle()
        #expect(!windows.isShown("screen"), "Repeated state must not undo a deliberate close")
        let next = await LocalVideoTrack.createBufferTrack(source: .screenShareVideo)
        store.rtc.debugSetScreenShare(track: next, sharer: "peer")
        try await settle()
        #expect(windows.isShown("screen"))
        withExtendedLifetime(presenter) {}
    }

    @Test @MainActor
    func pendingShareLocalShareDisconnectAndCallEndDoNotLeaveEmptyViewer() async throws {
        let (store, windows, window) = fixture()
        defer { window.close() }
        let presenter = SharedScreenPresenter(store: store, windows: windows)
        // A publication can arrive before its subscribed video track.
        store.rtc.debugSetScreenShare(track: nil, sharer: "peer")
        try await settle()
        #expect(!windows.isShown("screen"))
        let track = await LocalVideoTrack.createBufferTrack(source: .screenShareVideo)
        store.rtc.debugSetScreenShare(track: track, sharer: "peer")
        try await settle()
        #expect(windows.isShown("screen"))
        store.rtc.debugSetScreenShare(track: track, sharer: "me", local: true)
        try await settle()
        #expect(!windows.isShown("screen"), "The sharer does not need a remote-viewer window")
        store.rtc.debugSetScreenShare(track: track, sharer: "peer")
        try await settle()
        #expect(windows.isShown("screen"))
        await store.rtc.disconnect()
        try await settle()
        #expect(!windows.isShown("screen"))
        store.rtc.debugSetCall(participants: [], microphoneEnabled: false)
        store.activeRoom = PairRoom(id: "next-room", name: "Next call", participantCount: 2, participants: [])
        store.rtc.debugSetScreenShare(track: track, sharer: "peer")
        try await settle()
        #expect(windows.isShown("screen"))
        store.activeRoom = nil
        try await settle()
        #expect(!windows.isShown("screen"))
        // Late track callbacks cannot reopen a viewer after the call ended.
        store.rtc.debugSetScreenShare(track: track, sharer: "peer")
        try await settle()
        #expect(!windows.isShown("screen"))
        withExtendedLifetime(presenter) {}
    }
}
