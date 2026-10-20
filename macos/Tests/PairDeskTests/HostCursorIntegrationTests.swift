import AppKit
import SwiftUI
import XCTest
@preconcurrency import LiveKit
@testable import PairDesk

final class HostCursorIntegrationTests: XCTestCase {
    @MainActor
    func testPrivacyVeilIsReportedToViewersAndBlocksControlRequests() async throws {
        guard let address = ProcessInfo.processInfo.environment["PAIRDESK_TEST_API"],
              let password = ProcessInfo.processInfo.environment["PAIRDESK_TEST_PASSWORD"] else {
            throw XCTSkip("Run scripts/test-call.sh for privacy veil control integration")
        }
        _ = NSApplication.shared
        struct LoginBody: Encodable { let email: String; let password: String }
        struct RoomBody: Encodable { let name: String }
        let unsigned = try APIClient(server: address)
        let hostLogin: LoginResponse = try await unsigned.post("v1/login", body: LoginBody(
            email: "integration-1@pairdesk.invalid", password: password))
        let viewerLogin: LoginResponse = try await unsigned.post("v1/login", body: LoginBody(
            email: "integration-2@pairdesk.invalid", password: password))
        let hostClient = try APIClient(server: address, token: hostLogin.token)
        let viewerClient = try APIClient(server: address, token: viewerLogin.token)
        let created: RoomResponse = try await hostClient.post("v1/rooms", body: RoomBody(name: "Privacy veil control"))
        let host = RTCService()
        let statusReceiver = ControlAvailabilityReceiver(expectation: expectation(description: "View-only privacy status received"))
        let viewer = Room(delegate: statusReceiver)
        do {
            let hostJoin: JoinResponse = try await hostClient.post("v1/rooms/\(created.room.id)/join", body: EmptyBody())
            try await host.connect(url: hostJoin.url, token: hostJoin.token,
                                   identity: hostJoin.participantIdentity, name: hostLogin.user.name)
            let viewerJoin: JoinResponse = try await viewerClient.post("v1/rooms/\(created.room.id)/join", body: EmptyBody())
            try await viewer.connect(url: viewerJoin.url, token: viewerJoin.token)
            try await waitFor { host.participants.count == 2 }

            host.debugStartCursorShare(bounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
                                       session: "privacy-share", hiddenApplicationNames: ["Notes"])
            await fulfillment(of: [statusReceiver.expectation], timeout: 5)
            XCTAssertFalse(host.remoteControlAvailable)
            XCTAssertFalse(host.automaticControlEnabled)
            XCTAssertEqual(host.privacyVeilAppNames, ["Notes"], "Hidden app names should remain local to the sharer")
            XCTAssertEqual(statusReceiver.message?.available, false)
            XCTAssertEqual(statusReceiver.message?.reason, RemoteControlUnavailableReason.privacyVeil.rawValue)

            let request = RemoteControlMessage(epoch: "", sequence: 1, kind: .request,
                                               cursorSession: "privacy-share")
            try await viewer.localParticipant.publish(data: JSONEncoder().encode(request),
                options: DataPublishOptions(destinationIdentities: [Participant.Identity(from: hostJoin.participantIdentity)],
                                            topic: "pairdesk.control.v1", reliable: true))
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertNil(host.activeControllerIdentity, "A hidden app share must not grant remote input")
            XCTAssertEqual(host.privacyVeilAppNames, ["Notes"])
            await host.disconnect()
            await viewer.disconnect()
        } catch {
            await host.disconnect()
            await viewer.disconnect()
            try? await hostClient.send("v1/rooms/\(created.room.id)/leave", body: EmptyBody())
            try? await viewerClient.send("v1/rooms/\(created.room.id)/leave", body: EmptyBody())
            throw error
        }
        try? await hostClient.send("v1/rooms/\(created.room.id)/leave", body: EmptyBody())
        try? await viewerClient.send("v1/rooms/\(created.room.id)/leave", body: EmptyBody())
    }

    @MainActor
    func testScreenAnnotationsRelayWithConsentAndNeverBecomeRemoteInput() async throws {
        guard let address = ProcessInfo.processInfo.environment["PAIRDESK_TEST_API"],
              let password = ProcessInfo.processInfo.environment["PAIRDESK_TEST_PASSWORD"] else {
            throw XCTSkip("Run scripts/test-call.sh for annotation relay integration")
        }
        _ = NSApplication.shared
        struct LoginBody: Encodable { let email: String; let password: String }
        struct RoomBody: Encodable { let name: String }
        let unsigned = try APIClient(server: address)
        var clients: [APIClient] = []
        var users: [TeamUser] = []
        for index in 1...3 {
            let login: LoginResponse = try await unsigned.post("v1/login", body: LoginBody(
                email: "integration-annotation-\(index)@pairdesk.invalid", password: password))
            clients.append(try APIClient(server: address, token: login.token))
            users.append(login.user)
        }
        let created: RoomResponse = try await clients[0].post("v1/rooms", body: RoomBody(name: "Screen annotation relay"))
        let host = RTCService()
        let viewer = Room()
        let observer = Room()
        let relayed = AnnotationPacketReceiver(expectation: expectation(description: "Sharer relays annotation to peers"))
        observer.add(delegate: relayed)
        do {
            let hostJoin: JoinResponse = try await clients[0].post("v1/rooms/\(created.room.id)/join", body: EmptyBody())
            try await host.connect(url: hostJoin.url, token: hostJoin.token,
                                   identity: hostJoin.participantIdentity, name: users[0].name)
            let viewerJoin: JoinResponse = try await clients[1].post("v1/rooms/\(created.room.id)/join", body: EmptyBody())
            try await viewer.connect(url: viewerJoin.url, token: viewerJoin.token)
            let observerJoin: JoinResponse = try await clients[2].post("v1/rooms/\(created.room.id)/join", body: EmptyBody())
            try await observer.connect(url: observerJoin.url, token: observerJoin.token)
            try await waitFor { host.participants.count == 3 }

            host.debugStartCursorShare(bounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080), session: "annotation-share")
            let point = ScreenAnnotationMessage(session: "annotation-share", sequence: 1, kind: .point,
                                                strokeID: "stroke-1", point: .init(x: 0.25, y: 0.75))
            try await viewer.localParticipant.publish(data: JSONEncoder().encode(point),
                options: DataPublishOptions(destinationIdentities: [Participant.Identity(from: hostJoin.participantIdentity)],
                                            topic: "pairdesk.annotation.v1", reliable: false))
            try await waitFor { host.screenAnnotations.first?.points.first == point.point }
            await fulfillment(of: [relayed.expectation], timeout: 5)
            let broadcast = try XCTUnwrap(relayed.message)
            XCTAssertEqual(relayed.sender, hostJoin.participantIdentity)
            XCTAssertEqual(broadcast.participantIdentity, viewerJoin.participantIdentity)
            XCTAssertEqual(broadcast.strokeID, "stroke-1")
            XCTAssertTrue(host.remotePointers.isEmpty, "Annotation traffic must not become remote cursor or input")

            host.setAnnotationsAllowed(false)
            let blocked = ScreenAnnotationMessage(session: "annotation-share", sequence: 2, kind: .point,
                                                  strokeID: "stroke-2", point: .init(x: 0.5, y: 0.5))
            try await viewer.localParticipant.publish(data: JSONEncoder().encode(blocked),
                options: DataPublishOptions(destinationIdentities: [Participant.Identity(from: hostJoin.participantIdentity)],
                                            topic: "pairdesk.annotation.v1", reliable: false))
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(host.screenAnnotations.isEmpty, "Disabling annotations must clear marks and reject new points")

            host.setAnnotationsAllowed(true)
            let beforeShareChange = ScreenAnnotationMessage(session: "annotation-share", sequence: 3, kind: .point,
                                                            strokeID: "stroke-before-share-change",
                                                            point: .init(x: 0.7, y: 0.2))
            try await viewer.localParticipant.publish(data: JSONEncoder().encode(beforeShareChange),
                options: DataPublishOptions(destinationIdentities: [Participant.Identity(from: hostJoin.participantIdentity)],
                                            topic: "pairdesk.annotation.v1", reliable: false))
            try await waitFor { host.screenAnnotations.first?.strokeID == "stroke-before-share-change" }
            host.debugStartCursorShare(bounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080), session: "annotation-share-next")
            XCTAssertTrue(host.screenAnnotations.isEmpty, "Changing the share session must clear old marks")
            let afterShareChange = ScreenAnnotationMessage(session: "annotation-share-next", sequence: 1, kind: .point,
                                                           strokeID: "stroke-after-share-change",
                                                           point: .init(x: 0.3, y: 0.4))
            try await viewer.localParticipant.publish(data: JSONEncoder().encode(afterShareChange),
                options: DataPublishOptions(destinationIdentities: [Participant.Identity(from: hostJoin.participantIdentity)],
                                            topic: "pairdesk.annotation.v1", reliable: false))
            try await waitFor { host.screenAnnotations.first?.strokeID == "stroke-after-share-change" }
            await viewer.disconnect()
            try await waitFor { host.participants.count == 2 && host.screenAnnotations.isEmpty }
            await host.disconnect()
            await observer.disconnect()
        } catch {
            await host.disconnect()
            await viewer.disconnect()
            await observer.disconnect()
            for client in clients { try? await client.send("v1/rooms/\(created.room.id)/leave", body: EmptyBody()) }
            throw error
        }
        for client in clients { try? await client.send("v1/rooms/\(created.room.id)/leave", body: EmptyBody()) }
    }

    @MainActor
    func testAuthenticatedCursorPacketsShowNamesOnHostAndClearWithTheShare() async throws {
        guard let address = ProcessInfo.processInfo.environment["PAIRDESK_TEST_API"],
              let password = ProcessInfo.processInfo.environment["PAIRDESK_TEST_PASSWORD"] else {
            throw XCTSkip("Run scripts/test-call.sh for host cursor integration")
        }
        _ = NSApplication.shared
        struct LoginBody: Encodable { let email: String; let password: String }
        struct RoomBody: Encodable { let name: String }
        let unsigned = try APIClient(server: address)
        var clients: [APIClient] = []
        var users: [TeamUser] = []
        for i in 1...2 {
            let login: LoginResponse = try await unsigned.post("v1/login", body: LoginBody(email: "integration-\(i)@pairdesk.invalid", password: password))
            clients.append(try APIClient(server: address, token: login.token))
            users.append(login.user)
        }
        let response: RoomResponse = try await clients[0].post("v1/rooms", body: RoomBody(name: "Host cursor fixture"))
        let host = RTCService()
        let viewer = Room()
        do {
            let hostJoin: JoinResponse = try await clients[0].post("v1/rooms/\(response.room.id)/join", body: EmptyBody())
            try await host.connect(url: hostJoin.url, token: hostJoin.token, identity: hostJoin.participantIdentity, name: users[0].name)
            let viewerJoin: JoinResponse = try await clients[1].post("v1/rooms/\(response.room.id)/join", body: EmptyBody())
            try await viewer.connect(url: viewerJoin.url, token: viewerJoin.token)
            let viewerID = viewerJoin.participantIdentity
            try await waitFor { host.participants.contains { $0.identity == viewerID } }
            // Use real authenticated RTC packets and the production desktop
            // overlay, with synthetic share geometry instead of screen capture.
            host.debugStartCursorShare(bounds: CGRect(x: 100, y: 100, width: 800, height: 500), session: "share-one")
            let panel = try XCTUnwrap(host.debugHostCursorPanel)
            let content = try XCTUnwrap(panel.contentView as? NSHostingView<SharedCursorLayer>)
            func send(_ sequence: UInt64, x: Double = 0.25, y: Double = 0.75,
                      visible: Bool = true, session: String = "share-one") async throws {
                let message = RemoteControlMessage(epoch: session, sequence: sequence, kind: .cursor, x: x, y: y, visible: visible)
                try await viewer.localParticipant.publish(data: JSONEncoder().encode(message),
                    options: DataPublishOptions(destinationIdentities: [Participant.Identity(from: hostJoin.participantIdentity)],
                                                topic: "pairdesk.control.v1", reliable: false))
            }
            try await send(1)
            try await waitFor { host.remotePointers.first?.x == 0.25 }
            XCTAssertTrue(panel.isVisible)
            XCTAssertEqual(content.rootView.names[viewerID], users[1].name)
            XCTAssertEqual(content.rootView.pointers.first?.id, viewerID)
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertTrue(panel.ignoresMouseEvents)
            try await send(2, x: 0.8, y: 0.2)
            try await waitFor { host.remotePointers.first?.x == 0.8 }
            XCTAssertEqual(host.remotePointers.count, 1)
            XCTAssertEqual(content.rootView.pointers.first?.y, 0.2)
            try await send(3, visible: false)
            try await waitFor { host.remotePointers.isEmpty }
            XCTAssertFalse(panel.isVisible)
            try await send(4)
            try await waitFor { !host.remotePointers.isEmpty }
            try await waitFor { host.remotePointers.isEmpty }
            XCTAssertFalse(panel.isVisible, "A silent viewer's stale cursor must expire")

            host.debugStartCursorShare(bounds: CGRect(x: 150, y: 150, width: 400, height: 300), session: "share-two")
            XCTAssertFalse(panel.isVisible)
            let replacement = try XCTUnwrap(host.debugHostCursorPanel)
            XCTAssertFalse(replacement === panel)
            try await send(99, session: "share-one")
            try await send(1, x: 0.5, y: 0.5, session: "share-two")
            try await waitFor { host.remotePointers.first?.x == 0.5 }
            XCTAssertTrue(replacement.isVisible)
            await viewer.disconnect()
            try await waitFor { host.remotePointers.isEmpty }
            XCTAssertFalse(replacement.isVisible)
            await host.disconnect()
            XCTAssertNil(host.debugHostCursorPanel)
        } catch {
            await host.disconnect()
            await viewer.disconnect()
            for client in clients { try? await client.send("v1/rooms/\(response.room.id)/leave", body: EmptyBody()) }
            throw error
        }
        await host.disconnect()
        await viewer.disconnect()
        for client in clients { try? await client.send("v1/rooms/\(response.room.id)/leave", body: EmptyBody()) }
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Host cursor state did not propagate", file: file, line: line)
    }
}

private final class ControlAvailabilityReceiver: RoomDelegate, @unchecked Sendable {
    let expectation: XCTestExpectation
    private let lock = NSLock()
    private var storedMessage: RemoteControlMessage?
    private var fulfilled = false

    init(expectation: XCTestExpectation) { self.expectation = expectation }

    var message: RemoteControlMessage? {
        lock.lock()
        defer { lock.unlock() }
        return storedMessage
    }

    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data,
              forTopic topic: String, encryptionType: EncryptionType) {
        guard topic == "pairdesk.control.v1", let message = try? JSONDecoder().decode(RemoteControlMessage.self, from: data),
              message.kind == .availability, message.reason == RemoteControlUnavailableReason.privacyVeil.rawValue else { return }
        lock.lock()
        storedMessage = message
        let shouldFulfill = !fulfilled
        fulfilled = true
        lock.unlock()
        if shouldFulfill { expectation.fulfill() }
    }
}

private final class AnnotationPacketReceiver: RoomDelegate, @unchecked Sendable {
    let expectation: XCTestExpectation
    private let lock = NSLock()
    private var storedMessage: ScreenAnnotationMessage?
    private var storedSender: String?
    var message: ScreenAnnotationMessage? { lock.lock(); defer { lock.unlock() }; return storedMessage }
    var sender: String? { lock.lock(); defer { lock.unlock() }; return storedSender }
    init(expectation: XCTestExpectation) { self.expectation = expectation }
    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data,
              forTopic topic: String, encryptionType: EncryptionType) {
        guard topic == "pairdesk.annotation.v1", let participant,
              let message = try? JSONDecoder().decode(ScreenAnnotationMessage.self, from: data) else { return }
        lock.lock()
        guard storedMessage == nil else { lock.unlock(); return }
        storedMessage = message
        storedSender = participant.identity?.stringValue
        lock.unlock()
        expectation.fulfill()
    }
}
