import SwiftUI
import LiveKit

@main struct PairDeskApp: App {
    @UIApplicationDelegateAdaptor(PairDeskAppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    var body: some Scene { WindowGroup { RootView().environment(model) } }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        NavigationStack {
            Group {
                if model.user == nil { LoginView() }
                else if model.activeRoom != nil { ActiveCallView() }
                else { TeamView() }
            }
            .navigationTitle("PairDesk")
            .toolbar {
                if model.user != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Toggle("Available", isOn: Binding(get: { model.available }, set: model.setAvailable))
                            Button("Sign out", role: .destructive) { Task { await model.logout() } }
                        } label: { Image(systemName: "person.crop.circle") }
                    }
                }
            }
        }
        .tint(.indigo)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            guard model.user != nil else { return }
            PairDeskAppDelegate.requestNotificationAuthorizationAfterAuthentication()
        }
        .alert("PairDesk", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct LoginView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            Section("Your team server") {
                TextField("https://pairdesk.example.com", text: Binding(get: { model.server }, set: { model.server = $0 }))
                    .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
            }
            Section("Sign in") {
                TextField("Email", text: Binding(get: { model.email }, set: { model.email = $0 }))
                    .textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                SecureField("Password", text: Binding(get: { model.password }, set: { model.password = $0 }))
                Button { Task { await model.login() } } label: {
                    HStack { Spacer(); if model.busy { ProgressView() } else { Text("Sign in").bold() }; Spacer() }
                }.disabled(model.busy || model.email.isEmpty || model.password.isEmpty)
            }
            Section { Text("Use the email and password provided by your PairDesk team administrator.").font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

struct TeamView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.available ? "Available on mobile" : "Offline on mobile").font(.headline)
                        Text("Calls ring here while PairDesk is open").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Available", isOn: Binding(get: { model.available }, set: model.setAvailable)).labelsHidden()
                }
            }
            if !model.incoming.isEmpty {
                Section("Incoming calls") {
                    ForEach(model.incoming) { item in
                        VStack(alignment: .leading, spacing: 9) {
                            Label(item.caller.name, systemImage: "phone.arrow.down.left")
                            HStack {
                                Button("Accept") { Task { await model.accept(item) } }.buttonStyle(.borderedProminent)
                                Button("Decline", role: .destructive) { Task { await model.decline(item) } }.buttonStyle(.bordered)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
            if !model.outgoing.isEmpty {
                Section("Ringing") { ForEach(model.outgoing) { Text("Calling \($0.target.name)…").foregroundStyle(.secondary) } }
            }
            if !model.pendingJoinRequests.isEmpty {
                Section("Join requests") {
                    ForEach(model.pendingJoinRequests) { request in
                        VStack(alignment: .leading, spacing: 9) {
                            Text("\(request.requester.name) wants to join your call")
                            HStack {
                                Button("Allow") { Task { await model.respond(request, accept: true) } }.buttonStyle(.borderedProminent)
                                Button("Decline", role: .destructive) { Task { await model.respond(request, accept: false) } }.buttonStyle(.bordered)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
            if let request = model.myJoinRequest {
                Section("Join request sent") { Label("Waiting for \(request.room.participants.map(\.name).joined(separator: ", "))", systemImage: "hourglass") }
            }
            Section("Your team") {
                ForEach(model.teammates.filter { $0.id != model.user?.id }.sorted { ($0.online ?? false) && !($1.online ?? false) }) { person in
                    HStack(spacing: 12) {
                        ZStack { Circle().fill(person.online == true ? Color.green.opacity(0.16) : Color.gray.opacity(0.14)).frame(width: 40, height: 40); Text(person.initials).font(.caption.bold()) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(person.name)
                            Text(person.busy == true ? "In a call" : person.online == true ? "Online" : "Offline")
                                .font(.caption).foregroundStyle(person.online == true ? .green : .secondary)
                        }
                        Spacer()
                        if person.online == true && person.busy != true {
                            Button { Task { await model.call(person) } } label: { Image(systemName: "phone.fill").frame(width: 38, height: 38) }
                                .buttonStyle(.borderedProminent).clipShape(Circle()).accessibilityLabel("Call \(person.name)")
                        }
                    }.padding(.vertical, 3)
                }
            }
            if !model.activeCalls.isEmpty {
                Section("Calls you can join") {
                    ForEach(model.activeCalls) { room in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(room.participants.map(\.name).joined(separator: ", ")).font(.subheadline)
                                Text("\(room.participantCount) people · request to join").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Join") { Task { await model.requestJoin(room) } }.buttonStyle(.bordered)
                                .disabled(model.myJoinRequest != nil)
                        }
                    }
                }
            }
        }
        .refreshable { await model.refresh() }
        .overlay { if model.teammates.isEmpty { ContentUnavailableView("Loading your team", systemImage: "person.2", description: Text("PairDesk checks team presence every few seconds.")) } }
    }
}

struct ActiveCallView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform.circle.fill").font(.system(size: 84)).symbolRenderingMode(.palette).foregroundStyle(.indigo, .indigo.opacity(0.18))
            Text(model.activeRoom?.participants.map(\.name).joined(separator: ", ") ?? "PairDesk call")
                .font(.title2.bold()).multilineTextAlignment(.center)
            Text("Voice call · \(model.activeRoom?.participantCount ?? 1) connected")
                .foregroundStyle(.secondary)
            if !model.call.videoTiles.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(model.call.videoTiles) { tile in
                            VStack(spacing: 5) {
                                SwiftUIVideoView(tile.track, mirrorMode: tile.id == "local" ? .mirror : .auto)
                                    .frame(width: 160, height: 120).clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(tile.name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.horizontal)
                }.frame(height: 150)
            }
            if let request = model.pendingJoinRequests.first {
                VStack(spacing: 10) {
                    Text("\(request.requester.name) wants to join").font(.headline)
                    HStack {
                        Button("Allow") { Task { await model.respond(request, accept: true) } }.buttonStyle(.borderedProminent)
                        Button("Decline") { Task { await model.respond(request, accept: false) } }.buttonStyle(.bordered)
                    }
                }.padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
            Spacer()
            HStack(spacing: 20) {
                ControlButton(title: model.call.microphoneOn ? "Mute" : "Unmute", icon: model.call.microphoneOn ? "mic.fill" : "mic.slash.fill", active: model.call.microphoneOn) {
                    Task { try? await model.call.toggleMicrophone() }
                }
                ControlButton(title: model.call.speakerOn ? "Speaker" : "Earpiece", icon: model.call.speakerOn ? "speaker.wave.2.fill" : "ear", active: model.call.speakerOn) {
                    do { try model.call.setSpeaker(!model.call.speakerOn) }
                    catch { model.error = "Audio output could not be changed: \(error.localizedDescription)" }
                }
                ControlButton(title: model.call.cameraOn ? "Camera off" : "Camera", icon: model.call.cameraOn ? "video.fill" : "video.slash.fill", active: model.call.cameraOn) {
                    Task { do { try await model.call.toggleCamera() } catch { model.error = error.localizedDescription } }
                }
            }
            Button(role: .destructive) { Task { await model.leaveCall() } } label: {
                Label("End call", systemImage: "phone.down.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
            }.buttonStyle(.borderedProminent).tint(.red).padding(.horizontal, 36).padding(.bottom, 18)
        }.padding(.top, 24)
    }
}

struct ControlButton: View {
    let title: String; let icon: String; let active: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) { Image(systemName: icon).font(.title3); Text(title).font(.caption) }
                .foregroundColor(active ? Color.primary : Color.white).frame(width: 76, height: 76)
                .background(active ? Color(uiColor: .secondarySystemBackground) : Color(uiColor: .darkGray), in: Circle())
        }.buttonStyle(.plain)
    }
}
