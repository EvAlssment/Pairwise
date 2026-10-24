import Foundation
import Observation
import Security

@MainActor @Observable final class AppModel {
    static let shared = AppModel()
    var server = UserDefaults.standard.string(forKey: "pairdesk.server") ?? "https://api.136-80-31-73.sslip.io"
    var email = ""
    var password = ""
    private(set) var user: TeamUser?
    private(set) var teammates: [TeamUser] = []
    private(set) var calls: [CallInvitation] = []
    private(set) var joinRequests: [CallJoinRequest] = []
    private(set) var activeCalls: [PairRoom] = []
    private(set) var activeRoom: PairRoom?
    private(set) var available = true
    var error: String?
    var busy = false
    let call = CallSession()
    @ObservationIgnored private var token: String?
    @ObservationIgnored var pushRegistrationAPI: (any PushRegistrationAPI)?
    @ObservationIgnored private var alertPushToken: Data?
    @ObservationIgnored private var voipPushToken: Data?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var roomTask: Task<Void, Never>?

    init() { token = Keychain.read("pairdesk.session"); if token != nil { Task { await restore() } } }
    private var api: APIClient { get throws { try APIClient(server: server, token: token) } }
    var incoming: [CallInvitation] { calls.filter { $0.target.id == user?.id && $0.status == "pending" } }
    var outgoing: [CallInvitation] { calls.filter { $0.caller.id == user?.id && $0.status == "pending" } }
    var pendingJoinRequests: [CallJoinRequest] { joinRequests.filter { $0.status == "pending" && $0.requester.id != user?.id } }
    var myJoinRequest: CallJoinRequest? { joinRequests.first { $0.status == "pending" && $0.requester.id == user?.id } }

    func login() async {
        busy = true; error = nil
        defer { busy = false }
        struct Body: Encodable { let email: String; let password: String }
        do {
            let client = try APIClient(server: server)
            let result: LoginResponse = try await client.post("v1/login", body: Body(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password))
            token = result.token; user = result.user; Keychain.write(result.token, key: "pairdesk.session")
            PairDeskAppDelegate.requestNotificationAuthorizationAfterAuthentication()
            pushRegistrationAPI = PairDeskDeviceRegistration(client: try APIClient(server: server, token: result.token), deviceID: DeviceInstallation.id)
            await registerPushTokensIfReady()
            UserDefaults.standard.set(server, forKey: "pairdesk.server")
            password = ""; startPolling()
        } catch { self.error = error.localizedDescription }
    }
    private func restore() async {
        do {
            let me: MeResponse = try await api.get("v1/me")
            user = me.user
            PairDeskAppDelegate.requestNotificationAuthorizationAfterAuthentication()
            pushRegistrationAPI = PairDeskDeviceRegistration(client: try api, deviceID: DeviceInstallation.id)
            await registerPushTokensIfReady()
            startPolling()
        }
        catch { token = nil; Keychain.delete("pairdesk.session") }
    }
    func logout() async {
        refreshTask?.cancel(); roomTask?.cancel()
        await leaveCall()
        try? await pushRegistrationAPI?.unregister()
        pushRegistrationAPI = nil
        struct LogoutBody: Encodable { let deviceId: String }
        try? await api.send("v1/logout", body: LogoutBody(deviceId: DeviceInstallation.id))
        token = nil; user = nil; teammates = []; calls = []; activeCalls = []; joinRequests = []
        Keychain.delete("pairdesk.session")
    }
    private func startPolling() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
    func setAvailable(_ value: Bool) { available = value; Task { await refresh() } }
    func receivedAlertPushToken(_ deviceToken: Data) async {
        alertPushToken = deviceToken
        await registerPushTokensIfReady()
    }
    func receivedVoIPToken(_ deviceToken: Data) async {
        voipPushToken = deviceToken
        await registerPushTokensIfReady()
    }
    func invalidatedVoIPToken() async {
        voipPushToken = nil
        await registerPushTokensIfReady()
    }
    private func registerPushTokensIfReady() async {
        guard let pushRegistrationAPI, let alertPushToken else { return }
        do { try await pushRegistrationAPI.register(pushToken: alertPushToken, voipToken: voipPushToken) }
        catch { self.error = "Push registration failed: \(error.localizedDescription)" }
    }
    func refresh() async {
        guard user != nil else { return }
        do {
            if available { try await api.send("v1/heartbeat", body: EmptyBody()) }
            async let people: UsersResponse = api.get("v1/users")
            async let allCalls: CallsResponse = api.get("v1/calls")
            async let requests: JoinRequestsResponse = api.get("v1/join-requests")
            async let active: ActiveCallsResponse = api.get("v1/active-calls")
            let (p, c, j, a) = try await (people, allCalls, requests, active)
            teammates = p.users; calls = c.calls; joinRequests = j.requests; activeCalls = a.calls
            PairDeskAppDelegate.reconcileIncomingCalls(with: c.calls, activeRoomID: activeRoom?.id)
            if activeRoom == nil, let accepted = j.requests.first(where: {
                $0.requester.id == user?.id && $0.status == "accepted"
            }) { await join(accepted.room); return }
            if let current = activeRoom {
                try? await api.send("v1/rooms/\(current.id)/heartbeat", body: EmptyBody())
            }
        } catch { self.error = error.localizedDescription }
    }
    func call(_ person: TeamUser) async {
        struct Body: Encodable { let userId: String; let roomId: String? }
        do {
            let response: CallResponse = try await api.post("v1/calls", body: Body(userId: person.id, roomId: activeRoom?.id))
            if activeRoom == nil { await join(response.call.room) }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func accept(_ invitation: CallInvitation) async {
        do {
            let result: CallResponse = try await api.post("v1/calls/\(invitation.id)/accept", body: EmptyBody())
            await join(result.call.room)
        } catch { self.error = error.localizedDescription }
    }
    func answerCallFromCallKit(invitationID: String) async throws {
        if user == nil, token != nil { await restore() }
        guard let user else { throw APIError(message: "Sign in to PairDesk before answering this call.") }
        let response: CallsResponse = try await api.get("v1/calls")
        guard let invitation = response.calls.first(where: { $0.id == invitationID && $0.target.id == user.id && $0.status == "pending" }) else {
            throw APIError(message: "This call has ended or is no longer available.")
        }
        let accepted: CallResponse = try await api.post("v1/calls/\(invitation.id)/accept", body: EmptyBody())
        do { try await joinRoom(accepted.call.room, startMicrophone: false) }
        catch {
            try? await api.send("v1/rooms/\(accepted.call.room.id)/leave", body: EmptyBody())
            throw error
        }
    }
    func decline(_ invitation: CallInvitation) async {
        do { try await api.send("v1/calls/\(invitation.id)/decline", body: EmptyBody()); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func endCallFromCallKit(invitationID: String) async {
        if activeRoom != nil { await leaveCall(); return }
        guard let user else { return }
        do {
            let response: CallsResponse = try await api.get("v1/calls")
            guard let invite = response.calls.first(where: { $0.id == invitationID && $0.target.id == user.id }) else { return }
            try await api.send("v1/calls/\(invite.id)/decline", body: EmptyBody())
        } catch { self.error = error.localizedDescription }
    }
    func requestJoin(_ room: PairRoom) async {
        do { let _: JoinRequestResponse = try await api.post("v1/rooms/\(room.id)/join-requests", body: EmptyBody()); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func respond(_ request: CallJoinRequest, accept: Bool) async {
        do {
            let _: JoinRequestResponse = try await api.post("v1/join-requests/\(request.id)/\(accept ? "accept" : "decline")", body: EmptyBody())
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func join(_ room: PairRoom) async {
        do { try await joinRoom(room) }
        catch { self.error = error.localizedDescription; try? await api.send("v1/rooms/\(room.id)/leave", body: EmptyBody()) }
    }
    private func joinRoom(_ room: PairRoom, startMicrophone: Bool = true) async throws {
        guard activeRoom == nil else { throw APIError(message: "You are already in a call.") }
        let result: JoinResponse = try await api.post("v1/rooms/\(room.id)/join", body: EmptyBody())
        try await call.join(url: result.url, token: result.token, startMicrophone: startMicrophone)
        activeRoom = result.room
        roomTask?.cancel()
        roomTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, let room = self.activeRoom else { break }
                try? await self.api.send("v1/rooms/\(room.id)/heartbeat", body: EmptyBody())
            }
        }
    }
    func leaveCall() async {
        roomTask?.cancel(); roomTask = nil
        let room = activeRoom; activeRoom = nil
        PairDeskAppDelegate.reportActiveCallsEnded()
        await call.leave()
        if let room { try? await api.send("v1/rooms/\(room.id)/leave", body: EmptyBody()) }
        await refresh()
    }
}

enum Keychain {
    static func read(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ value: String, key: String) {
        delete(key); let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key, kSecValueData as String: Data(value.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }
    static func delete(_ key: String) { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key] as CFDictionary) }
}
