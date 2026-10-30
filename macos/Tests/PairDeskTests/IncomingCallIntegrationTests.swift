import AppKit
import CoreVideo
import Testing
@preconcurrency import LiveKit
@testable import PairDesk

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PAIRDESK_TEST_API"] != nil,
                            "Run scripts/test-call.sh for API, media, and popup integration"))
struct IncomingCallIntegrationTests {
    @Test @MainActor
    func testNewCompletedCallHasStableDurationForBothClients() async throws {
        try await withClients { clients in
            let caller = clients[0], recipient = clients[1]
            let person = try #require(caller.users.first { $0.id == recipient.user?.id })
            await caller.call(person)
            #expect(caller.error == nil)
            await recipient.refreshInvitations()
            let invitation = try #require(recipient.incomingCall)
            await recipient.acceptCall(invitation)
            #expect(recipient.error == nil)
            try await settle { caller.rtc.participants.count == 2 && recipient.rtc.participants.count == 2 }
            try await Task.sleep(for: .seconds(1))
            await caller.leave()
            try await settle { !recipient.rtc.connected }

            var completed: [CallInvitation] = []
            for client in [caller, recipient] {
                await client.refreshInvitations()
                let call = try #require(client.callInvitations.first { $0.id == invitation.id })
                let start = try #require(ServerDate.parse(call.startedAt))
                let end = try #require(call.endedDate)
                #expect(end.timeIntervalSince(start) >= 1)
                #expect(call.historyStatusLabel(incoming: client === recipient) == "Call ended")
                #expect(call.historyDurationText?.hasPrefix("Duration ") == true)
                #expect(call.historyDurationText != "Duration unavailable")
                #expect(call.historyDateText?.hasPrefix("Ended ") == true)
                completed.append(call)
                await client.refreshInvitations()
                #expect(client.callInvitations.first { $0.id == call.id } == call,
                        "Polling must not change the saved end time or duration")
            }
            #expect(completed[0].startedAt == completed[1].startedAt)
            #expect(completed[0].endedAt == completed[1].endedAt)
            #expect(completed[0].historyDurationText == completed[1].historyDurationText)
        }
    }

    @Test @MainActor
    func testDeclineSoundsOnBothSidesAndGroupDepartureSoundsOnce() async throws {
        let saved = UserDefaults.standard.object(forKey: "playCallSounds")
        defer { UserDefaults.standard.set(saved, forKey: "playCallSounds") }
        let endings = (0..<4).map { _ in CallEventTone() }
        try await withClients(audio: { index in
            CallAudioFeedback { $0 == .disconnected ? endings[index] : nil }
        }) { clients in
            let a = clients[0], b = clients[1], c = clients[2]
            for client in clients { client.playCallSounds = true }
            let bPerson = try #require(a.users.first { $0.id == b.user?.id })
            let cPerson = try #require(a.users.first { $0.id == c.user?.id })
            await a.call(bPerson)
            await b.refreshInvitations()
            await b.declineCall(try #require(b.incomingCall))
            await a.refreshInvitations()
            #expect(endings[0].plays == 1 && endings[1].plays == 1)
            await a.refreshInvitations()
            await b.refreshInvitations()
            #expect(endings[0].plays == 1 && endings[1].plays == 1)
            await a.refresh()
            await b.refresh()
            await a.call(bPerson)
            await b.refreshInvitations()
            await b.acceptCall(try #require(b.incomingCall))
            try await settle { a.rtc.participants.count == 2 && b.rtc.participants.count == 2 }
            await a.call(cPerson)
            await c.refreshInvitations()
            await c.declineCall(try #require(c.incomingCall))
            await a.refreshInvitations()
            await b.refreshInvitations()
            #expect(endings[0].plays == 2 && endings[2].plays == 1)
            #expect(endings[1].plays == 1, "Another member's declined invitation must not sound like a departure")
            #expect(a.rtc.connected && b.rtc.connected)
            await a.call(cPerson)
            await c.refreshInvitations()
            await c.acceptCall(try #require(c.incomingCall))
            try await settle { a.rtc.participants.count == 3 && b.rtc.participants.count == 3 }
            await c.leave()
            try await settle { a.rtc.participants.count == 2 && b.rtc.participants.count == 2 }
            #expect(endings[0].plays == 3 && endings[1].plays == 2)
            #expect(endings[2].plays == 2, "The person leaving gets the existing hang-up cue once")
            await a.refreshInvitations()
            await b.refreshInvitations()
            #expect(endings[0].plays == 3 && endings[1].plays == 2)
            #expect(a.rtc.connected && b.rtc.connected)
            // The in-call Accept/Decline popup also handles requests to join.
            await c.requestToJoin(try #require(a.activeRoom))
            await b.refreshInvitations()
            await b.declineJoinRequest(try #require(b.incomingJoinRequests.first))
            await c.refreshInvitations()
            await a.refreshInvitations()
            #expect(endings[1].plays == 3 && endings[2].plays == 3)
            #expect(endings[0].plays == 3, "Only the responder and requester hear a declined join request")
            await b.refreshInvitations()
            await c.refreshInvitations()
            #expect(endings[1].plays == 3 && endings[2].plays == 3)
            a.playCallSounds = false
            await b.leave()
            try await settle { !a.rtc.connected }
            #expect(endings[0].plays == 3, "Disabled sounds must stay silent on the final departure")
        }
    }

    @Test @MainActor
    func testEveryGroupMemberSeesAnotherMembersInviteAndJoiningState() async throws {
        try await withClients { clients in
            let a = clients[0], b = clients[1], c = clients[2], outsider = clients[3]
            let aID = try #require(a.user?.id)
            let bPerson = try #require(a.users.first { $0.id == b.user?.id })
            await a.call(bPerson)
            #expect(a.error == nil)
            await b.refreshInvitations()
            let firstCall = try #require(b.incomingCall)
            await b.acceptCall(firstCall)
            try await settle { a.rtc.participants.count == 2 && b.rtc.participants.count == 2 }
            let roomID = try #require(b.activeRoom?.id)
            let cPerson = try #require(a.users.first { $0.id == c.user?.id })
            await a.call(cPerson)
            #expect(a.error == nil)
            await b.refreshInvitations()
            let invitation = try #require(b.pendingCallInvitations.first { $0.target.id == c.user?.id })
            #expect(invitation.caller.id == aID)
            #expect(invitation.status == "pending")
            #expect(b.outgoingCalls.isEmpty)
            #expect(b.incomingCallPrompts.isEmpty)
            #expect(!invitation.canCancelPendingInvitation(userID: b.user?.id))
            #expect(!b.availablePeople.contains { $0.id == cPerson.id })
            await outsider.refreshInvitations()
            #expect(!outsider.callInvitations.contains { $0.id == invitation.id })
            do {
                try await b.api.send("v1/calls/\(invitation.id)/cancel", body: EmptyBody())
                Issue.record("A different member cancelled the caller's invitation")
            } catch let error as APIError { #expect(error.status == 403) }
            // Accept without connecting C's media yet, so B must see Joining….
            let accepted: CallResponse = try await c.api.post("v1/calls/\(invitation.id)/accept", body: EmptyBody())
            await b.refreshInvitations()
            #expect(b.pendingCallInvitations.first { $0.id == invitation.id }?.status == "accepted")
            await c.join(accepted.call.room)
            #expect(c.error == nil)
            try await settle { b.rtc.participants.contains { $0.identity == cPerson.id } }
            #expect(!b.pendingCallInvitations.contains { $0.id == invitation.id }, "The connected member replaces the pending row")
            #expect(b.activeRoom?.id == roomID)
            #expect(b.rtc.connected)
        }
    }

    @Test @MainActor
    func testSharedScreenViewerClosesAndReopensOverLiveKitWithoutEndingCall() async throws {
        _ = NSApplication.shared
        let address = try #require(ProcessInfo.processInfo.environment["PAIRDESK_TEST_API"])
        let password = try #require(ProcessInfo.processInfo.environment["PAIRDESK_TEST_PASSWORD"])
        struct LoginBody: Encodable { let email: String; let password: String }
        struct RoomBody: Encodable { let name: String }
        struct ShareBody: Encodable { let enabled: Bool }
        let unsigned = try APIClient(server: address)
        var logins: [LoginResponse] = []
        var clients: [APIClient] = []
        for i in 1...2 {
            let login: LoginResponse = try await unsigned.post("v1/login", body: LoginBody(
                email: "integration-\(i)@pairdesk.invalid", password: password))
            logins.append(login)
            clients.append(try APIClient(server: address, token: login.token))
        }
        let created: RoomResponse = try await clients[0].post("v1/rooms", body: RoomBody(name: "Viewer lifecycle fixture"))
        let host = Room()
        let viewer = AppStore(callAudio: CallAudioFeedback { _ in nil })
        viewer.debugUseSession(user: logins[1].user, token: logins[1].token, server: address)
        let windows = AppWindows()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.register("screen", window)
        defer { window.close() }
        let presenter = SharedScreenPresenter(store: viewer, windows: windows)
        do {
            let hostJoin: JoinResponse = try await clients[0].post("v1/rooms/\(created.room.id)/join", body: EmptyBody())
            try await host.connect(url: hostJoin.url, token: hostJoin.token)
            let viewerJoin: JoinResponse = try await clients[1].post("v1/rooms/\(created.room.id)/join", body: EmptyBody())
            viewer.activeRoom = viewerJoin.room
            try await viewer.rtc.connect(url: viewerJoin.url, token: viewerJoin.token,
                                         identity: viewerJoin.participantIdentity, name: "Viewer")
            try await settle { viewer.rtc.participants.count == 2 }
            #expect(!windows.isShown("screen"))
            try await clients[0].send("v1/rooms/\(created.room.id)/share", body: ShareBody(enabled: true))
            try await settle { host.localParticipant.permissions.canPublishSources.contains(Track.Source.screenShareVideo.rawValue) }
            var pixelBuffer: CVPixelBuffer?
            let result = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                                             [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
            #expect(result == kCVReturnSuccess)
            let frame = try #require(pixelBuffer)
            CVPixelBufferLockBaseAddress(frame, [])
            if let base = CVPixelBufferGetBaseAddress(frame) {
                memset(base, 0, CVPixelBufferGetBytesPerRow(frame) * CVPixelBufferGetHeight(frame))
            }
            CVPixelBufferUnlockBaseAddress(frame, [])
            for _ in 0..<2 {
                let track = await LocalVideoTrack.createBufferTrack(name: "pairdesk.screen.display", source: .screenShareVideo)
                let capturer = try #require(track.capturer as? BufferCapturer)
                capturer.capture(frame)
                let frames = Task { @MainActor in
                    while !Task.isCancelled {
                        capturer.capture(frame)
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                defer { frames.cancel() }
                let publication = try await host.localParticipant.publish(videoTrack: track)
                try await settle { viewer.rtc.screenTrack != nil && windows.isShown("screen") }
                #expect(viewer.rtc.activeSharerIdentity == logins[0].user.id,
                        "The participant badge must identify the subscribed screen's owner")
                try await host.localParticipant.unpublish(publication: publication)
                try await settle { viewer.rtc.screenTrack == nil && !windows.isShown("screen") }
                #expect(viewer.rtc.activeSharerIdentity == nil, "The sharing badge must clear when sharing stops")
                frames.cancel()
                #expect(viewer.rtc.connected)
                #expect(host.connectionState == .connected)
                #expect(viewer.activeRoom?.id == created.room.id)
            }
            withExtendedLifetime(presenter) {}
            // Release the server's share claim and membership while the host
            // is still connected; cleanup errors must not leave a busy fixture.
            try await clients[0].send("v1/rooms/\(created.room.id)/share", body: ShareBody(enabled: false))
            await viewer.leave()
            try await clients[0].send("v1/rooms/\(created.room.id)/leave", body: EmptyBody())
            await host.disconnect()
            let roster: UsersResponse = try await clients[0].request("v1/users")
            for login in logins {
                #expect(roster.users.first(where: { $0.id == login.user.id })?.busy != true)
            }
        } catch {
            try? await clients[0].send("v1/rooms/\(created.room.id)/share", body: ShareBody(enabled: false))
            await viewer.leave()
            try? await clients[0].send("v1/rooms/\(created.room.id)/leave", body: EmptyBody())
            await host.disconnect()
            throw error
        }
    }

    @MainActor
    private func withClients(audio: ((Int) -> CallAudioFeedback)? = nil,
                             _ run: ([AppStore]) async throws -> Void) async throws {
        _ = NSApplication.shared
        let address = try #require(ProcessInfo.processInfo.environment["PAIRDESK_TEST_API"])
        let password = try #require(ProcessInfo.processInfo.environment["PAIRDESK_TEST_PASSWORD"])
        let savedMuted = UserDefaults.standard.object(forKey: "startCallsMuted")
        defer { UserDefaults.standard.set(savedMuted, forKey: "startCallsMuted") }
        struct LoginBody: Encodable { let email: String; let password: String }
        let api = try APIClient(server: address)
        var stores: [AppStore] = []
        for i in 1...4 {
            let login: LoginResponse = try await api.post("v1/login", body: LoginBody(
                email: "integration-notification-\(i)@pairdesk.invalid", password: password))
            let store = AppStore(callAudio: audio?(i - 1) ?? CallAudioFeedback { _ in nil })
            store.debugUseSession(user: login.user, token: login.token, server: address)
            store.startCallsMuted = true
            stores.append(store)
        }
        do {
            // Publish everyone's presence before any client reads the roster.
            for store in stores { try await store.api.send("v1/heartbeat", body: EmptyBody()) }
            for store in stores { await store.refresh() }
            try await run(stores)
        } catch {
            for store in stores { await store.leave() }
            throw error
        }
        for store in stores { await store.leave() }
    }

    @MainActor
    private func settle(until condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(condition(), "Call state did not settle")
    }

    @Test @MainActor
    func testIdlePopupAcceptDeclineAndCallerCancellation() async throws {
        try await withClients { clients in
            let caller = clients[0], recipient = clients[1]
            let windows = AppWindows()
            let presenter = IncomingCallPresenter(store: recipient, windows: windows)
            defer { windows.close("incoming") }
            let person = try #require(caller.users.first { $0.id == recipient.user?.id })

            await caller.call(person)
            #expect(caller.error == nil)
            _ = try #require(caller.activeRoom)
            await recipient.refreshInvitations()
            try await settle { windows.isShown("incoming") }
            let prompt = try #require(recipient.incomingCallPrompts.first)
            #expect(prompt.person.name == caller.user?.name)
            #expect(!prompt.isJoinRequest)
            await recipient.respond(to: prompt, accepting: true)
            #expect(recipient.error == nil)
            #expect(recipient.rtc.connected)
            #expect(recipient.activeRoom?.id == caller.activeRoom?.id)
            try await settle { !windows.isShown("incoming") }
            await recipient.leave()
            await caller.leave()

            await caller.refresh()
            await recipient.refresh()
            await caller.call(person)
            await recipient.refreshInvitations()
            try await settle { windows.isShown("incoming") }
            let declined = try #require(recipient.incomingCallPrompts.first)
            await recipient.respond(to: declined, accepting: false)
            try await settle { !windows.isShown("incoming") }
            #expect(recipient.activeRoom == nil)
            #expect(!recipient.rtc.connected)
            await caller.refreshInvitations()
            await caller.leave()

            await caller.refresh()
            await recipient.refresh()
            await caller.call(person)
            await recipient.refreshInvitations()
            try await settle { windows.isShown("incoming") }
            let cancelled = try #require(caller.outgoingCalls.first)
            await caller.cancelCall(cancelled)
            await recipient.refreshInvitations()
            try await settle { !windows.isShown("incoming") }
            #expect(presenter.shownPromptID == nil)
        }
    }

    @Test @MainActor
    func testActiveCallPopupDeclineCancelAndAcceptWithoutReplacingCall() async throws {
        try await withClients { clients in
            let host = clients[0], peer = clients[1], requester = clients[2], other = clients[3]
            let peerPerson = try #require(host.users.first { $0.id == peer.user?.id })
            await host.call(peerPerson)
            #expect(host.error == nil)
            _ = try #require(host.activeRoom)
            await peer.refreshInvitations()
            await peer.acceptCall(try #require(peer.incomingCall))
            let room = try #require(host.activeRoom)
            let hostWindows = AppWindows(), peerWindows = AppWindows()
            let hostPresenter = IncomingCallPresenter(store: host, windows: hostWindows)
            let peerPresenter = IncomingCallPresenter(store: peer, windows: peerWindows)
            defer { hostWindows.close("incoming"); peerWindows.close("incoming") }

            await requester.requestToJoin(room)
            await host.refreshInvitations()
            await peer.refreshInvitations()
            try await settle { hostWindows.isShown("incoming") && peerWindows.isShown("incoming") }
            let declined = try #require(host.incomingCallPrompts.first)
            #expect(declined.isJoinRequest)
            #expect(declined.person.name == requester.user?.name)
            await host.respond(to: declined, accepting: false)
            await peer.refreshInvitations()
            try await settle { !hostWindows.isShown("incoming") && !peerWindows.isShown("incoming") }
            #expect(host.activeRoom?.id == room.id)
            #expect(host.rtc.connected && peer.rtc.connected)
            #expect(requester.activeRoom == nil)

            await requester.requestToJoin(room)
            await host.refreshInvitations()
            try await settle { hostWindows.isShown("incoming") }
            await requester.cancelJoinRequest(try #require(requester.outgoingJoinRequests.first))
            await host.refreshInvitations()
            try await settle { !hostWindows.isShown("incoming") }

            await other.requestToJoin(room)
            await requester.requestToJoin(room)
            await host.refreshInvitations()
            await peer.refreshInvitations()
            #expect(host.incomingCallPrompts.count == 2)
            let accepted = try #require(peer.incomingCallPrompts.first)
            #expect(accepted.person.id == requester.user?.id, "Respond to the request actually displayed by the popup")
            await peer.respond(to: accepted, accepting: true)
            #expect(peer.error == nil)
            await requester.refreshInvitations()
            #expect(requester.rtc.connected, "Requester must join after acceptance")
            #expect(requester.activeRoom?.id == room.id)
            await host.refreshInvitations()
            try await settle { hostPresenter.shownPromptID != accepted.id && peerPresenter.shownPromptID != accepted.id }
            #expect(host.incomingCallPrompts.count == 1)
            #expect(host.activeRoom?.id == room.id && peer.activeRoom?.id == room.id)
            #expect(host.rtc.connected && peer.rtc.connected)
            let remaining = try #require(host.incomingCallPrompts.first)
            await host.respond(to: remaining, accepting: false)
            await peer.refreshInvitations()
            try await settle { !hostWindows.isShown("incoming") && !peerWindows.isShown("incoming") }
        }
    }

    @Test @MainActor
    func testApprovalWhileBusyConnectsAfterwardsAndDoesNotRejoinAfterLeaving() async throws {
        try await withClients { clients in
            let host = clients[0], peer = clients[1], requester = clients[2]
            await host.call(try #require(host.users.first { $0.id == peer.user?.id }))
            await peer.refreshInvitations()
            await peer.acceptCall(try #require(peer.incomingCall))
            let room = try #require(host.activeRoom)
            await requester.requestToJoin(room)
            requester.busy = true
            await peer.refreshInvitations()
            await peer.acceptJoinRequest(try #require(peer.incomingJoinRequests.first))
            await requester.refreshInvitations()
            #expect(requester.activeRoom == nil)
            requester.busy = false
            try await settle { requester.activeRoom?.id == room.id }
            #expect(requester.rtc.connected)
            await requester.leave()
            await requester.refreshInvitations()
            try await Task.sleep(for: .milliseconds(100))
            #expect(requester.activeRoom == nil)
            #expect(!requester.rtc.connected)
        }
    }

    @Test @MainActor
    func testJoinedParticipantsKeepTheCallWhenBothOriginalParticipantsLeave() async throws {
        try await withClients { clients in
            let host = clients[0], peer = clients[1]
            await host.call(try #require(host.users.first { $0.id == peer.user?.id }))
            await peer.refreshInvitations()
            await peer.acceptCall(try #require(peer.incomingCall))
            let room = try #require(host.activeRoom)
            for requester in clients.suffix(2) {
                await requester.requestToJoin(room)
                await host.refreshInvitations()
                await host.acceptJoinRequest(try #require(host.incomingJoinRequests.first))
                await requester.refreshInvitations()
                try await settle { requester.activeRoom?.id == room.id }
            }
            try await settle { clients[2].rtc.participants.count == 4 && clients[3].rtc.participants.count == 4 }
            await host.leave()
            await peer.leave()
            for remaining in clients.suffix(2) {
                await remaining.refreshInvitations()
                await remaining.refresh()
                #expect(remaining.activeRoom?.id == room.id)
                #expect(remaining.rtc.connected)
            }
            try await settle { clients[2].rtc.participants.count == 2 && clients[3].rtc.participants.count == 2 }
        }
    }
}
