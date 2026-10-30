#if DEBUG
import AppKit
import SwiftUI

/// PAIRDESK_PANEL_CHECK=1 opens the status item popover from code, as a Dock
/// click does, toggles a fixture roster between tall and short, and prints
/// where the popover's top edge sits relative to the status item each time.
/// Debug builds only; no server, no saved session.
@MainActor
enum PanelCheck {
    static func run(store: AppStore, statusBar: StatusBarController) {
        let me = TeamUser(id: "me", name: "Bharat Hasija", email: "bharat@example.com", online: true, busy: false, admin: true, enabled: true)
        let team = (1...6).map { TeamUser(id: "t\($0)", name: "Test person \($0)", email: "t\($0)@example.com", online: $0 % 2 == 0, busy: false, enabled: true) }
        store.serverAddress = "snapshot.invalid"
        store.user = me
        store.users = [me] + team
        store.directoryStatus = "Team connected"
        Task {
            try? await Task.sleep(for: .seconds(1))
            statusBar.showPopover()
            try? await Task.sleep(for: .seconds(1))
            guard let status = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("StatusBar") }),
                  let popover = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("Popover") }) else {
                print("popover not found; windows: \(NSApp.windows.map { String(describing: type(of: $0)) })")
                exit(2)
            }
            print("popover opened from code: \(popover.isVisible); top edge \(Int(status.frame.minY - popover.frame.maxY)) pt below the status item; height=\(Int(popover.frame.height))")
            var tall = true
            for _ in 0..<4 {
                tall.toggle()
                store.users = tall ? [me] + team : [me, team[1]]
                try? await Task.sleep(for: .seconds(1.2))
                print("roster \(tall ? "tall " : "short") height=\(Int(popover.frame.height))  top edge \(Int(status.frame.minY - popover.frame.maxY)) pt below the status item  x=\(Int(popover.frame.midX - status.frame.midX)) pt off the icon's center")
                fflush(stdout)
            }
            exit(0)
        }
    }
}

/// Renders key screens with fixture data to PNG files so UI changes can be
/// reviewed without a server, a call, or clicking through the menu bar.
/// Debug builds only:
///
///     PAIRDESK_SNAPSHOT_DIR=/tmp/pairdesk-shots swift run
///
/// The app exits after rendering and never calls AppRuntime.start(), so it
/// does not read the saved session. Fixture stores point at an invalid server
/// address, so a view's refresh fails locally instead of reaching a server
/// (a 401 there would clear the saved session).
@MainActor
enum UISnapshots {
    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let loginItem = LoginItemManager()
        let me = TeamUser(id: "me", name: "Bharat Hasija", email: "bharat@example.com", online: true, busy: false, admin: true, enabled: true)
        let harshit = TeamUser(id: "harshit", name: "Harshit", email: "harshit@example.com", online: true, busy: false, enabled: true)
        let team = [
            me, harshit,
            TeamUser(id: "alex", name: "Alex Rivera", email: "alex@example.com", online: true, busy: true, enabled: true),
            TeamUser(id: "sam", name: "Sam Lee", email: "sam@example.com", online: false, busy: false, enabled: true)
        ]
        let room = PairRoom(id: "room", name: "Direct call", participantCount: 1, participants: [])
        func store(_ configure: (AppStore) -> Void = { _ in }) -> AppStore {
            let store = AppStore()
            store.serverAddress = "snapshot.invalid"
            configure(store)
            return store
        }
        func invitation(from caller: TeamUser, to target: TeamUser) -> CallInvitation {
            CallInvitation(id: "call-\(caller.id)-\(target.id)", status: "pending", caller: caller, target: target, room: room, expiresAt: "")
        }

        let signedOut = store()
        let idle = store { $0.user = me; $0.users = team; $0.directoryStatus = "Team connected" }
        let ringing = store {
            $0.user = me; $0.users = team; $0.directoryStatus = "Team connected"
            $0.activeRoom = room; $0.callInvitations = [invitation(from: me, to: harshit)]
        }
        let incoming = store {
            $0.user = me; $0.users = team; $0.directoryStatus = "Team connected"
            $0.callInvitations = [invitation(from: harshit, to: me)]
        }
        let joinableRoom = PairRoom(id: "active-room", name: "Direct call", participantCount: 2, participants: [
            TeamUser(id: "alex", name: "Alex Rivera", email: "alex@example.com", online: true, busy: true, enabled: true),
            TeamUser(id: "saurab", name: "Saurab", email: "saurab@example.com", online: true, busy: true, enabled: true)
        ])

        snapshot("menu-signed-out", to: directory, compact: true) { MenuBarPanel(store: signedOut, rtc: signedOut.rtc, loginItem: loginItem) }
        snapshot("menu-roster", to: directory, compact: true) { MenuBarPanel(store: idle, rtc: idle.rtc, loginItem: loginItem) }
        let pair = store {
            $0.user = me; $0.directoryStatus = "Team connected"
            $0.users = [me, harshit, TeamUser(id: "saurab", name: "Saurab", email: "saurab@example.com", online: false, busy: false, enabled: true)]
        }
        snapshot("menu-roster-two", to: directory, compact: true) { MenuBarPanel(store: pair, rtc: pair.rtc, loginItem: loginItem) }
        let crowd = store {
            $0.user = me; $0.directoryStatus = "Team connected"
            $0.users = [me] + (1...14).map { TeamUser(id: "t\($0)", name: "Teammate \($0)", email: "t\($0)@example.com", online: $0 <= 6, busy: $0 == 2, enabled: true) }
        }
        snapshot("menu-roster-many", to: directory, compact: true) { MenuBarPanel(store: crowd, rtc: crowd.rtc, loginItem: loginItem) }
        snapshot("menu-ringing", to: directory, compact: true) { MenuBarPanel(store: ringing, rtc: ringing.rtc, loginItem: loginItem) }
        snapshot("menu-incoming", to: directory, compact: true) { MenuBarPanel(store: incoming, rtc: incoming.rtc, loginItem: loginItem) }
        let inCall = store {
            $0.user = me; $0.users = team; $0.directoryStatus = "Team connected"
            $0.activeRoom = room; $0.callStartedAt = Date().addingTimeInterval(-185)
            $0.rtc.debugSetCall(participants: [CallParticipant(identity: me.id, name: me.name, isLocal: true),
                                               CallParticipant(identity: harshit.id, name: harshit.name, isLocal: false, isSpeaking: true, isMicrophoneMuted: false)],
                                microphoneEnabled: true)
        }
        snapshot("menu-in-call", to: directory, compact: true) { MenuBarPanel(store: inCall, rtc: inCall.rtc, loginItem: loginItem) }
        let joinRequestCall = store {
            $0.user = me; $0.users = team; $0.directoryStatus = "Team connected"
            $0.activeRoom = room; $0.callStartedAt = Date().addingTimeInterval(-62)
            $0.joinRequests = [CallJoinRequest(id: "join-request", status: "pending", requester: team[3], room: PairRoom(id: "room", name: "Direct call", participantCount: 2, participants: [me, harshit]), expiresAt: "")]
            $0.rtc.debugSetCall(participants: [CallParticipant(identity: me.id, name: me.name, isLocal: true),
                                               CallParticipant(identity: harshit.id, name: harshit.name, isLocal: false)],
                                microphoneEnabled: true)
        }
        snapshot("menu-in-call-join-request", to: directory, compact: true) { MenuBarPanel(store: joinRequestCall, rtc: joinRequestCall.rtc, loginItem: loginItem) }
        let joinable = store {
            $0.user = me; $0.users = team; $0.directoryStatus = "Team connected"
            $0.activeTeamCalls = [joinableRoom]
        }
        snapshot("menu-joinable-team-call", to: directory, compact: true) { MenuBarPanel(store: joinable, rtc: joinable.rtc, loginItem: loginItem) }
        let joinPending = store {
            $0.user = me; $0.users = team; $0.directoryStatus = "Team connected"
            $0.activeTeamCalls = [joinableRoom]
            $0.joinRequests = [CallJoinRequest(id: "outgoing-join-request", status: "pending", requester: me, room: joinableRoom, expiresAt: "")]
        }
        snapshot("menu-join-request-pending", to: directory, compact: true) { MenuBarPanel(store: joinPending, rtc: joinPending.rtc, loginItem: loginItem) }
        let muted = store {
            $0.user = me; $0.users = team; $0.directoryStatus = "Team connected"
            $0.activeRoom = room; $0.callStartedAt = Date().addingTimeInterval(-62)
            $0.rtc.debugSetCall(participants: [CallParticipant(identity: me.id, name: me.name, isLocal: true),
                                               CallParticipant(identity: harshit.id, name: harshit.name, isLocal: false)],
                                microphoneEnabled: false)
        }
        snapshot("menu-in-call-muted", to: directory, compact: true) { MenuBarPanel(store: muted, rtc: muted.rtc, loginItem: loginItem) }
        let microphoneStates = store {
            $0.user = me; $0.users = team; $0.directoryStatus = "Team connected"
            $0.activeRoom = room
            $0.rtc.debugSetCall(participants: [CallParticipant(identity: me.id, name: me.name, isLocal: true),
                                               CallParticipant(identity: harshit.id, name: harshit.name, isLocal: false),
                                               CallParticipant(identity: team[2].id, name: team[2].name, isLocal: false, isMicrophoneMuted: false),
                                               CallParticipant(identity: team[3].id, name: team[3].name, isLocal: false, isSpeaking: true, isMicrophoneMuted: false)],
                                microphoneEnabled: true)
        }
        snapshot("menu-microphone-states", to: directory, compact: true) { MenuBarPanel(store: microphoneStates, rtc: microphoneStates.rtc, loginItem: loginItem) }
        let syncing = store {
            $0.user = me; $0.users = team; $0.directoryStatus = "Team connected"
            $0.activeRoom = room; $0.callStartedAt = Date().addingTimeInterval(-410)
            $0.rtc.debugSetCall(participants: [CallParticipant(identity: me.id, name: me.name, isLocal: true),
                                               CallParticipant(identity: harshit.id, name: harshit.name, isLocal: false)],
                                microphoneEnabled: true, clipboardSync: true)
        }
        snapshot("menu-in-call-clipboard-sync", to: directory, compact: true) { MenuBarPanel(store: syncing, rtc: syncing.rtc, loginItem: loginItem) }
        snapshot("window-incoming-call", to: directory) { IncomingCallView(store: incoming) }
        snapshot("window-incoming-join-request", to: directory) { IncomingCallView(store: joinRequestCall) }
        snapshot("window-sign-in", to: directory) { RootView(store: signedOut).environmentObject(loginItem) }
        snapshot("window-sign-up", to: directory) { LoginView(store: signedOut, creatingAccount: true) }
        snapshot("window-signed-in", to: directory) { RootView(store: idle).environmentObject(loginItem) }
        snapshot("window-settings", to: directory, size: CGSize(width: 960, height: 660)) {
            SettingsView(store: idle, rtc: idle.rtc, loginItem: loginItem)
        }
        snapshot("window-settings-audio-test", to: directory, size: CGSize(width: 960, height: 660)) {
            SettingsView(store: idle, rtc: idle.rtc, loginItem: loginItem, initialSection: .audio)
        }
        snapshot("window-settings-screen-share", to: directory, size: CGSize(width: 960, height: 660)) {
            SettingsView(store: idle, rtc: idle.rtc, loginItem: loginItem, initialSection: .screenShare)
        }
        snapshot("window-settings-camera-test", to: directory, size: CGSize(width: 960, height: 660)) {
            SettingsView(store: idle, rtc: idle.rtc, loginItem: loginItem, initialSection: .camera)
        }
        snapshot("window-camera-gallery-empty", to: directory, size: CGSize(width: 1120, height: 760)) {
            CameraGalleryView(rtc: inCall.rtc)
        }
        snapshot("window-clipboard-sharing", to: directory, size: CGSize(width: 520, height: 520)) {
            ClipboardTransferView(
                peers: [ClipboardPeer(identity: "harshit", name: "Harshit"), ClipboardPeer(identity: "bharat", name: "Bharat")],
                incoming: nil,
                onSend: { _, _ in }, onPaste: {}, onDismiss: {},
                clipboardSyncEnabled: false, clipboardSyncNotice: nil, onToggleSync: { _ in }, screenSharingActive: true
            )
            .padding(20)
            .frame(width: 480)
        }
        snapshot("window-permissions", to: directory) { PermissionsView() }
        snapshot("window-permissions-duplicate-copies", to: directory) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Privacy and access").font(.title2.bold())
                Text("This copy: /Applications/PairDesk.app")
                    .font(.caption).foregroundStyle(.secondary)
                DuplicateAppCopyWarning(paths: [
                    "/Volumes/PairDesk/PairDesk.app",
                    "/Users/teammate/Downloads/PairDesk.app"
                ])
            }
            .padding(26)
            .frame(width: 490)
        }
        snapshot("window-account", to: directory) { AccountView(store: idle).environmentObject(loginItem) }
        snapshot("window-share-picker", to: directory) { ScreenSharePickerView(store: ringing) }
        snapshot("window-shared-screen", to: directory, size: CGSize(width: 1000, height: 620)) {
            SharedScreenWindow(store: microphoneStates, rtc: microphoneStates.rtc, transcripts: microphoneStates.transcripts)
        }
        snapshot("separate-cursors", to: directory, size: CGSize(width: 1000, height: 620)) {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Separate cursors").font(.title2.bold())
                    Text("Move independently. Click, drag, scroll and type one at a time.").foregroundStyle(.secondary)
                    Spacer()
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                SharedCursorLayer(pointers: [RemotePointer(id: "harshit", x: 0.32, y: 0.35, updatedAt: .now),
                                            RemotePointer(id: "bharat", x: 0.65, y: 0.58, updatedAt: .now),
                                            RemotePointer(id: "saurab", x: 0.96, y: 0.94, updatedAt: .now)],
                                  names: ["harshit": "Harshit", "bharat": "Bharat", "saurab": "Saurab"],
                                  contentSize: CGSize(width: 1920, height: 1080))
            }
        }
        print("Rendered UI snapshots to \(directory.path)")
    }

    /// `compact` renders at the smallest height the view accepts, which is
    /// what MenuBarExtra's window settles on; ideal-height renders hide
    /// views that collapse there.
    private static func snapshot<V: View>(_ name: String, to directory: URL, size: CGSize? = nil, compact: Bool = false, @ViewBuilder _ content: () -> V) {
        let view = content()
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        let ideal = host.fittingSize
        let compactSize = compact ? NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: ideal.width, height: 0)) : ideal
        let frame = NSRect(origin: .zero, size: size ?? compactSize)
        let window = NSWindow(contentRect: frame.offsetBy(dx: -20_000, dy: -20_000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        host.frame = frame
        window.orderFrontRegardless()
        NSApp.updateWindows()
        // NavigationSplitView and several AppKit-backed SwiftUI controls do
        // not finish their first layout pass until their window is ordered.
        // Drain a short slice of the main run loop so the cached bitmap
        // reflects the same laid-out hierarchy a person sees in the app.
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        defer { window.close() }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        do { try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png")) }
        catch { print("Could not write \(name).png: \(error.localizedDescription)") }
    }
}
#endif
