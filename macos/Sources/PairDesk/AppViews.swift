import SwiftUI
import AppKit
import LiveKit

struct RootView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        Group {
            if store.user == nil { LoginView(store: store) }
            else { WorkspaceView(store: store, rtc: store.rtc, transcripts: store.transcripts) }
        }
        .tint(Theme.accent)
        .background(Theme.surface)
        .alert("PairDesk", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

struct LoginView: View {
    private struct SignupPolicy: Decodable { let enabled: Bool; let allowedDomains: [String] }
    @ObservedObject var store: AppStore
    @State private var creatingAccount = false
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var signupEnabled = true
    @State private var signupDomains: [String] = []
    @State private var serverExpanded = false
    @FocusState private var focused: Bool
    init(store: AppStore, creatingAccount: Bool = false) {
        self.store = store
        _creatingAccount = State(initialValue: creatingAccount)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Logo(size: 44).padding(.top, 12) // clear of the hidden title bar's window buttons
            Text(creatingAccount ? "Create your PairDesk account" : "Sign in to PairDesk")
                .font(.system(size: 22, weight: .semibold))
            Text(creatingAccount ? "Join your team and set your own password." : "Sign in with your team account.")
                .foregroundStyle(Theme.textMuted).font(.system(size: 13))
            HStack(spacing: 0) {
                authTab("Sign in", selected: !creatingAccount) { creatingAccount = false }
                authTab("Create account", selected: creatingAccount) { creatingAccount = true }
            }
            .padding(3).background(Theme.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
            .padding(.top, 4)
            if creatingAccount {
                VStack(alignment: .leading, spacing: 8) {
                    Text("NAME").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textMuted)
                    TextField("Your name", text: $name).textFieldStyle(.roundedBorder)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("EMAIL").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textMuted)
                TextField("you@team.com", text: $email).textFieldStyle(.roundedBorder).focused($focused)
            }.padding(.top, 12)
            VStack(alignment: .leading, spacing: 8) {
                Text("PASSWORD").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textMuted)
                SecureField(creatingAccount ? "At least 12 characters" : "Your password", text: $password).textFieldStyle(.roundedBorder)
            }
            if creatingAccount {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CONFIRM PASSWORD").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textMuted)
                    SecureField("Enter your password again", text: $confirmPassword).textFieldStyle(.roundedBorder)
                }
            }
            Button {
                let submitted = password
                password = ""
                let submittedEmail = email
                if creatingAccount {
                    let submittedName = name
                    confirmPassword = ""
                    Task { await store.signUp(name: submittedName, email: submittedEmail, password: submitted) }
                } else {
                    Task { await store.login(email: submittedEmail, password: submitted) }
                }
            } label: {
                HStack { Spacer(); if store.busy { ProgressView().controlSize(.small) } else { Text(creatingAccount ? "Create account" : "Sign in").fontWeight(.semibold); Image(systemName: "arrow.right") }; Spacer() }
                    .padding(.vertical, 10)
            }.buttonStyle(.borderedProminent).disabled(store.busy || email.isEmpty || password.isEmpty || (creatingAccount && (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.count < 12 || password != confirmPassword)))
                .keyboardShortcut(.defaultAction)
            DisclosureGroup("Server address", isExpanded: $serverExpanded) {
                TextField("https://pair.yourteam.com", text: $store.serverAddress).textFieldStyle(.roundedBorder).padding(.top, 8)
            }.font(.system(size: 12)).foregroundStyle(Theme.textMuted).disabled(store.busy)
            Text(creatingAccount ? signupNote : "Need help accessing your team account? Contact your team administrator.")
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
        }.padding(32).frame(width: 380)
            .onAppear { focused = true }
            .task { await loadSignupPolicy() }
            .onChange(of: store.serverAddress) { _, _ in Task { await loadSignupPolicy() } }
    }

    private func authTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.primary : Theme.textMuted)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(selected ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(store.busy || (title == "Create account" && !signupEnabled))
    }

    private var signupNote: String {
        guard signupEnabled else { return "Self-service signup is turned off for this team. Contact your team administrator." }
        let domainNote = signupDomains.isEmpty ? "Use the email address you use with your team." : "Use an email ending in " + signupDomains.map { "@\($0)" }.joined(separator: " or ") + "."
        return domainNote + " Email verification is not currently enabled."
    }

    @MainActor
    private func loadSignupPolicy() async {
        guard let client = try? APIClient(server: store.serverAddress),
              let policy: SignupPolicy = try? await client.request("v1/signup-policy") else { return }
        signupEnabled = policy.enabled
        signupDomains = policy.allowedDomains
        if !signupEnabled { creatingAccount = false }
    }
}

struct SharedScreenWindow: View {
    @ObservedObject var store: AppStore
    @ObservedObject var rtc: RTCService
    @ObservedObject var transcripts: WhisperTranscriber
    @ObservedObject var agentBridge: LocalAgentBridge = AppRuntime.shared.store.agentBridge
    @State private var showTranscript = false
    @State private var showClipboard = false
    @State private var permissions = false
    @State private var sourcePicker = false
    @State private var annotationMode = false
    @State private var laserMode = false
    @State private var annotationStrokeID: String?
    private var shareStatus: String? {
        guard let sharer = rtc.activeSharerIdentity else { return nil }
        switch rtc.controlState {
        case .granted:
            return "You have control of \(rtc.participantName(for: sharer))'s Mac"
        case .requesting:
            return "Connecting remote control…"
        case .hostPermissionRequired:
            return "Ask \(rtc.participantName(for: sharer)) to enable Accessibility, then try again"
        case .viewer:
            let host = rtc.participantName(for: sharer)
            if rtc.remoteControlAvailable { return "Viewing \(host) · \(rtc.usesIndependentCursors ? "separate cursors · " : "")click or type to control" }
            if let reason = rtc.remoteControlUnavailableReason { return "Viewing \(host) · \(reason.viewerDescription(host: host))" }
            return "Viewing \(host) · view only"
        case .host:
            if rtc.automaticControlEnabled { return "Sharing display · remote control ready" }
            if let reason = rtc.remoteControlUnavailableReason { return "Sharing display · \(reason.sharerDescription)" }
            return "Sharing display · remote control paused"
        case .unavailable:
            return "Shared screen · view only"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Call · \(max(1, rtc.participants.count))").font(.headline).lineLimit(1)
                if rtc.isReconnecting {
                    Label(rtc.isSharing ? "Reconnecting · control paused" : "Reconnecting", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
                if let shareStatus {
                    Label(shareStatus, systemImage: rtc.controlState.isGranted ? "cursorarrow.motionlines" : "display")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .layoutPriority(1)
                }
                if rtc.isSharing && !rtc.remoteControlAvailable && rtc.remoteControlUnavailableReason == .accessibility {
                    Button("Fix") { PermissionWindowController.shared.show() }
                        .buttonStyle(.borderless)
                        .help("Check Accessibility permission for this exact PairDesk copy")
                }
                Spacer(minLength: 0)
                if rtc.screenTrack != nil && !rtc.isSharing {
                    Menu {
                        Text("Network · \(rtc.screenNetworkQuality.label)")
                        Text("Screen · \(rtc.screenStreamMetrics.summary)")
                        if let firstFrame = rtc.screenTimeToFirstFrameMilliseconds {
                            Text("First frame · \(firstFrame) ms")
                        }
                    } label: {
                        Label("Quality", systemImage: "waveform.path")
                            .foregroundStyle(networkQualityColor)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("Shared-screen quality details")
                    .accessibilityLabel("Shared-screen quality details")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            Divider()
            HStack(spacing: 7) {
                Button {
                    Task { do { try await store.setMicrophoneEnabled(!rtc.isMicrophoneEnabled) } catch { store.error = error.localizedDescription } }
                } label: {
                    Label(rtc.isMicrophoneEnabled ? "Mute" : "Unmute", systemImage: rtc.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill")
                }
                .buttonStyle(.bordered)
                .tint(rtc.isMicrophoneEnabled ? Theme.accent : Theme.attention)
                .help(rtc.isMicrophoneEnabled ? "Mute microphone" : "Unmute microphone")
                .accessibilityLabel(rtc.isMicrophoneEnabled ? "Mute microphone" : "Unmute microphone")
                Button {
                    annotationMode.toggle()
                    laserMode = false
                    annotationStrokeID = nil
                } label: {
                    Image(systemName: annotationMode ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                }
                .buttonStyle(.bordered)
                .tint(annotationMode ? Theme.accent : nil)
                .disabled(!rtc.canAnnotateScreen)
                .help(rtc.annotationsAllowed ? "Draw temporary marks on the shared screen" : "The sharer disabled annotations")
                .accessibilityLabel(annotationMode ? "Done drawing" : "Draw on shared screen")
                Button {
                    laserMode.toggle()
                    annotationMode = false
                    annotationStrokeID = nil
                } label: {
                    Image(systemName: laserMode ? "scope" : "dot.scope")
                }
                .buttonStyle(.bordered)
                .tint(laserMode ? Theme.accent : nil)
                .disabled(!rtc.canAnnotateScreen)
                .accessibilityLabel(laserMode ? "Done pointing" : "Laser pointer")
                .help("Point at the screen with a temporary, color-coded laser. It fades automatically.")
                Button {
                    Task { do { try await rtc.setCameraEnabled(!rtc.isCameraEnabled) } catch { store.error = error.localizedDescription } }
                } label: {
                    Label(rtc.isCameraEnabled ? "Camera off" : "Camera on", systemImage: rtc.isCameraEnabled ? "video.fill" : "video.slash.fill")
                }
                .buttonStyle(.bordered)
                .tint(rtc.isCameraEnabled ? Theme.accent : nil)
                .help(rtc.isCameraEnabled ? "Turn camera off" : "Turn camera on")
                if rtc.isCameraEnabled && rtc.cameraDevices.count > 1 {
                    Menu {
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
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .help("Choose camera")
                    .accessibilityLabel("Choose camera")
                }
                Button { showClipboard = true } label: {
                    Label("Copy & paste", systemImage: rtc.clipboardSyncEnabled ? "doc.on.clipboard.fill" : "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .tint(rtc.clipboardSyncEnabled ? Theme.accent : nil)
                .help(rtc.clipboardSyncEnabled ? "Text copy and paste is synced with this call until the call ends" : "Sync copy and paste for the call, or send text once to a teammate")
                .accessibilityLabel(rtc.clipboardSyncEnabled ? "Copy and paste sync on" : "Copy and paste options")
                .popover(isPresented: $showClipboard, arrowEdge: .bottom) {
                    ClipboardTransferView(
                        peers: rtc.participants.filter { !$0.isLocal }.map { ClipboardPeer(identity: $0.identity, name: $0.name) },
                        incoming: rtc.incomingClipboardTransfer,
                        onSend: { text, identity in try await rtc.sendClipboard(text: text, to: identity) },
                        onPaste: { rtc.pasteIncomingClipboardTransfer() },
                        onDismiss: { rtc.dismissIncomingClipboardTransfer() },
                        clipboardSyncEnabled: rtc.clipboardSyncEnabled,
                        clipboardSyncNotice: rtc.clipboardSyncNotice,
                        onToggleSync: { rtc.setClipboardSyncEnabled($0) }
                    )
                    .padding(16)
                    .frame(width: 420)
                }
                Menu {
                    if store.availablePeople.isEmpty {
                        Text("No one else is available right now")
                    } else {
                        ForEach(store.availablePeople) { person in
                            Button { Task { await store.call(person) } } label: {
                                Label(person.name, systemImage: "phone.fill")
                            }
                        }
                    }
                } label: {
                    Label("Add", systemImage: "person.badge.plus")
                }
                .disabled(!store.canAddPerson || store.busy)
                .help(store.canAddPerson ? "Add someone to this call" : "This call is full")
                .accessibilityLabel("Add teammate")
                Button { if rtc.isSharing { Task { await store.stopSharing() } } else { sourcePicker = true } } label: {
                    Label(rtc.isSharing ? "Stop share" : "Share screen", systemImage: rtc.isSharing ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
                .help(rtc.isSharing ? "Stop sharing your screen" : "Share your screen")
                Menu {
                    if rtc.isSharing {
                        Button("Change source…") { Task { await store.changeScreenSource() } }.disabled(store.busy)
                    }
                    if !rtc.screenAnnotations.isEmpty || !rtc.screenAnnotationLasers.isEmpty {
                        Button("Clear marks") { rtc.clearScreenAnnotations() }
                    }
                    Button("Local transcript") { showTranscript.toggle() }
                    Button("Full screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("More call controls")
                .accessibilityLabel("More call controls")
                Spacer(minLength: 4)
                Button("End call") { Task { await store.leave() } }
                    .buttonStyle(DangerButtonStyle())
                    .help("Leave this call")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Theme.surface)
            if rtc.participants.contains(where: { !$0.isLocal }) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(rtc.participants.filter { !$0.isLocal }) { person in
                            HStack(spacing: 6) {
                                Text(person.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                ParticipantMicrophoneStatus(participant: person)
                            }
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 7)
                }.fixedSize(horizontal: false, vertical: true)
                    .background(Theme.surface)
            }
            CameraStrip(feeds: rtc.cameraFeeds).padding(.horizontal, 12).padding(.vertical, 4)
            if let notice = rtc.cameraDeviceNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
            HStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let track = rtc.screenTrack, !rtc.isSharing {
                        InteractiveScreenView(track: track, rtc: rtc)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay {
                                if let dimensions = track.dimensions {
                                    // Keep this layer interactive so draw/laser gestures reach the input view.
                                    GeometryReader { geometry in
                                        let contentSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
                                        ZStack {
                                            let names = Dictionary(uniqueKeysWithValues: rtc.participants.map { ($0.identity, $0.name) })
                                            ScreenAnnotationLayer(strokes: rtc.screenAnnotations, names: names, contentSize: contentSize)
                                                .allowsHitTesting(false)
                                            ScreenAnnotationLaserLayer(lasers: rtc.screenAnnotationLasers, names: names, contentSize: contentSize)
                                                .allowsHitTesting(false)
                                            if (annotationMode || laserMode) && rtc.canAnnotateScreen {
                                                ScreenAnnotationInputLayer(rtc: rtc, contentSize: contentSize,
                                                                           strokeID: $annotationStrokeID,
                                                                           laserMode: laserMode)
                                            }
                                            if rtc.usesIndependentCursors {
                                                let pointers = rtc.remotePointers + localPointer
                                                let names = Dictionary(uniqueKeysWithValues: rtc.participants.map { ($0.identity, $0.name) })
                                                SharedCursorLayer(pointers: pointers, names: names, contentSize: contentSize)
                                                    .allowsHitTesting(false)
                                            } else {
                                                ForEach(rtc.remotePointers) { pointer in
                                                    if let point = ScreenCoordinateMapper.displayedPoint(
                                                        normalized: CGPoint(x: pointer.x, y: pointer.y),
                                                        container: CGRect(origin: .zero, size: geometry.size),
                                                        contentSize: contentSize
                                                    ) {
                                                        RemotePointerBadge(name: rtc.participantName(for: pointer.id), color: cursorColor(for: pointer.id))
                                                            .position(x: min(max(point.x + 54, 54), geometry.size.width - 54),
                                                                      y: min(max(point.y + 14, 14), geometry.size.height - 14))
                                                            .transition(.opacity)
                                                            .allowsHitTesting(false)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .allowsHitTesting((annotationMode || laserMode) && rtc.canAnnotateScreen)
                                }
                            }
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: rtc.isSharing ? "display.and.arrow.up" : "phone").font(.system(size: 44))
                            Text(rtc.isSharing ? (rtc.isSharingWindow ? "Your window is shared" : "Your display is shared") : (store.activeRoom == nil ? "Call ended" : "Waiting for a screen share"))
                            Text(rtc.isSharing ? (rtc.isSharingWindow ? "Window sharing is view-only. Use the menu bar to stop sharing." : "Your teammates can control your shared display. Use the menu bar to stop control.") : (store.activeRoom == nil ? "Start a new call from the PairDesk menu bar." : "Your teammate can start sharing at any time. Call controls and your team are in the PairDesk menu bar.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(30)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if showTranscript { TranscriptPanel(transcriber: transcripts, rtc: rtc, bridge: agentBridge).frame(width: 300) }
            }
            if let error = rtc.error { HStack { Text(error).font(.caption).foregroundStyle(.orange); Spacer(); Button("Permissions") { permissions = true } }.padding(8) }
        }.background(Theme.surface).tint(Theme.accent)
        .task {
            while !Task.isCancelled {
                rtc.refreshScreenNetworkQuality()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        .onChange(of: rtc.incomingClipboardTransfer?.message.id) { _, offerID in
            if offerID != nil { showClipboard = true }
        }
        .onChange(of: rtc.canAnnotateScreen) { _, canAnnotate in
            if !canAnnotate { annotationMode = false; laserMode = false; annotationStrokeID = nil }
        }
        .sheet(isPresented: $permissions) { PermissionsView() }
        .sheet(isPresented: $sourcePicker) { ScreenSharePickerView(store: store) }
        .alert("PairDesk", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }

    private func cursorColor(for identity: String) -> Color { Theme.personColor(for: identity) }

    private var localPointer: [RemotePointer] {
        guard let identity = rtc.localIdentity, let point = rtc.localCursorPosition else { return [] }
        return [RemotePointer(id: identity, x: point.x, y: point.y, updatedAt: .now)]
    }

    private var networkQualityColor: Color {
        switch rtc.screenNetworkQuality {
        case .measuring: .secondary
        case .good: .green
        case .fair: .orange
        case .highLatency: .red
        }
    }
}

private struct ScreenAnnotationInputLayer: View {
    @ObservedObject var rtc: RTCService
    let contentSize: CGSize
    @Binding var strokeID: String?
    let laserMode: Bool

    var body: some View {
        GeometryReader { geometry in
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let point = ScreenCoordinateMapper.normalized(point: value.location,
                            container: CGRect(origin: .zero, size: geometry.size), contentSize: contentSize) else { return }
                        if laserMode {
                            rtc.setScreenAnnotationLaser(ScreenAnnotationPoint(x: point.x, y: point.y))
                            return
                        }
                        if strokeID == nil { strokeID = UUID().uuidString }
                        if let strokeID {
                            rtc.addScreenAnnotationPoint(ScreenAnnotationPoint(x: point.x, y: point.y), strokeID: strokeID)
                        }
                    }
                    .onEnded { _ in strokeID = nil })
        }
    }
}

private struct RemotePointerBadge: View {
    let name: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .foregroundStyle(.white)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.9), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 5, y: 2)
    }
}

struct ScreenSharePickerView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var screenPermission = PermissionManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var permissions = false
    @State private var source: ScreenShareSource = .display
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Share your screen").font(.title2.bold())
            Picker("What to share", selection: $source) {
                ForEach(ScreenShareSource.allCases) { source in Text(source.title).tag(source) }
            }.pickerStyle(.segmented)
            Text(source.explanation + " PairDesk only gets access to your selection for this sharing session.").font(.callout).foregroundStyle(.secondary)
            if source == .display {
                Label("On macOS 15.2 or newer, you can hide selected apps after choosing a display. Notification banners may still appear; use Focus to silence them. Window or Region sharing limits what others see.", systemImage: "eye")
                    .font(.caption).foregroundStyle(Theme.attention).fixedSize(horizontal: false, vertical: true)
            }
            if source == .window {
                Text("Window sharing is view-only. Share a display or region to use remote control.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Remote mouse and keyboard control needs Accessibility access on the Mac being shared. Screen sharing still works without it.", systemImage: "cursorarrow.motionlines")
                    .font(.caption).foregroundStyle(.secondary)
                if !screenPermission.accessibility {
                    Button("Set up remote control") { screenPermission.requestAccessibility() }
                }
            }
            Spacer()
            HStack {
                Button("Permissions") { permissions = true }
                Spacer()
                Button("Cancel") { dismiss(); AppWindows.shared.close("share") }
                    .keyboardShortcut(.cancelAction)
                Button("Choose \(source == .window ? "window" : "display")…") { beginSharing() }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(store.busy)
            }
        }.padding(26).frame(width: 560)
        .task { screenPermission.refresh() }
        .sheet(isPresented: $permissions) { PermissionsView() }
    }

    private func beginSharing() {
        let chosenSource = source
        dismiss()
        AppWindows.shared.close("share")
        Task { await store.shareScreen(source: chosenSource) }
    }
}

struct WorkspaceView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var rtc: RTCService
    @ObservedObject var transcripts: WhisperTranscriber
    @EnvironmentObject private var loginItem: LoginItemManager
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 46))
            Text("PairDesk lives in your menu bar").font(.title2.bold())
            Text("Click its icon at the top right of your screen to call a teammate, share a display, or manage a call.").multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            // Their own windows, as in the menu bar: these are taller than this
            // compact window, so sheets would hang off its bottom edge.
            HStack { Button("Permissions") { PermissionWindowController.shared.show() }; Button("Account settings") { AppWindows.shared.showAccount(store: store, loginItem: loginItem) } }
        }.padding(40).frame(width: 520)
    }
}

private struct TranscriptPanel: View {
    @ObservedObject var transcriber: WhisperTranscriber
    @ObservedObject var rtc: RTCService
    @ObservedObject var bridge: LocalAgentBridge
    @State private var allowParticipants = false
    @State private var allowTranscript = false
    @State private var allowScreenshot = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Local transcript").font(.system(size: 14, weight: .semibold)); Spacer(); Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(Theme.accent) }
            Toggle("Transcribe on this Mac", isOn: Binding(get: { transcriber.enabled }, set: {
                transcriber.setEnabled($0)
                rtc.setAudioForwardingConsented(transcriber.enabled)
            })).toggleStyle(.switch).font(.system(size: 11))
            Text(transcriber.status).font(.system(size: 10)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if transcriber.segments.isEmpty { Text("Speech will appear here when transcription is on. Tiny is fast, but may miss technical words.").font(.system(size: 12)).foregroundStyle(Theme.textMuted).padding(.top, 20) }
                        ForEach(transcriber.segments) { segment in
                            VStack(alignment: .leading, spacing: 5) { HStack { Text(segment.speakerName).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent); Spacer(); Text(segment.createdAt, style: .time).font(.system(size: 9)).foregroundStyle(Theme.textMuted) }; Text(segment.text).font(.system(size: 12)).textSelection(.enabled).lineSpacing(3) }.id(segment.id)
                        }
                    }
                }.onChange(of: transcriber.segments.count) { _, _ in if let id = transcriber.segments.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            HStack { Button("Clear") { transcriber.clear() }.buttonStyle(.plain); Spacer(); Button("Export text") { export() }.buttonStyle(.plain).disabled(transcriber.segments.isEmpty) }.font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            Text("No upload. Not saved automatically.").font(.system(size: 9)).foregroundStyle(Theme.textMuted)
            Divider()
            HStack { Text("Coding agent access").font(.system(size: 14, weight: .semibold)); Spacer(); Image(systemName: "lock.shield").foregroundStyle(Theme.accent) }
            Text("Only this Mac · active call only · read only").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
            Text("The copied config contains a temporary access key. Other apps running as your macOS user may be able to read that config; connect only a trusted agent and revoke access when finished.")
                .font(.system(size: 9)).foregroundStyle(Theme.attention).fixedSize(horizontal: false, vertical: true)
            Toggle("Participant names", isOn: $allowParticipants).toggleStyle(.switch).font(.system(size: 11)).disabled(bridge.isEnabled)
            Toggle("Transcript text", isOn: $allowTranscript).toggleStyle(.switch).font(.system(size: 11)).disabled(bridge.isEnabled)
            Toggle("One-time window screenshots", isOn: $allowScreenshot).toggleStyle(.switch).font(.system(size: 11)).disabled(bridge.isEnabled)
            Text("Each screenshot request opens Apple's window picker. Only the window you select is sent, once, to the local agent.")
                .font(.system(size: 9)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            if let activity = bridge.screenshotActivity {
                Text(activity).font(.system(size: 9)).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true)
            }
            if bridge.isEnabled, let token = bridge.credential {
                Text("Access is enabled for this call. The selected context may be sent to your configured model provider by the agent.")
                    .font(.system(size: 10)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                Button("Copy MCP configuration") { copyAgentConfiguration(token: token) }.buttonStyle(.bordered)
                Button("Revoke agent access") { bridge.revoke() }.buttonStyle(.plain).foregroundStyle(.red)
            } else {
                Button("Enable local agent access") {
                    _ = bridge.authorize(capabilities: Set([allowParticipants ? "participants" : nil,
                                                            allowTranscript ? "transcript" : nil,
                                                            allowScreenshot ? "screenshot" : nil].compactMap { $0 }))
                }.buttonStyle(.borderedProminent).disabled(!allowParticipants && !allowTranscript && !allowScreenshot)
            }
            if !bridge.isEnabled && (!allowParticipants || !allowTranscript || !allowScreenshot) {
                Text("Each capability is optional. Audio, screen streams, and remote control are not exposed.")
                    .font(.system(size: 9)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(20)
    }
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pairdesk-transcript.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = transcriber.segments.map { "[\($0.createdAt.formatted(date: .omitted, time: .standard))] \($0.speakerName): \($0.text)" }.joined(separator: "\n\n")
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { NSAlert(error: error).runModal() }
    }
    private func copyAgentConfiguration(token: String) {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pairdesk-agent-mcp").path
        let config: [String: Any] = ["mcpServers": ["pairdesk": ["command": executable,
            "env": ["PAIRDESK_BRIDGE_TOKEN": token, "PAIRDESK_BRIDGE_SOCKET": bridge.socketPath]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct TranscriptWindow: View {
    @ObservedObject var store: AppStore
    var body: some View {
        TranscriptPanel(transcriber: store.transcripts, rtc: store.rtc, bridge: store.agentBridge)
            .frame(width: 340, height: 700)
    }
}

struct AccountView: View {
    @EnvironmentObject private var loginItem: LoginItemManager
    @ObservedObject var store: AppStore
    @State private var current = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var saving = false
    @State private var addingMember = false
    @State private var managingTeam = false
    @State private var showingDiagnostics = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(store.user?.name ?? "Account").font(.title2.bold())
            Text(store.user?.email ?? "").foregroundStyle(.secondary)
            if store.user?.admin == true {
                Button("Create a team account") { addingMember = true }.buttonStyle(.bordered)
                Button("Manage team accounts…") { managingTeam = true }.buttonStyle(.bordered)
            }
            Divider()
            Toggle("Start PairDesk at login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.setEnabled($0) }))
            if let message = loginItem.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if loginItem.needsApproval { Button("Open Login Items settings") { loginItem.openSettings() } }
            Button("Review support diagnostics…") { showingDiagnostics = true }.buttonStyle(.bordered)
            Divider()
            Text("Change password").font(.headline)
            SecureField("Current password", text: $current).textFieldStyle(.roundedBorder)
            SecureField("New password (at least 12 characters)", text: $newPassword).textFieldStyle(.roundedBorder)
            SecureField("Confirm new password", text: $confirmation).textFieldStyle(.roundedBorder)
            HStack { Button("Sign out") { closeWindow(); Task { await store.logout() } }.disabled(store.busy || saving); Spacer(); Button("Close") { closeWindow() }; Button(saving ? "Saving…" : "Save password") { saving = true; Task { let success = await store.changePassword(current: current, new: newPassword); saving = false; if success { closeWindow() } } }.buttonStyle(.borderedProminent).disabled(saving || current.isEmpty || newPassword.count < 12 || newPassword != confirmation) }
        }.padding(30).frame(width: 430)
            .sheet(isPresented: $addingMember) { CreateMemberView(store: store) }
            .sheet(isPresented: $managingTeam) { ManageTeamView(store: store) }
            .sheet(isPresented: $showingDiagnostics) { SupportDiagnosticsView(store: store, rtc: store.rtc) }
    }
    private func closeWindow() { AppWindows.shared.close("account") }
}

private struct ManageTeamView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var resetMember: TeamUser?
    @State private var newPassword = ""
    @State private var saving = false
    @State private var error: String?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Team accounts").font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }
            Text("Disabling an account ends its sessions. Password resets also sign the member out; share the new password privately.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if let message { Text(message).font(.caption).foregroundStyle(.green) }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.adminUsers) { member in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(member.name).font(.system(size: 13, weight: .medium))
                                Text(member.email).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Reset password") { resetMember = member; newPassword = ""; message = nil; error = nil }
                                .controlSize(.small)
                            Button(member.enabled == false ? "Enable" : "Disable") {
                                saving = true; error = nil; message = nil
                                Task {
                                    do { try await store.setTeamMemberEnabled(member, enabled: member.enabled == false); message = "Account updated." }
                                    catch { self.error = error.localizedDescription }
                                    saving = false
                                }
                            }.controlSize(.small).disabled(saving || (member.admin == true && member.enabled != false && store.adminUsers.filter { $0.admin == true && $0.enabled != false }.count <= 1))
                        }.padding(9).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.frame(minHeight: 180, maxHeight: 320)
            Divider()
            Text("Recent admin activity").font(.headline)
            if !store.adminAuditSupported {
                Text("Activity history will appear after the server is updated.").font(.caption).foregroundStyle(.secondary)
            } else if store.adminAuditEvents.isEmpty {
                Text("No account changes recorded yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(store.adminAuditEvents.suffix(10).reversed()) { event in
                            HStack(alignment: .firstTextBaseline) {
                                Text(auditDescription(event)).font(.caption)
                                Spacer(minLength: 8)
                                Text(event.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(maxHeight: 110)
            }
            if let resetMember {
                Divider()
                Text("Reset password for \(resetMember.name)").font(.headline)
                SecureField("New password (12+ characters)", text: $newPassword).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { self.resetMember = nil; newPassword = "" }
                    Spacer()
                    Button(saving ? "Saving…" : "Set password") {
                        saving = true; error = nil; message = nil
                        Task {
                            do {
                                try await store.resetTeamMemberPassword(resetMember, newPassword: newPassword)
                                self.resetMember = nil; newPassword = ""; message = "Password reset; the member must sign in again."
                            } catch { self.error = error.localizedDescription }
                            saving = false
                        }
                    }.buttonStyle(.borderedProminent).disabled(saving || newPassword.count < 12)
                }
            }
        }.padding(24).frame(width: 620).task {
            do { try await store.refreshAdminUsers() } catch { self.error = error.localizedDescription }
        }
    }

    private func auditDescription(_ event: AdminAuditEvent) -> String {
        let verb: String
        switch event.action {
        case "account.password_reset": verb = "reset password for"
        case "account.disabled": verb = "disabled"
        case "account.enabled": verb = "enabled"
        default: verb = "updated"
        }
        let actor = store.adminUsers.first(where: { $0.id == event.actorId })?.name ?? "An administrator"
        let target = store.adminUsers.first(where: { $0.id == event.targetId })?.name ?? "a team member"
        return "\(actor) \(verb) \(target)"
    }
}

private struct CreateMemberView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var saving = false
    @State private var error: String?
    @State private var created = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create a team account").font(.title2.bold())
            Text("Give your teammate their email and initial password directly. They can change the password after signing in.").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Full name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Email", text: $email).textFieldStyle(.roundedBorder)
            SecureField("Initial password (12+ characters)", text: $password).textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.orange).font(.system(size: 12)) }
            if created { Label("Account created", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
            HStack { Spacer(); Button("Close") { dismiss() }; Button(saving ? "Creating…" : "Create account") {
                saving = true
                error = nil
                Task {
                    do { try await store.createMember(name: name, email: email, password: password); password = ""; created = true }
                    catch { self.error = error.localizedDescription }
                    saving = false
                }
            }.buttonStyle(.borderedProminent).disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || email.isEmpty || password.count < 12) }
        }.padding(30).frame(width: 430)
    }
}

private struct Logo: View {
    let size: CGFloat
    var body: some View { Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: size * 0.53, weight: .medium)).foregroundStyle(Theme.accent).frame(width: size, height: size).background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.26)) }
}
