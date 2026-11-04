import Foundation
import Observation
import Security
import PairwiseCore

struct SessionCredentialStore {
    let read: () -> String?
    let write: (String) -> Void
    let clear: () -> Void
    static var keychain: Self {
        Self(read: { Keychain.read("pairdesk.session") },
             write: { Keychain.write($0, key: "pairdesk.session") },
             clear: { Keychain.delete("pairdesk.session") })
    }
}

@MainActor @Observable final class AppModel {
    static let shared = AppModel()
    var server = UserDefaults.standard.string(forKey: "pairdesk.server") ?? "https://api.136-80-31-73.sslip.io"
    var email = ""
    var password = ""
    private(set) var signupPolicy: SignupPolicy?
    private(set) var user: TeamUser?
    private(set) var teammates: [TeamUser] = []
    private(set) var calls: [CallInvitation] = []
    private(set) var joinRequests: [CallJoinRequest] = []
    private(set) var activeCalls: [PairRoom] = []
    private(set) var activeRoom: PairRoom?
    private(set) var available = true
    var error: String?
    var busy = false {
        didSet {
            if !busy { Task { @MainActor [weak self] in await self?.connectApprovedJoinRequest() } }
        }
    }
    let call: CallSession
    @ObservationIgnored private let credentials: SessionCredentialStore
    @ObservationIgnored private let apiSession: URLSession
    @ObservationIgnored private var token: String?
    @ObservationIgnored var pushRegistrationAPI: (any PushRegistrationAPI)?
    @ObservationIgnored private var alertPushToken: Data?
    @ObservationIgnored private var voipPushToken: Data?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var roomTask: Task<Void, Never>?
    private var joinApprovals = JoinApprovalTracker()
    private var restoringSession = false
    private var leavingCall = false

    init(credentials: SessionCredentialStore = .keychain, session: URLSession = .shared,
         call: CallSession? = nil, restoreOnLaunch: Bool = true) {
        self.credentials = credentials
        self.apiSession = session
        self.call = call ?? CallSession()
        token = credentials.read()
        self.call.onDisconnected = { [weak self] in
            guard let self, let roomID = self.activeRoom?.id else { return }
            Task { @MainActor [weak self] in
                guard let self, self.activeRoom?.id == roomID, !self.call.connected else { return }
                await self.leaveCall()
            }
        }
        if restoreOnLaunch, token != nil { Task { await restore() } }
    }
    var hasSavedSession: Bool { token != nil }
    var approvedJoinRequests: [CallJoinRequest] {
        guard activeRoom == nil, let user else { return [] }
        return joinRequests.filter {
            $0.status == "accepted" && $0.requester.id == user.id && joinApprovals.isAwaitingConnection($0.id) &&
            $0.room.participants.contains(where: { $0.id == user.id })
        }
    }
    private var api: APIClient { get throws { try APIClient(server: server, token: token, session: apiSession) } }
    var incoming: [CallInvitation] { calls.filter { $0.target.id == user?.id && $0.status == "pending" } }
    var outgoing: [CallInvitation] { calls.filter { $0.caller.id == user?.id && $0.status == "pending" } }
    var pendingJoinRequests: [CallJoinRequest] { joinRequests.filter { $0.status == "pending" && $0.requester.id != user?.id } }
    var myJoinRequest: CallJoinRequest? { joinRequests.first { $0.status == "pending" && $0.requester.id == user?.id } }

    func login() async {
        busy = true; error = nil
        defer { busy = false }
        struct Body: Encodable { let email: String; let password: String }
        do {
            let client = try APIClient(server: server, session: apiSession)
            let result: LoginResponse = try await client.post("v1/login", body: Body(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password))
            await beginSession(result)
        } catch { self.error = error.localizedDescription }
    }
    func loadSignupPolicy() async {
        signupPolicy = nil
        do {
            let client = try APIClient(server: server, session: apiSession)
            signupPolicy = try await client.get("v1/signup-policy")
        } catch { self.error = error.localizedDescription }
    }
    func sendSignupCode(email: String) async throws -> String {
        struct Body: Encodable { let email: String }
        let client = try APIClient(server: server, session: apiSession)
        let response: SignupCodeResponse = try await client.post("v1/signup-code", body: Body(email: email.trimmingCharacters(in: .whitespacesAndNewlines)))
        return response.challengeId
    }
    func createAccount(name: String, email: String, password: String, challengeID: String?, code: String?) async {
        busy = true; error = nil
        defer { busy = false }
        struct Body: Encodable {
            let name: String; let email: String; let password: String
            let challengeId: String?; let code: String?
        }
        do {
            let client = try APIClient(server: server, session: apiSession)
            let response: LoginResponse = try await client.post("v1/signup", body: Body(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password,
                challengeId: challengeID, code: code))
            await beginSession(response)
        } catch { self.error = error.localizedDescription }
    }
    private func beginSession(_ result: LoginResponse) async {
        token = result.token; user = result.user; credentials.write(result.token)
        PairDeskAppDelegate.requestNotificationAuthorizationAfterAuthentication()
        do {
            pushRegistrationAPI = PairDeskDeviceRegistration(client: try APIClient(server: server, token: result.token, session: apiSession), deviceID: DeviceInstallation.id)
            await registerPushTokensIfReady()
        } catch { self.error = error.localizedDescription }
        UserDefaults.standard.set(server, forKey: "pairdesk.server")
        password = ""; startPolling()
    }
    func restore() async {
        guard user == nil, token != nil, !restoringSession else { return }
        restoringSession = true
        busy = true
        error = nil
        defer { restoringSession = false; busy = false }
        do {
            let me: MeResponse = try await api.get("v1/me")
            user = me.user
            PairDeskAppDelegate.requestNotificationAuthorizationAfterAuthentication()
            pushRegistrationAPI = PairDeskDeviceRegistration(client: try api, deviceID: DeviceInstallation.id)
            await registerPushTokensIfReady()
            startPolling()
        }
        catch {
            if (error as? APIError)?.status == 401 {
                token = nil
                credentials.clear()
            }
            self.error = error.localizedDescription
        }
    }
    func logout() async {
        refreshTask?.cancel(); roomTask?.cancel()
        await leaveCall()
        try? await pushRegistrationAPI?.unregister()
        pushRegistrationAPI = nil
        struct LogoutBody: Encodable { let deviceId: String }
        try? await api.send("v1/logout", body: LogoutBody(deviceId: DeviceInstallation.id))
        token = nil; user = nil; teammates = []; calls = []; activeCalls = []; joinRequests = []
        credentials.clear()
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
            await connectApprovedJoinRequest()
            if let current = activeRoom { await heartbeat(current) }
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
        guard !busy, activeRoom == nil else { return }
        busy = true
        defer { busy = false }
        do {
            let response: JoinRequestResponse = try await api.post("v1/rooms/\(room.id)/join-requests", body: EmptyBody())
            joinApprovals.clear()
            joinApprovals.requestCreated(response.request.id)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func retryApprovedJoinRequest(_ request: CallJoinRequest) async {
        await connectApprovedJoinRequest(retrying: request.id)
    }
    private func connectApprovedJoinRequest(retrying id: String? = nil) async {
        guard !busy, activeRoom == nil,
              let request = approvedJoinRequests.first(where: { request in
                  if let id { return request.id == id }
                  return joinApprovals.shouldAutomaticallyJoin(request.id)
              }) else { return }
        busy = true
        defer { busy = false }
        joinApprovals.beginAttempt(request.id)
        do {
            try await joinRoom(request.room)
            joinApprovals.didJoin(request.id)
        } catch { self.error = error.localizedDescription }
    }
    private func heartbeat(_ room: PairRoom) async {
        do { try await api.send("v1/rooms/\(room.id)/heartbeat", body: EmptyBody()) }
        catch {
            if activeRoom?.id == room.id, let status = (error as? APIError)?.status,
               [403, 404, 409].contains(status) { await leaveCall() }
            else { self.error = error.localizedDescription }
        }
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
                await self.heartbeat(room)
            }
        }
    }
    func leaveCall() async {
        guard !leavingCall else { return }
        leavingCall = true
        defer { leavingCall = false }
        joinApprovals.clear()
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
