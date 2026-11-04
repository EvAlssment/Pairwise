import Foundation
import Testing
@testable import PairDeskModel

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static var backend: FixtureBackend!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.backend.response(to: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class FixtureBackend: @unchecked Sendable {
    private let lock = NSLock()
    var meStatus = 200
    var offline = false
    var approveImmediately = false
    var requestStatus = "pending"
    var requestExists = false
    var roomEnded = false
    func edit(_ action: (FixtureBackend) -> Void) { lock.withLock { action(self) } }
    let me: [String: Any] = ["id": "me", "name": "Fixture user", "email": "me@example.invalid", "online": true]
    var room: [String: Any] { ["id": "room", "name": "Fixture call", "participantCount": 2, "participants": [me]] }
    func joinRequest(status: String) -> [String: Any] {
        ["id": "request", "status": status, "requester": me, "room": room, "expiresAt": "2099-01-01T00:00:00Z"]
    }
    func response(to request: URLRequest) throws -> (Int, [String: Any]) {
        try lock.withLock {
            if offline { throw URLError(.notConnectedToInternet) }
            switch request.url!.path {
            case "/v1/signup-code": return (202, ["challengeId": "fixture-challenge"])
            case "/v1/signup": return (201, ["token": "new-session", "user": ["id": "new-user", "name": "New Teammate", "email": "new@example.com"]])
            case "/v1/me": return meStatus == 200 ? (200, ["user": me]) : (meStatus, ["error": "Fixture HTTP failure"])
            case "/v1/users": return (200, ["users": [me]])
            case "/v1/calls": return (200, ["calls": []])
            case "/v1/active-calls": return (200, ["calls": [room]])
            case "/v1/join-requests": return (200, ["requests": requestExists ? [joinRequest(status: requestStatus)] : []])
            case "/v1/rooms/room/join-requests":
                requestExists = true
                let posted = joinRequest(status: "pending")
                if approveImmediately { requestStatus = "accepted" }
                return (201, ["request": posted])
            case "/v1/rooms/room/join": return (200, ["room": room, "url": "ws://fixture.invalid", "token": "fixture", "participantIdentity": "me"])
            case "/v1/rooms/room/heartbeat" where roomEnded: return (403, ["error": "join the room first"])
            default: return (200, ["ok": true])
            }
        }
    }
}

@Suite(.serialized) struct CallRecoveryTests {
    @MainActor private func fixture() -> (AppModel, FixtureBackend, () -> Int) {
        let backend = FixtureBackend()
        FixtureProtocol.backend = backend
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        var clearCount = 0
        let credentials = SessionCredentialStore(read: { "fixture-session" }, write: { _ in }, clear: { clearCount += 1 })
        let model = AppModel(credentials: credentials, session: URLSession(configuration: config), restoreOnLaunch: false)
        model.server = "http://127.0.0.1"
        return (model, backend, { clearCount })
    }
    @MainActor private func room() -> PairRoom {
        PairRoom(id: "room", name: "Fixture call", participantCount: 2,
                 participants: [TeamUser(id: "me", name: "Fixture user", email: "me@example.invalid")])
    }
    @MainActor private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test(arguments: [true, false]) @MainActor
    func transientRestoreFailureRetainsSessionAndRetrySucceeds(offline: Bool) async {
        let (model, backend, clears) = fixture()
        backend.edit { $0.offline = offline; $0.meStatus = 503 }
        await model.restore()
        #expect(model.hasSavedSession)
        #expect(clears() == 0)
        #expect(model.user == nil)
        backend.edit { $0.offline = false; $0.meStatus = 200 }
        await model.restore()
        #expect(model.user?.id == "me")
        #expect(clears() == 0)
        await model.logout()
    }

    @Test @MainActor func rejectedSessionIsDiscarded() async {
        let (model, backend, clears) = fixture()
        backend.edit { $0.meStatus = 401 }
        await model.restore()
        #expect(!model.hasSavedSession)
        #expect(clears() == 1)
    }

    @Test @MainActor func verifiedSignupRequestsCodeAndCreatesSession() async throws {
        let (model, _, _) = fixture()
        let challenge = try await model.sendSignupCode(email: " new@example.com ")
        #expect(challenge == "fixture-challenge")
        await model.createAccount(name: "New Teammate", email: "new@example.com", password: "twelve-character-password",
                                  challengeID: challenge, code: "12345678")
        #expect(model.user?.id == "new-user")
    }

    @Test @MainActor func immediateApprovalJoinsOnceAndLeavingDoesNotRejoinHistory() async throws {
        let (model, backend, _) = fixture()
        await model.restore()
        backend.edit { $0.approveImmediately = true }
        await model.requestJoin(room())
        try await settle { model.activeRoom != nil }
        #expect(model.call.joinAttempts == 1)
        await model.leaveCall()
        await model.refresh()
        #expect(model.activeRoom == nil)
        #expect(model.call.joinAttempts == 1)
        await model.logout()
    }

    @Test @MainActor func busyApprovalConnectsWhenTheActionCompletes() async throws {
        let (model, backend, _) = fixture()
        await model.restore()
        await model.requestJoin(room())
        model.busy = true
        backend.edit { $0.requestStatus = "accepted" }
        await model.refresh()
        #expect(model.activeRoom == nil)
        model.busy = false
        try await settle { model.activeRoom != nil }
        await model.logout()
    }

    @Test @MainActor func failedAdmissionCanBeRetriedWithoutAutomaticRejoinLoop() async throws {
        let (model, backend, _) = fixture()
        await model.restore()
        model.call.shouldFailJoin = true
        backend.edit { $0.approveImmediately = true }
        await model.requestJoin(room())
        try await settle { model.call.joinAttempts == 1 && !model.busy }
        await model.refresh()
        #expect(model.call.joinAttempts == 1)
        let request = try #require(model.approvedJoinRequests.first)
        model.call.shouldFailJoin = false
        await model.retryApprovedJoinRequest(request)
        #expect(model.activeRoom != nil)
        #expect(model.call.joinAttempts == 2)
        await model.logout()
    }

    @Test @MainActor func remoteDisconnectClearsActiveCallState() async throws {
        let (model, _, _) = fixture()
        await model.restore()
        await model.join(room())
        model.call.simulateRemoteDisconnect()
        try await settle { model.activeRoom == nil }
        #expect(!model.call.connected)
        await model.logout()
    }

    @Test @MainActor func terminalRoomHeartbeatClearsActiveCallState() async {
        let (model, backend, _) = fixture()
        await model.restore()
        await model.join(room())
        backend.edit { $0.roomEnded = true }
        await model.refresh()
        #expect(model.activeRoom == nil)
        #expect(!model.call.connected)
        await model.logout()
    }
}
