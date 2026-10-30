import AppKit
import Combine
import SwiftUI

/// The menu bar presence, built on AppKit like Tuple's: a status item whose
/// popover AppKit keeps attached to it, can be opened from the Dock, and a
/// mute button that sits beside the icon during calls. SwiftUI's MenuBarExtra
/// offers none of those.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private(set) static var shared: StatusBarController?

    private let store: AppStore
    private let rtc: RTCService
    private let loginItem: LoginItemManager
    private let item: NSStatusItem
    private var muteItem: NSStatusItem?
    private let popover = NSPopover()
    private let popoverBackground = SurfaceView()
    private var subscriptions = Set<AnyCancellable>()

    init(store: AppStore, rtc: RTCService, loginItem: LoginItemManager) {
        self.store = store
        self.rtc = rtc
        self.loginItem = loginItem
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        // Right clicks reach the action too, so the status menu (and Quit)
        // is available before sign-in, as in every menu bar app.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "PairDesk"

        let content = NSHostingController(rootView: MenuBarPanel(store: store, rtc: rtc, loginItem: loginItem))
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        // @Published emits before the value lands; hop once so reads see the new state.
        Publishers.Merge3(store.$callInvitations.map { _ in () }, store.$activeRoom.map { _ in () },
                          store.$joinRequests.map { _ in () })
            .sink { [weak self] in Task { @MainActor [weak self] in self?.refreshIcon() } }
            .store(in: &subscriptions)
        Publishers.Merge(store.$activeRoom.map { _ in () }, rtc.$isMicrophoneEnabled.map { _ in () })
            .sink { [weak self] in Task { @MainActor [weak self] in self?.refreshMuteItem() } }
            .store(in: &subscriptions)
        refreshIcon()
        refreshMuteItem()
        Self.shared = self
    }

    func showPopover() {
        guard let button = item.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func closePopover() { popover.performClose(nil) }

    private func togglePopover() {
        if popover.isShown { closePopover() } else { showPopover() }
    }

    /// A left click toggles the popover. A right click or Control-click shows
    /// the status menu instead; without it there is no way to quit before
    /// signing in, since the app has no Dock icon outside a call.
    @objc private func statusItemClicked() {
        if Self.opensMenu(NSApp.currentEvent) { showMenu() } else { togglePopover() }
    }

    /// Right clicks and Control-clicks ask for the menu; anything else, and a
    /// code-driven open with no event, is the popover.
    nonisolated static func opensMenu(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseUp || event.modifierFlags.contains(.control)
    }

    private func showMenu() {
        closePopover()
        let menu = NSMenu()
        menu.addItem(menuItem("Open PairDesk", action: #selector(openFromMenu)))
        menu.addItem(menuItem("Settings…", action: #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit PairDesk", action: #selector(quit), key: "q"))
        // A status item with a menu shows it in place of sending its action,
        // so attach the menu for this click only; a plain click afterwards
        // opens the popover again.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    @objc private func openFromMenu() { showPopover() }

    @objc private func showSettings() { AppWindows.shared.showSettings(store: store, loginItem: loginItem) }

    /// Goes through applicationShouldTerminate, which leaves an active call first.
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleMute() {
        let enable = !rtc.isMicrophoneEnabled
        Task { @MainActor in
            do { try await store.setMicrophoneEnabled(enable) }
            catch { store.error = error.localizedDescription }
        }
    }

    private func refreshIcon() {
        let symbol = !store.incomingCallPrompts.isEmpty ? "phone.arrow.down.left" : (store.activeRoom != nil ? "phone.fill" : "rectangle.on.rectangle")
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "PairDesk")
    }

    /// Status items created later sit to the left of earlier ones, so the mute
    /// button appears beside the PairDesk icon for the duration of a call.
    private func refreshMuteItem() {
        guard store.activeRoom != nil else {
            if let muteItem { NSStatusBar.system.removeStatusItem(muteItem) }
            muteItem = nil
            return
        }
        if muteItem == nil {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            created.button?.target = self
            created.button?.action = #selector(toggleMute)
            muteItem = created
        }
        let micOn = rtc.isMicrophoneEnabled
        let image = NSImage(systemSymbolName: micOn ? "mic.fill" : "mic.slash.fill", accessibilityDescription: micOn ? "Mute" : "Unmute")
        // Let macOS keep both states legible against the menu bar background.
        image?.isTemplate = true
        muteItem?.button?.image = image
        muteItem?.button?.contentTintColor = nil
        muteItem?.button?.toolTip = micOn ? "Mute microphone" : "Unmute microphone"
    }

    // MARK: NSPopoverDelegate

    /// Paint the popover frame, arrow included, in the panel's surface color
    /// so the panel reads as one shape.
    func popoverDidShow(_ notification: Notification) {
        guard popoverBackground.superview == nil,
              let frameView = popover.contentViewController?.view.window?.contentView?.superview else { return }
        popoverBackground.frame = frameView.bounds
        popoverBackground.autoresizingMask = [.width, .height]
        frameView.addSubview(popoverBackground, positioned: .below, relativeTo: frameView.subviews.first)
    }
}

/// A view filled with Theme.surface that follows appearance changes.
private final class SurfaceView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); wantsLayer = true }
    override func updateLayer() { layer?.backgroundColor = NSColor(Theme.surface).cgColor }
}
