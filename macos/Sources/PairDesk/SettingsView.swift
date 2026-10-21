import AppKit
import SwiftUI

private enum PairDeskSettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case audio = "Audio"
    case video = "Video"
    case camera = "Camera"
    case privacy = "Privacy"
    case permissions = "Permissions"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .audio: "waveform"
        case .video: "display"
        case .camera: "video"
        case .privacy: "eye.slash"
        case .permissions: "hand.raised"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var rtc: RTCService
    @ObservedObject var loginItem: LoginItemManager
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var privacyVeil = PrivacyVeilPreferences.shared
    @State private var selection: PairDeskSettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(PairDeskSettingsSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .frame(minWidth: 170)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    sectionContent
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(30)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Theme.surface)
        }
        .frame(minWidth: 850, minHeight: 580)
        .tint(Theme.accent)
        .task {
            while !Task.isCancelled {
                permissions.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selection ?? .general {
        case .general: generalSection
        case .audio: audioSection
        case .video: videoSection
        case .camera: cameraSection
        case .privacy: privacySection
        case .permissions: permissionsSection
        }
    }

    private var generalSection: some View {
        SettingsPage(title: "General", subtitle: "Set how PairDesk behaves when you start it and join calls.") {
            SettingsCard {
                Toggle("Start PairDesk when I log in", isOn: Binding(
                    get: { loginItem.enabled }, set: { loginItem.setEnabled($0) }
                ))
                Divider()
                Toggle("Join calls muted", isOn: $store.startCallsMuted)
                Divider()
                Toggle("Play call sounds", isOn: $store.playCallSounds)
                if loginItem.needsApproval {
                    Divider()
                    HStack {
                        Label("macOS needs approval for automatic startup", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(Theme.attention)
                        Spacer()
                        Button("Open Login Items") { loginItem.openSettings() }
                    }
                }
            }
            SettingsCard {
                Label("PairDesk", systemImage: "rectangle.on.rectangle").font(.headline)
                Text("Your team, calls, screen sharing, and collaboration controls are available from the menu bar.")
                    .font(.callout).foregroundStyle(Theme.textMuted)
            }
        }
    }

    private var audioSection: some View {
        SettingsPage(title: "Audio", subtitle: "Choose the devices used for voice calls. PairDesk never turns on your microphone at launch.") {
            SettingsCard {
                SettingsRow(title: "Microphone", detail: rtc.savedAudioInputUnavailable
                    ? "Saved microphone unavailable; using the system default."
                    : (rtc.isMicrophoneEnabled ? "Microphone is active for this call." : "Microphone stays off until you turn it on."),
                            symbol: "mic") {
                    Picker("Microphone", selection: Binding(
                        get: { rtc.selectedAudioInputID }, set: { rtc.selectAudioInput($0) }
                    )) {
                        ForEach(rtc.audioInputDevices) { device in Text(device.title).tag(device.id) }
                    }
                    .labelsHidden().frame(maxWidth: 250)
                    .disabled(rtc.audioInputDevices.isEmpty)
                }
                Divider()
                SettingsRow(title: "Speaker", detail: rtc.savedAudioOutputUnavailable
                    ? "Saved speaker unavailable; using the system default."
                    : "Audio follows your selected output device.", symbol: "hifispeaker") {
                    Picker("Speaker", selection: Binding(
                        get: { rtc.selectedAudioOutputID }, set: { rtc.selectAudioOutput($0) }
                    )) {
                        ForEach(rtc.audioOutputDevices) { device in Text(device.title).tag(device.id) }
                    }
                    .labelsHidden().frame(maxWidth: 250)
                    .disabled(rtc.audioOutputDevices.isEmpty)
                }
            }
            SettingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Microphone level").font(.headline)
                        Text(rtc.isMicrophoneEnabled ? "Speak to see the local input meter." : "Turn on your microphone in a call to test its level.")
                            .font(.callout).foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    GeometryReader { proxy in
                        Capsule().fill(Theme.surfaceRaised)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Theme.online)
                                    .frame(width: proxy.size.width * min(max(rtc.localMicrophoneLevel, 0), 1))
                            }
                    }
                    .frame(width: 150, height: 8)
                    .accessibilityLabel("Local microphone input level")
                }
            }
            Text("Noise processing is not enabled. Input is not captured until you explicitly turn your microphone on in a call.")
                .font(.caption).foregroundStyle(Theme.textMuted)
        }
    }

    private var videoSection: some View {
        SettingsPage(title: "Screen sharing", subtitle: "Choose the maximum screen quality. Adaptive quality can lower the stream when the network needs it.") {
            SettingsCard {
                Toggle("Adapt quality to network conditions", isOn: Binding(
                    get: { rtc.adaptiveQualityEnabled }, set: { rtc.setAdaptiveQualityEnabled($0) }
                ))
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Maximum quality").font(.headline)
                    Picker("Maximum quality", selection: Binding(
                        get: { rtc.screenShareQuality }, set: { rtc.setScreenShareQuality($0) }
                    )) {
                        ForEach(ScreenShareQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("All presets target 30 fps. The selected maximum applies the next time you start sharing.")
                        .font(.caption).foregroundStyle(Theme.textMuted)
                }
            }
            SettingsCard {
                Label("Source selection", systemImage: "rectangle.dashed")
                    .font(.headline)
                Text("Choose a display, window, or region when you start sharing. Window shares show only that selected window and are view-only.")
                    .font(.callout).foregroundStyle(Theme.textMuted)
            }
        }
    }

    private var cameraSection: some View {
        SettingsPage(title: "Camera", subtitle: "Camera sharing is optional and remains off until you turn it on in a call.") {
            SettingsCard {
                SettingsRow(title: "Preferred camera", detail: rtc.cameraDeviceNotice ?? cameraStatus,
                            symbol: "video") {
                    Picker("Preferred camera", selection: Binding(
                        get: { rtc.selectedCameraID ?? "" },
                        set: { id in if !id.isEmpty { Task { await rtc.selectCamera(id) } } }
                    )) {
                        if rtc.cameraDevices.isEmpty { Text("No camera found").tag("") }
                        ForEach(rtc.cameraDevices) { device in Text(device.name).tag(device.id) }
                    }
                    .labelsHidden().frame(maxWidth: 250)
                    .disabled(rtc.cameraDevices.isEmpty)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Camera quality").font(.headline)
                    Picker("Camera quality", selection: Binding(
                        get: { rtc.cameraVideoQuality }, set: { rtc.setCameraVideoQuality($0) }
                    )) {
                        ForEach(CameraVideoQuality.allCases) { quality in Text(quality.title).tag(quality) }
                    }
                    .pickerStyle(.segmented)
                    Text("30 fps · quality applies the next time you turn video on. Actual capture depends on your camera and network.")
                        .font(.caption).foregroundStyle(Theme.textMuted)
                }
                Divider()
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: permissions.camera ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(permissions.camera ? Theme.online : Theme.textMuted)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Camera access").font(.headline)
                        Text("Permission is requested only when you turn video on.")
                            .font(.callout).foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    Button(permissions.camera ? "System Settings" : "Allow") {
                        if permissions.camera { permissions.open("Privacy_Camera") }
                        else { Task { await permissions.requestCamera() } }
                    }
                }
            }
        }
    }

    private var privacySection: some View {
        SettingsPage(title: "Privacy veil", subtitle: "Keep selected apps out of a shared display. PairDesk applies these exclusions only after you choose a display in Apple's sharing picker.") {
            SettingsCard {
                if #available(macOS 15.2, *) {
                    if privacyVeil.applications.isEmpty {
                        ContentUnavailableView("No hidden apps", systemImage: "eye", description: Text("Add apps such as Messages or a password manager. Their windows will be excluded when you share a display."))
                            .frame(minHeight: 130)
                    } else {
                        ForEach(privacyVeil.applications) { app in
                            HStack(spacing: 12) {
                                Image(systemName: "eye.slash.fill").foregroundStyle(Theme.attention)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.name).font(.headline)
                                    Text(app.bundleIdentifier).font(.caption.monospaced()).foregroundStyle(Theme.textMuted)
                                }
                                Spacer()
                                Button(role: .destructive) { privacyVeil.remove(app) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain).help("Remove \(app.name) from hidden apps")
                            }
                            .padding(.vertical, 5)
                            if app.id != privacyVeil.applications.last?.id { Divider() }
                        }
                    }
                    HStack {
                        Text("App exclusions hide every window of that app. To share just one window, choose Window when you share.")
                            .font(.caption).foregroundStyle(Theme.textMuted)
                        Spacer()
                        Button { privacyVeil.addApplicationsFromPanel() } label: {
                            Label("Add apps", systemImage: "plus")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                } else {
                    Label("App hiding requires macOS 15.2 or later", systemImage: "info.circle")
                    Text("You can still share a specific window instead of a full display.")
                        .font(.callout).foregroundStyle(Theme.textMuted)
                }
            }
            Text("Privacy changes apply to the next share. The active share keeps the filter you approved when it started. Pairwise stops a share when a protected app opens or closes.")
                .font(.caption).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            SettingsCard {
                Label("Browser tabs", systemImage: "safari").font(.headline)
                Text("macOS shares or excludes windows and apps, not individual browser tabs. Hide the whole browser app, or share a different window. Notification banners can still appear; use a Focus mode to silence them.")
                    .font(.callout).foregroundStyle(Theme.textMuted)
            }
            if !rtc.privacyVeilAppNames.isEmpty {
                SettingsCard {
                    Label("Currently hidden", systemImage: "eye.slash.fill").font(.headline)
                    Text(rtc.privacyVeilAppNames.joined(separator: ", "))
                        .font(.callout).foregroundStyle(Theme.textMuted)
                    Text("Remote control is paused while apps are hidden.")
                        .font(.caption).foregroundStyle(Theme.textMuted)
                }
            }
        }
    }

    private var permissionsSection: some View {
        SettingsPage(title: "Permissions", subtitle: "Each permission is requested only when you use its feature. You can still join calls and view shares without optional access.") {
            SettingsCard {
                permissionRow("Microphone", detail: "Needed to speak on a call.", granted: permissions.microphone,
                              allow: { Task { await permissions.requestMicrophone() } }, settings: { permissions.open("Privacy_Microphone") })
                Divider()
                permissionRow("Camera", detail: "Optional video, turned on only by you.", granted: permissions.camera,
                              allow: { Task { await permissions.requestCamera() } }, settings: { permissions.open("Privacy_Camera") })
                Divider()
                permissionRow("Accessibility", detail: "Optional remote mouse and keyboard control on your Mac.", granted: permissions.accessibility,
                              allow: { permissions.requestAccessibility() }, settings: { permissions.open("Privacy_Accessibility") })
                Divider()
                SettingsRow(title: "Screen sharing", detail: "Choose a display or window in Apple's picker each time. No separate broad screen-recording permission is used.", symbol: "display") {
                    Text("Per share").font(.callout).foregroundStyle(Theme.textMuted)
                }
            }
            HStack {
                Text("Permission status refreshes automatically when you return from System Settings.")
                    .font(.caption).foregroundStyle(Theme.textMuted)
                Spacer()
                Button("Check again") { permissions.refresh() }
            }
        }
    }

    private var cameraStatus: String {
        if rtc.cameraDevices.isEmpty { return "No camera found. Voice and screen sharing remain available." }
        return rtc.isCameraEnabled ? "Camera is on for this call." : "Camera is off. Turn it on from the call controls."
    }

    private func permissionRow(_ title: String, detail: String, granted: Bool,
                               allow: @escaping () -> Void, settings: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? Theme.online : Theme.textMuted)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(Theme.textMuted)
            }
            Spacer()
            Button(granted ? "System Settings" : "Allow") { granted ? settings() : allow() }
        }
        .padding(.vertical, 5)
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).font(.callout).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            content
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceRaised.opacity(0.48), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String
    let symbol: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Theme.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 5)
    }
}
