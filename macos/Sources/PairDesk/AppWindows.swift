import AppKit
import SwiftUI

/// The app's windows, created on demand with AppKit so they can be opened
/// from the status item, the Dock, and state changes, none of which have
/// SwiftUI's openWindow. Each id has one window that is reused.
@MainActor
final class AppWindows {
    static let shared = AppWindows()
    private var windows: [String: NSWindow] = [:]

    /// The SwiftUI sign-in window registers itself at launch.
    func register(_ id: String, _ window: NSWindow) { windows[id] = window }
    func isShown(_ id: String) -> Bool { windows[id]?.isVisible == true }
    func close(_ id: String) { windows[id]?.orderOut(nil) }

    func showSignIn() {
        guard let window = windows["main"] else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showAccount(store: AppStore, loginItem: LoginItemManager) {
        show("account") { Self.hosted(AccountView(store: store).environmentObject(loginItem), title: "PairDesk account") }
    }

    func showSharePicker(store: AppStore) {
        show("share") { Self.hosted(ScreenSharePickerView(store: store), title: "Share your screen") }
    }

    func showTranscript(store: AppStore) {
        show("transcript") { Self.hosted(TranscriptWindow(store: store), title: "PairDesk · Transcript and agent access") }
    }

    func showSharedScreen(store: AppStore) {
        show("screen") {
            let root = SharedScreenWindow(store: store, rtc: store.rtc, transcripts: store.transcripts, agentBridge: store.agentBridge)
                .frame(minWidth: 700, minHeight: 450)
            let window = Self.hosted(root, title: "PairDesk · Shared screen", fixedSize: false)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.contentMinSize = NSSize(width: 700, height: 450)
            let available = (NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900))
            window.setContentSize(NSSize(width: min(1440, available.width - 40), height: min(900, available.height - 40)))
            window.center()
            return window
        }
    }

    /// A notification-style card: top right, above other apps' windows, on
    /// every Space, and shown without activating the app so typing elsewhere
    /// cannot answer the call.
    func showIncomingCall(store: AppStore) {
        let window = show("incoming", activate: false) {
            let window = Self.hosted(IncomingCallView(store: store), title: "Incoming call")
            window.styleMask = [.titled, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            window.isMovableByWindowBackground = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            return window
        }
        window.layoutIfNeeded()
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            window.setFrameTopLeftPoint(NSPoint(x: visible.maxX - window.frame.width - 16, y: visible.maxY - 16))
        }
    }

    @discardableResult
    private func show(_ id: String, activate: Bool = true, make: () -> NSWindow) -> NSWindow {
        let window = windows[id] ?? {
            let created = make()
            windows[id] = created
            return created
        }()
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
        return window
    }

    private static func hosted<Root: View>(_ root: Root, title: String, fixedSize: Bool = true) -> NSWindow {
        let controller = NSHostingController(rootView: root.preferredColorScheme(.dark))
        // Fixed-size windows follow their content; the viewer is sized once
        // and then belongs to the person resizing it.
        controller.sizingOptions = fixedSize ? [.preferredContentSize] : []
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        return window
    }
}
