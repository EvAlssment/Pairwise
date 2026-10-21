import SwiftUI
import AppKit
import Combine

@MainActor
final class AppRuntime {
    static let shared = AppRuntime()
    let store = AppStore()
    let loginItem = LoginItemManager()
    private var started = false
    var suppressInitialWindow = true
    func start() {
        guard !started else { return }
        started = true
        loginItem.prepareInstalledApp()
        Task { await store.restore() }
    }
}

@main
struct PairDeskApp: App {
    @NSApplicationDelegateAdaptor(PairDeskDelegate.self) private var delegate
    @StateObject private var store = AppRuntime.shared.store
    @StateObject private var loginItem = AppRuntime.shared.loginItem
    var body: some Scene {
        // The menu bar and every other window are AppKit (StatusBarController,
        // AppWindows); only the sign-in window is a SwiftUI scene.
        Window("PairDesk", id: "main") {
            RootView(store: store).environmentObject(loginItem).preferredColorScheme(.dark)
                .background(InitialWindowHider())
        }
        .windowStyle(.hiddenTitleBar).windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    AppWindows.shared.showSettings(store: store, loginItem: loginItem)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Stop Remote Control") { store.rtc.revokeControl() }.keyboardShortcut(.escape, modifiers: [.control, .option])
            }
        }
    }
}

@MainActor
final class PairDeskDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore { AppRuntime.shared.store }
    private var statusBar: StatusBarController?
    private var subscriptions = Set<AnyCancellable>()
    private var shownIncomingCallID: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory mode and LSUIElement keep calling in the menu bar. Like
        // Tuple, the Dock icon appears only while a call is active, so the
        // call is reachable with Cmd-Tab and the icon is a reminder it's on.
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        if let directory = ProcessInfo.processInfo.environment["PAIRDESK_SNAPSHOT_DIR"] {
            UISnapshots.render(to: URL(fileURLWithPath: directory, isDirectory: true))
            exit(0)
        }
        #endif
        let store = self.store
        let rtc = store.rtc
        statusBar = StatusBarController(store: store, rtc: rtc, loginItem: AppRuntime.shared.loginItem)
        #if DEBUG
        if ProcessInfo.processInfo.environment["PAIRDESK_PANEL_CHECK"] != nil, let statusBar {
            PanelCheck.run(store: store, statusBar: statusBar)
            return
        }
        if ProcessInfo.processInfo.environment["PAIRDESK_SETTINGS_CHECK"] != nil ||
            ProcessInfo.processInfo.arguments.contains("--settings-preview") {
            AppWindows.shared.showSettings(store: store, loginItem: AppRuntime.shared.loginItem)
            return
        }
        #endif

        // @Published emits before the value lands; each handler hops once so
        // it reads the new state.
        store.$activeRoom.map { $0 != nil }.removeDuplicates().sink { inCall in
            NSApp.setActivationPolicy(inCall ? .regular : .accessory)
        }.store(in: &subscriptions)
        store.$callInvitations.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncIncomingCallWindow() }
        }.store(in: &subscriptions)
        rtc.$activeSharerIdentity.sink { _ in
            Task { @MainActor in
                if rtc.activeSharerIdentity != nil, !rtc.isSharing, rtc.screenTrack != nil { AppWindows.shared.showSharedScreen(store: store) }
            }
        }.store(in: &subscriptions)
        store.$activeRoom.map { $0?.id }.removeDuplicates().sink { id in
            guard id == nil else { return }
            Task { @MainActor in
                AppWindows.shared.close("screen")
                AppWindows.shared.close("share")
                AppWindows.shared.close("transcript")
            }
        }.store(in: &subscriptions)
        AppRuntime.shared.start()
    }

    private func syncIncomingCallWindow() {
        let id = store.incomingCall?.id
        guard id != shownIncomingCallID else { return }
        shownIncomingCallID = id
        if id != nil { AppWindows.shared.showIncomingCall(store: store) } else { AppWindows.shared.close("incoming") }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store.activeRoom != nil else { return .terminateNow }
        Task { await store.leave(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// A Dock click (the icon exists only during a call) opens the panel, as in Tuple.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBar?.showPopover()
        return false
    }
}

private struct InitialWindowHider: NSViewRepresentable {
    func makeNSView(context: Context) -> InitialWindowView { InitialWindowView() }
    func updateNSView(_ nsView: InitialWindowView, context: Context) {}
}
@MainActor
private final class InitialWindowView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        AppWindows.shared.register("main", window)
        guard AppRuntime.shared.suppressInitialWindow else { return }
        AppRuntime.shared.suppressInitialWindow = false
        DispatchQueue.main.async { window.orderOut(nil) }
    }
}
