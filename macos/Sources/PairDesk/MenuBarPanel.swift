import AppKit
import SwiftUI

struct MenuBarPanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var rtc: RTCService
    @ObservedObject var loginItem: LoginItemManager
    @ObservedObject private var permissions = PermissionManager.shared
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if store.user == nil {
                Text(store.busy ? "Restoring your session…" : "Sign in to call your team.").foregroundStyle(Theme.textMuted)
                Button("Sign in") { show("main") }.buttonStyle(PrimaryButtonStyle()).disabled(store.busy)
            } else {
                statusRow
                ForEach(store.approvedJoinRequests) { request in
                    HStack {
                        Text("Your request to join \(callNames(request.room)) was approved.").font(.caption)
                        Spacer()
                        Button("Retry joining") { Task { await store.retryApprovedJoinRequest(request) } }
                            .buttonStyle(PrimaryButtonStyle()).disabled(store.busy)
                    }
                }
                if let incoming = store.incomingCall { incomingCall(incoming) }
                if store.activeRoom != nil {
                    inCall
                    Divider()
                    roster
                } else {
                    roster
                }
                if let message = store.callMessage { Text(message).font(.caption).foregroundStyle(Theme.textMuted) }
                if let error = store.error ?? rtc.error {
                    HStack(alignment: .top, spacing: 8) {
                        Text(error).font(.caption).foregroundStyle(Theme.attention).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Dismiss") {
                            store.error = nil
                            rtc.dismissError()
                        }.buttonStyle(QuietButtonStyle(compact: true))
                    }
                }
            }
        }
        .padding(16).frame(width: Theme.panelWidth)
        .background(Theme.surface)
        .tint(Theme.accent)
        .onAppear { if store.user != nil { Task { await store.refresh() } } }
        .task {
            while !Task.isCancelled {
                permissions.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissions.refresh() }
    }

    // MARK: Header and status

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
            Text("PairDesk").font(.system(size: 15, weight: .semibold))
            Spacer()
            if let user = store.user { PersonAvatar(name: user.name, id: user.id, size: 26).help(user.name) }
            Button {
                AppWindows.shared.showSettings(store: store, loginItem: loginItem)
            } label: {
                Image(systemName: "gearshape").font(.system(size: 14)).foregroundStyle(Theme.textMuted)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings").accessibilityLabel("Settings")
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle().fill(teamConnected ? Theme.online : Theme.attention).frame(width: 6, height: 6)
            Text(store.directoryStatus).font(.caption).foregroundStyle(Theme.textMuted)
            Spacer()
            Text("\(teammates.count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.textMuted)
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise").font(.caption).foregroundStyle(Theme.textMuted)
            }.buttonStyle(.plain).help("Refresh contacts").accessibilityLabel("Refresh contacts")
        }
    }

    private var teamConnected: Bool { store.directoryStatus == "Team connected" }

    private func incomingCall(_ incoming: CallInvitation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PersonAvatar(name: incoming.caller.name, id: incoming.caller.id, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(incoming.caller.name).font(.system(size: 13, weight: .semibold))
                    Text("Incoming call…").font(.caption).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Button("Decline") { Task { await store.declineCall(incoming) } }.buttonStyle(DangerButtonStyle())
                Button("Accept") { Task { await store.acceptCall(incoming) } }.buttonStyle(PrimaryButtonStyle())
            }.disabled(store.busy)
            Divider()
        }
    }

    // MARK: In a call

    private var inCall: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(rtc.isSharing || rtc.screenTrack != nil ? "Screen share" : "Audio call").font(.system(size: 13, weight: .semibold))
                if let started = store.callStartedAt {
                    Text("·").foregroundStyle(Theme.textMuted)
                    Text(started, style: .timer).font(.system(size: 13).monospacedDigit()).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                if rtc.isReconnecting {
                    Label(rtc.isSharing ? "Reconnecting · control paused" : "Reconnecting…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(Theme.attention).lineLimit(1)
                }
            }
            if rtc.isSharing, let quality = rtc.adaptiveShareStatus {
                Text("Screen quality · \(quality)")
                    .font(.caption).foregroundStyle(Theme.textMuted)
            }
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("ON THIS CALL · \(rtc.participants.filter { !$0.isLocal }.count + 1)")
                ForEach(rtc.participants.filter { !$0.isLocal }) { person in
                    HStack(spacing: 10) {
                        PersonAvatar(name: person.name, id: person.identity, size: 28)
                        Text(person.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer()
                        ParticipantMicrophoneStatus(participant: person)
                    }
                }
                ForEach(store.outgoingCalls) { invitation in
                    HStack(spacing: 10) {
                        PersonAvatar(name: invitation.target.name, id: invitation.target.id, size: 28).opacity(0.6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(invitation.target.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text("Calling…").font(.caption).foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        Button("Cancel") { Task { await store.cancelCall(invitation) } }.buttonStyle(QuietButtonStyle(compact: true))
                    }
                }
            }
            CameraStrip(feeds: rtc.cameraFeeds)
            Button { show("transcript") } label: {
                Label("Transcript and local agent access…", systemImage: "text.quote")
                    .font(.system(size: 11, weight: .medium))
            }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            if !store.incomingJoinRequests.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader("JOIN REQUESTS")
                    ForEach(store.incomingJoinRequests) { request in
                        HStack(spacing: 8) {
                            PersonAvatar(name: request.requester.name, id: request.requester.id, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(request.requester.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text("Wants to join this call").font(.caption).foregroundStyle(Theme.textMuted)
                            }
                            Spacer(minLength: 4)
                            Button("Decline") { Task { await store.declineJoinRequest(request) } }
                                .buttonStyle(QuietButtonStyle(compact: true)).disabled(store.busy)
                            Button("Accept") { Task { await store.acceptJoinRequest(request) } }
                                .buttonStyle(PrimaryButtonStyle()).disabled(store.busy || !store.canAddPerson)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                CallTile(title: rtc.isMicrophoneEnabled ? "Mute me" : "Unmute me",
                         systemImage: rtc.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill",
                         highlight: rtc.isMicrophoneEnabled ? nil : Theme.attention,
                         level: rtc.isMicrophoneEnabled ? rtc.localMicrophoneLevel : nil,
                         action: { Task { do { try await store.setMicrophoneEnabled(!rtc.isMicrophoneEnabled) } catch { store.error = error.localizedDescription } } }) {
                    audioDeviceMenu
                }
                CallTile(title: rtc.isCameraEnabled ? "Camera on" : "Camera off",
                         systemImage: rtc.isCameraEnabled ? "video.fill" : "video.slash.fill",
                         highlight: rtc.isCameraEnabled ? Theme.accent : nil,
                         action: { Task { do { try await rtc.setCameraEnabled(!rtc.isCameraEnabled) } catch { store.error = error.localizedDescription } } }) {
                    if rtc.isCameraEnabled && rtc.cameraDevices.count > 1 {
                        Section("Choose camera") {
                            ForEach(rtc.cameraDevices) { device in
                                Button {
                                    Task { await rtc.selectCamera(device.id) }
                                } label: {
                                    if device.id == rtc.selectedCameraID {
                                        Label(device.name, systemImage: "checkmark")
                                    } else {
                                        Text(device.name)
                                    }
                                }
                            }
                        }
                        Divider()
                    }
                    Button("Camera privacy settings…") { PermissionManager.shared.open("Privacy_Camera") }
                }
                CallTile(title: rtc.isSharing ? "Stop sharing" : "Share screen",
                         systemImage: rtc.isSharing ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle",
                         highlight: rtc.isSharing ? Theme.accent : nil,
                         action: { if rtc.isSharing { Task { await store.stopSharing() } } else { show("share") } }) {
                    if !rtc.isSharing, rtc.screenTrack != nil {
                        Button("Show shared screen") { show("screen") }
                        Divider()
                    }
                    Section(rtc.isSharing ? "Change source" : "Share") {
                        ForEach(ScreenShareSource.allCases) { source in
                            Button("\(source.title)…") { chooseShareSource(source) }
                                .disabled(store.busy)
                        }
                    }
                }
            }
            if !permissions.microphone && !rtc.isMicrophoneEnabled {
                Button("Microphone access needed to talk…") { show("permissions") }.buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent)
            }
            if rtc.isSharing { sharingStatus }
            if rtc.isSharing && !rtc.isSharingWindow {
                Toggle("Allow screen annotations", isOn: Binding(
                    get: { rtc.annotationsAllowed },
                    set: { rtc.setAnnotationsAllowed($0) }
                ))
                .font(.caption)
            }
            if let notice = rtc.cameraDeviceNotice {
                Text(notice).font(.caption).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            if rtc.clipboardSharingEnabled { clipboardSyncStatus }
            HStack {
                if !store.canAddPerson {
                    Text("Call is full · four people").font(.caption).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Button("End call") { Task { await store.leave() } }.buttonStyle(DangerButtonStyle())
            }
        }
    }

    @ViewBuilder
    private var audioDeviceMenu: some View {
        Section("Microphone") {
            if rtc.savedAudioInputUnavailable { Text("Saved microphone unavailable; using system default") }
            if rtc.audioInputDevices.isEmpty { Text("No microphones found") }
            ForEach(rtc.audioInputDevices) { device in
                Button { rtc.selectAudioInput(device.id) } label: {
                    if rtc.selectedAudioInputID == device.id { Label(device.title, systemImage: "checkmark") } else { Text(device.title) }
                }
            }
        }
        Section("Speaker") {
            if rtc.savedAudioOutputUnavailable { Text("Saved speaker unavailable; using system default") }
            if rtc.audioOutputDevices.isEmpty { Text("System default") }
            ForEach(rtc.audioOutputDevices) { device in
                Button { rtc.selectAudioOutput(device.id) } label: {
                    if rtc.selectedAudioOutputID == device.id { Label(device.title, systemImage: "checkmark") } else { Text(device.title) }
                }
            }
        }
    }

    /// Sync shares every copy with the call, so it stays visible outside the
    /// clipboard sheet, with the way to stop it.
    private var clipboardSyncStatus: some View {
        HStack(spacing: 8) {
            Label(rtc.clipboardSyncNotice ?? "Clipboard sync is on", systemImage: "doc.on.clipboard")
                .font(.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
            Spacer(minLength: 4)
            if !rtc.automaticScreenClipboardEnabled {
                Button("Turn off") { rtc.setClipboardSyncEnabled(false) }.buttonStyle(QuietButtonStyle(compact: true))
            }
        }
    }

    private var sharingStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rtc.privacyVeilNotificationsHidden {
                Label("Notification banners are hidden from the shared display", systemImage: "bell.slash.fill")
                    .font(.caption).foregroundStyle(Theme.attention)
            }
            if !rtc.privacyVeilAppNames.isEmpty {
                Label("Apps hidden from the shared display", systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(Theme.attention)
                Text(rtc.privacyVeilAppNames.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !rtc.privacyVeilWindowNames.isEmpty {
                Label("Windows hidden for this share", systemImage: "macwindow.badge.shield.half.filled")
                    .font(.caption).foregroundStyle(Theme.attention)
                Text(rtc.privacyVeilWindowNames.joined(separator: ", "))
                    .font(.caption).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if rtc.privacyVeilActive {
                Text("Remote control is disabled while protected content is hidden.")
                    .font(.caption).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let controller = rtc.activeControllerIdentity {
                Label("\(rtc.participantName(for: controller)) is controlling your Mac", systemImage: "cursorarrow.motionlines")
                    .font(.caption).foregroundStyle(Theme.textMuted)
            } else if rtc.remoteControlAvailable && rtc.automaticControlEnabled {
                Label("Separate cursors · click or type to control", systemImage: "cursorarrow").font(.caption).foregroundStyle(Theme.textMuted)
            }
            if rtc.remoteControlAvailable {
                Button(rtc.automaticControlEnabled ? "Stop control" : "Allow control again") {
                    if rtc.automaticControlEnabled { rtc.pauseRemoteControl() } else { rtc.resumeRemoteControl() }
                }.buttonStyle(QuietButtonStyle(compact: true)).disabled(rtc.isReconnecting)
            } else if !rtc.privacyVeilActive && rtc.isSharingWindow {
                Text("Window sharing is view-only").font(.caption).foregroundStyle(Theme.textMuted)
            } else if !rtc.privacyVeilActive && !permissions.accessibility {
                Button("Set up remote control…") { show("permissions") }.buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent)
            } else if !rtc.privacyVeilActive {
                Text("Remote control unavailable for this share").font(.caption).foregroundStyle(Theme.textMuted)
            }
        }
    }

    // MARK: Roster

    private var roster: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
                TextField("Search people…", text: $searchText).textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textMuted) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if filteredTeammates.isEmpty {
                        VStack(spacing: 7) {
                            Text(teamConnected ? (searchText.isEmpty ? "No teammates yet" : "No matching teammates") : "Loading teammates…")
                                .font(.caption).foregroundStyle(Theme.textMuted)
                            if teamConnected { Button("Refresh") { Task { await store.refresh() } }.buttonStyle(QuietButtonStyle(compact: true)) }
                        }.frame(maxWidth: .infinity).frame(minHeight: 76)
                    } else {
                        if !onlineTeammates.isEmpty { contactSection("Online", people: onlineTeammates) }
                        if store.activeRoom == nil && !orphanedJoinRequests.isEmpty { joinRequestSection }
                        if store.activeRoom == nil && !store.activeTeamCalls.isEmpty { activeCallsSection }
                        if !offlineTeammates.isEmpty { contactSection("Offline", people: offlineTeammates) }
                    }
                    if !recentCalls.isEmpty { recentCallsSection }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The call log shares the roster's scroll area so missed calls stay
            // reachable even when the team list is long.
            .frame(maxHeight: store.activeRoom == nil ? 420 : 300)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var teammates: [TeamUser] {
        store.users.filter { $0.id != store.user?.id }.sorted {
            if ($0.online == true) != ($1.online == true) { return $0.online == true }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
    private var filteredTeammates: [TeamUser] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return teammates }
        return teammates.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.email.localizedCaseInsensitiveContains(query) }
    }
    private var onlineTeammates: [TeamUser] { filteredTeammates.filter { $0.online == true } }
    private var offlineTeammates: [TeamUser] { filteredTeammates.filter { $0.online != true } }
    private var recentCalls: [CallInvitation] {
        store.callInvitations.filter { ["expired", "declined", "cancelled"].contains($0.status) }.prefix(8).map { $0 }
    }
    private var orphanedJoinRequests: [CallJoinRequest] {
        store.outgoingJoinRequests.filter { request in
            !store.activeTeamCalls.contains(where: { $0.id == request.room.id })
        }
    }

    private var recentCallsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("RECENT CALLS")
            ForEach(recentCalls) { invitation in
                let incoming = invitation.target.id == store.user?.id
                let person = incoming ? invitation.caller : invitation.target
                let missed = incoming && invitation.status == "expired"
                HStack(spacing: 9) {
                    PersonAvatar(name: person.name, id: person.id, size: 27).opacity(missed ? 1 : 0.7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        HStack(spacing: 5) {
                            Text(callHistoryLabel(invitation, incoming: incoming))
                                .foregroundStyle(missed ? Theme.attention : Theme.textMuted)
                            Text("·")
                            Text(invitation.createdDate, style: .relative)
                                .foregroundStyle(Theme.textMuted)
                        }.font(.caption).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if person.online == true && person.busy != true {
                        Button("Call back") { Task { await store.call(person) } }
                            .buttonStyle(QuietButtonStyle(compact: true)).disabled(store.busy)
                    }
                }.padding(.horizontal, 8).frame(minHeight: 38)
            }
        }
    }

    private func callHistoryLabel(_ invitation: CallInvitation, incoming: Bool) -> String {
        switch invitation.status {
        case "expired": incoming ? "Missed call" : "No answer"
        case "declined": incoming ? "Declined" : "Call declined"
        default: "Call ended"
        }
    }

    private var joinRequestSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("JOIN REQUESTS")
            ForEach(orphanedJoinRequests) { request in
                HStack(spacing: 8) {
                    Image(systemName: "hourglass").font(.caption).foregroundStyle(Theme.attention).frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Waiting to join \(callNames(request.room))").font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("Your request is waiting for someone to accept").font(.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button("Cancel") { Task { await store.cancelJoinRequest(request) } }
                        .buttonStyle(QuietButtonStyle(compact: true)).disabled(store.busy)
                }.padding(.horizontal, 8).frame(minHeight: 38)
            }
        }
    }

    @ViewBuilder
    private var activeCallsSection: some View {
        let calls = store.activeTeamCalls.filter { $0.id != store.activeRoom?.id }
        if !calls.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionHeader("ACTIVE TEAM CALLS")
                ForEach(calls) { room in activeCallRow(room) }
            }
        }
    }

    private func activeCallRow(_ room: PairRoom) -> some View {
        let pendingRequest = store.outgoingJoinRequests.first { $0.room.id == room.id }
        return HStack(spacing: 8) {
            HStack(spacing: -7) {
                ForEach(Array(room.participants.prefix(3))) { participant in
                    PersonAvatar(name: participant.name, id: participant.id, size: 25, circular: true)
                        .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(callNames(room)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(pendingRequest == nil ? "\(room.participantCount) people · active call" : "Request sent · waiting for acceptance")
                    .font(.caption).foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 4)
            if let pendingRequest {
                Button("Cancel") { Task { await store.cancelJoinRequest(pendingRequest) } }
                    .buttonStyle(QuietButtonStyle(compact: true)).disabled(store.busy)
            } else {
                Button("Request to join") { Task { await store.requestToJoin(room) } }
                    .buttonStyle(QuietButtonStyle(compact: true)).disabled(store.busy || store.activeRoom != nil)
            }
        }.padding(.horizontal, 8).frame(minHeight: 42)
    }

    private func callNames(_ room: PairRoom) -> String {
        let names = room.participants.map(\.name)
        return names.isEmpty ? room.name : names.joined(separator: " · ")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textMuted).padding(.horizontal, 8).padding(.bottom, 2)
    }

    private func contactSection(_ title: String, people: [TeamUser]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader(title)
            ForEach(people) { person in contactRow(person) }
        }
    }

    private func contactRow(_ person: TeamUser) -> some View {
        let online = person.online == true
        return HStack(spacing: 10) {
            PersonAvatar(name: person.name, id: person.id, size: 32, presence: presence(person)).opacity(online ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.system(size: 13, weight: .medium)).foregroundStyle(online ? Color.primary : Theme.textMuted).lineLimit(1)
                Text(status(person)).font(.caption).foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 4)
            if canCall(person) {
                Button { Task { await store.call(person) } } label: {
                    Label(store.activeRoom == nil ? "Call" : "Add", systemImage: "phone.fill")
                }.buttonStyle(QuietButtonStyle(compact: true))
            }
        }
        .frame(height: 44).padding(.horizontal, 8).contentShape(Rectangle())
    }

    private func presence(_ person: TeamUser) -> Presence {
        person.online != true ? .offline : (person.busy == true ? .busy : .online)
    }
    private func status(_ person: TeamUser) -> String {
        if rtc.participants.contains(where: { $0.identity == person.id }) { return "In this call" }
        return person.online != true ? "Offline" : (person.busy == true ? "In a call" : "Online")
    }
    private func canCall(_ person: TeamUser) -> Bool {
        !store.busy && person.online == true && person.busy != true &&
        !rtc.participants.contains(where: { $0.identity == person.id }) &&
        !store.outgoingCalls.contains(where: { $0.target.id == person.id }) &&
        (store.activeRoom == nil || store.canAddPerson)
    }
    private func show(_ id: String) {
        // Let the popover close before the window takes focus.
        DispatchQueue.main.async {
            StatusBarController.shared?.closePopover()
            switch id {
            case "permissions": PermissionWindowController.shared.show()
            case "main": AppWindows.shared.showSignIn()
            case "account": AppWindows.shared.showAccount(store: store, loginItem: loginItem)
            case "share": AppWindows.shared.showSharePicker(store: store)
            case "screen": AppWindows.shared.showSharedScreen(store: store)
            case "transcript": AppWindows.shared.showTranscript(store: store)
            default: break
            }
        }
    }

    private func chooseShareSource(_ source: ScreenShareSource) {
        DispatchQueue.main.async {
            StatusBarController.shared?.closePopover()
            Task {
                if rtc.isSharing { await store.changeScreenSource(source: source) }
                else { await store.shareScreen(source: source) }
            }
        }
    }
}

struct IncomingCallView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        if let prompt = store.incomingCallPrompts.first {
            VStack(spacing: 18) {
                PersonAvatar(name: prompt.person.name, id: prompt.person.id, size: 72, circular: true, ring: true)
                    .padding(.top, 6).accessibilityHidden(true)
                VStack(spacing: 4) {
                    Text(prompt.isJoinRequest ? "Wants to join your call" : "Incoming call…")
                        .font(.caption).foregroundStyle(Theme.textMuted)
                    Text(prompt.person.name).font(.system(size: 18, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(prompt.person.email).font(.caption).foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }.multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button { Task { await store.respond(to: prompt, accepting: false) } } label: {
                        Label("Decline", systemImage: "phone.down.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(DangerButtonStyle(filled: true))
                    Button { Task { await store.respond(to: prompt, accepting: true) } } label: {
                        Label(prompt.isJoinRequest ? "Add to call" : "Accept",
                              systemImage: prompt.isJoinRequest ? "person.badge.plus" : "phone.fill")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(PrimaryButtonStyle())
                        .disabled(prompt.isJoinRequest && !store.canAddPerson)
                }.disabled(store.busy)
                if prompt.isJoinRequest && !store.canAddPerson {
                    Text("This call is limited to four people.").font(.caption).foregroundStyle(Theme.textMuted)
                }
                if store.incomingCallPrompts.count > 1 {
                    Text("\(store.incomingCallPrompts.count - 1) more waiting")
                        .font(.caption).foregroundStyle(Theme.textMuted)
                }
                if let error = store.error {
                    Text(error).font(.caption).foregroundStyle(Theme.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24).frame(width: 300)
            .background(Theme.surface)
        }
    }
}
