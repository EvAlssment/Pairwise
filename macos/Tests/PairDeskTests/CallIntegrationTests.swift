import Foundation
import XCTest
import CoreVideo
@preconcurrency import LiveKit
@testable import PairDesk

final class CallIntegrationTests: XCTestCase {
    @MainActor
    func testFourNativeClientsCameraPublicationAndExclusiveScreenPermission() async throws {
        guard let address = ProcessInfo.processInfo.environment["PAIRDESK_TEST_API"],
              let password = ProcessInfo.processInfo.environment["PAIRDESK_TEST_PASSWORD"] else {
            throw XCTSkip("Run scripts/test-call.sh for isolated LiveKit integration")
        }
        struct LoginBody: Encodable { let email: String; let password: String }
        struct RoomBody: Encodable { let name: String }
        struct ShareBody: Encodable { let enabled: Bool }
        let unsigned = try APIClient(server: address)
        var clients: [APIClient] = []
        for i in 1...5 {
            let result: LoginResponse = try await unsigned.post("v1/login", body: LoginBody(email: "integration-\(i)@pairdesk.invalid", password: password))
            clients.append(try APIClient(server: address, token: result.token))
        }
        let response: RoomResponse = try await clients[0].post("v1/rooms", body: RoomBody(name: "Native integration fixture"))
        let roomID = response.room.id
        var media: [Room] = []
        var frameTask: Task<Void, Never>?
        defer { frameTask?.cancel() }
        let receiver = DataReceiver(expectation: expectation(description: "Authenticated RTC data delivered"))
        do {
            for i in 0..<4 {
                for client in clients.prefix(i) { try await client.send("v1/rooms/\(roomID)/heartbeat", body: EmptyBody()) }
                let join: JoinResponse = try await clients[i].post("v1/rooms/\(roomID)/join", body: EmptyBody())
                let room = Room(delegate: i == 1 ? receiver : nil)
                media.append(room)
                let relayOnly = ProcessInfo.processInfo.environment["PAIRDESK_TEST_RELAY_ONLY"] == "1"
                try await room.connect(url: join.url, token: join.token, connectOptions: ConnectOptions(iceTransportPolicy: relayOnly ? .relay : .all))
                XCTAssertEqual(room.connectionState, .connected)
                XCTAssertEqual(room.localParticipant.identity?.stringValue, join.participantIdentity)
                XCTAssertFalse(room.localParticipant.isCameraEnabled(), "Joining a call must not activate the camera")
                XCTAssertTrue(room.localParticipant.permissions.canPublishSources.contains(Track.Source.camera.rawValue))
                XCTAssertFalse(room.localParticipant.permissions.canPublishSources.contains(Track.Source.screenShareVideo.rawValue))
            }
            for client in clients.prefix(4) { try await client.send("v1/rooms/\(roomID)/heartbeat", body: EmptyBody()) }
            for _ in 0..<100 {
                if media[0].remoteParticipants.count == 3 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(media[0].remoteParticipants.count, 3)
            let payload = Data("pairdesk-integration".utf8)
            try await media[0].localParticipant.publish(data: payload, options: DataPublishOptions(topic: "pairdesk.test", reliable: true))
            await fulfillment(of: [receiver.expectation], timeout: 10)
            XCTAssertEqual(receiver.received, payload)
            XCTAssertEqual(receiver.sender, media[0].localParticipant.identity?.stringValue)
            let hostIdentity = try XCTUnwrap(media[0].localParticipant.identity)
            let clipboardExpectation = expectation(description: "Text clipboard message delivered to intended Mac")
            let clipboardReceiver = DataReceiver(expectation: clipboardExpectation, topic: "pairdesk.clipboard.v1")
            media[0].add(delegate: clipboardReceiver)
            let clipboard = try ClipboardTransferMessage(recipientIdentity: hostIdentity.stringValue,
                                                         text: "clipboard integration · 你好")
            try await media[1].localParticipant.publish(
                data: clipboard.encoded(),
                options: DataPublishOptions(destinationIdentities: [hostIdentity],
                                            topic: "pairdesk.clipboard.v1", reliable: true)
            )
            await fulfillment(of: [clipboardExpectation], timeout: 10)
            XCTAssertEqual(clipboardReceiver.sender, media[1].localParticipant.identity?.stringValue)
            XCTAssertEqual(try ClipboardTransferMessage.decode(try XCTUnwrap(clipboardReceiver.received),
                                                               authenticatedSender: try XCTUnwrap(clipboardReceiver.sender),
                                                               localIdentity: hostIdentity.stringValue), clipboard)
            media[0].remove(delegate: clipboardReceiver)
            // Independent hover uses an authenticated, lossy packet addressed
            // only to the sharing Mac, without any control lease.
            let cursorReceiver = DataReceiver(expectation: expectation(description: "Independent cursor delivered to host"), topic: "pairdesk.control.v1")
            let bystanderExpectation = expectation(description: "Host relays cursor to another viewer")
            let bystander = DataReceiver(expectation: bystanderExpectation, topic: "pairdesk.control.v1")
            media[0].add(delegate: cursorReceiver)
            media[2].add(delegate: bystander)
            let hostID = try XCTUnwrap(media[0].localParticipant.identity)
            let viewerID = try XCTUnwrap(media[1].localParticipant.identity).stringValue
            let bystanderID = try XCTUnwrap(media[2].localParticipant.identity)
            let cursor = RemoteControlMessage(epoch: "fixture-share", sequence: 1, kind: .cursor, x: 0.25, y: 0.75, visible: true)
            try await media[1].localParticipant.publish(data: JSONEncoder().encode(cursor), options: DataPublishOptions(destinationIdentities: [hostID], topic: "pairdesk.control.v1", reliable: false))
            await fulfillment(of: [cursorReceiver.expectation], timeout: 5)
            let receivedCursor = try JSONDecoder().decode(RemoteControlMessage.self, from: XCTUnwrap(cursorReceiver.received))
            XCTAssertEqual(receivedCursor, cursor)
            XCTAssertEqual(cursorReceiver.sender, media[1].localParticipant.identity?.stringValue)
            XCTAssertTrue(IndependentCursorPolicy.accepts(receivedCursor, session: "fixture-share", isParticipant: true, lastSequence: nil))
            let motionExpectation = expectation(description: "Coalesced control motion delivered independently of ordered inputs")
            let motionReceiver = DataReceiver(expectation: motionExpectation, topic: "pairdesk.control.v1")
            media[0].add(delegate: motionReceiver)
            let motion = RemoteControlMessage(epoch: "fixture-share", sequence: 1,
                                              kind: .pointer, x: 0.4, y: 0.6)
            try await media[1].localParticipant.publish(data: JSONEncoder().encode(motion),
                                                        options: DataPublishOptions(destinationIdentities: [hostID],
                                                                                    topic: "pairdesk.control.v1", reliable: false))
            await fulfillment(of: [motionExpectation], timeout: 5)
            let receivedMotion = try JSONDecoder().decode(RemoteControlMessage.self, from: XCTUnwrap(motionReceiver.received))
            XCTAssertEqual(receivedMotion, motion)
            let viewerIdentity = try XCTUnwrap(motionReceiver.sender)
            var motionGate = RemoteControlGate()
            motionGate.grant(identity: viewerIdentity, epoch: "fixture-share", now: 1_000)
            XCTAssertTrue(motionGate.accept(receivedMotion, sender: viewerIdentity, now: 1_000.1))
            media[0].remove(delegate: motionReceiver)
            let relayed = RemoteControlMessage(epoch: "fixture-share", sequence: 2, kind: .cursorBroadcast,
                                               x: 0.25, y: 0.75, pointerIdentity: viewerID, visible: true)
            try await media[0].localParticipant.publish(data: JSONEncoder().encode(relayed), options: DataPublishOptions(destinationIdentities: [bystanderID], topic: "pairdesk.control.v1", reliable: false))
            await fulfillment(of: [bystanderExpectation], timeout: 5)
            let receivedRelay = try JSONDecoder().decode(RemoteControlMessage.self, from: XCTUnwrap(bystander.received))
            XCTAssertEqual(receivedRelay, relayed)
            XCTAssertEqual(bystander.sender, media[0].localParticipant.identity?.stringValue)
            XCTAssertTrue(IndependentCursorPolicy.acceptsBroadcast(receivedRelay, session: "fixture-share", senderIsSharer: true,
                                                                   pointerIsParticipant: true, viewerIdentity: bystanderID.stringValue, lastSequence: nil))
            media[0].remove(delegate: cursorReceiver)
            media[2].remove(delegate: bystander)
            do {
                let _: JoinResponse = try await clients[4].post("v1/rooms/\(roomID)/join", body: EmptyBody())
                XCTFail("A fifth member was admitted")
            } catch let error as APIError { XCTAssertEqual(error.status, 409) }
            try await clients[0].send("v1/rooms/\(roomID)/share", body: ShareBody(enabled: true))
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(media[0].localParticipant.permissions.canPublishSources.contains(Track.Source.screenShareVideo.rawValue))
            XCTAssertTrue(media[0].localParticipant.permissions.canPublishSources.contains(Track.Source.camera.rawValue))
            XCTAssertFalse(media[0].localParticipant.permissions.canPublishSources.contains(Track.Source.screenShareAudio.rawValue))
            let videoReceiver = SyntheticVideoReceiver(expectation: expectation(description: "Synthetic screen frame delivered"))
            media[1].add(delegate: videoReceiver)
            let track = await LocalVideoTrack.createBufferTrack(name: "pairdesk.screen.fixture", source: .screenShareVideo)
            let capturer = try XCTUnwrap(track.capturer as? BufferCapturer)
            let pixel = try syntheticPixelBuffer()
            capturer.capture(pixel)
            frameTask = Task {
                while !Task.isCancelled {
                    capturer.capture(pixel)
                    try? await Task.sleep(for: .milliseconds(66))
                }
            }
            let publication = try await media[0].localParticipant.publish(videoTrack: track, options: VideoPublishOptions(simulcast: false))
            await fulfillment(of: [videoReceiver.expectation], timeout: 15)
            XCTAssertTrue(videoReceiver.receivedFrame)
            frameTask?.cancel()
            frameTask = nil
            try await media[0].localParticipant.unpublish(publication: publication)
            let cameraReceiver = SyntheticVideoReceiver(expectation: expectation(description: "Synthetic camera frame delivered"),
                                                        source: .camera)
            media[1].add(delegate: cameraReceiver)
            let cameraTrack = await LocalVideoTrack.createBufferTrack(name: "pairdesk.camera.fixture", source: .camera)
            let cameraCapturer = try XCTUnwrap(cameraTrack.capturer as? BufferCapturer)
            cameraCapturer.capture(pixel)
            frameTask = Task {
                while !Task.isCancelled {
                    cameraCapturer.capture(pixel)
                    try? await Task.sleep(for: .milliseconds(66))
                }
            }
            let cameraPublication = try await media[0].localParticipant.publish(videoTrack: cameraTrack,
                                                                                 options: VideoPublishOptions(name: "pairdesk.camera.fixture", simulcast: false))
            await fulfillment(of: [cameraReceiver.expectation], timeout: 15)
            XCTAssertTrue(cameraReceiver.receivedFrame)
            frameTask?.cancel()
            frameTask = nil
            try await media[0].localParticipant.unpublish(publication: cameraPublication)
            media[1].remove(delegate: cameraReceiver)
            do {
                try await clients[1].send("v1/rooms/\(roomID)/share", body: ShareBody(enabled: true))
                XCTFail("A second sharer was admitted")
            } catch let error as APIError { XCTAssertEqual(error.status, 409) }
            try await clients[0].send("v1/rooms/\(roomID)/share", body: ShareBody(enabled: false))
            try await clients[1].send("v1/rooms/\(roomID)/share", body: ShareBody(enabled: true))
            try await clients[1].send("v1/rooms/\(roomID)/share", body: ShareBody(enabled: false))
        } catch {
            for room in media { await room.disconnect() }
            for client in clients { try? await client.send("v1/rooms/\(roomID)/leave", body: EmptyBody()) }
            throw error
        }
        for room in media { await room.disconnect() }
        for client in clients { try? await client.send("v1/rooms/\(roomID)/leave", body: EmptyBody()) }
    }

    private func syntheticPixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        XCTAssertEqual(result, kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel))
        memset(bytes, 128, CVPixelBufferGetBytesPerRow(pixel) * CVPixelBufferGetHeight(pixel))
        return pixel
    }
}

private final class SyntheticVideoReceiver: NSObject, RoomDelegate, VideoRenderer, @unchecked Sendable {
    let expectation: XCTestExpectation
    private let source: Track.Source
    private let lock = NSLock()
    private var didReceive = false
    var receivedFrame: Bool { lock.lock(); defer { lock.unlock() }; return didReceive }
    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { CGSize(width: 640, height: 480) }
    init(expectation: XCTestExpectation, source: Track.Source = .screenShareVideo) {
        self.expectation = expectation
        self.source = source
    }
    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard let track = publication.track as? RemoteVideoTrack, track.source == source else { return }
        track.add(videoRenderer: self)
    }
    func render(frame: VideoFrame) {
        lock.lock()
        guard !didReceive else { lock.unlock(); return }
        didReceive = true
        lock.unlock()
        expectation.fulfill()
    }
}

private final class DataReceiver: RoomDelegate, @unchecked Sendable {
    let expectation: XCTestExpectation
    private let topic: String
    private let lock = NSLock()
    private var storedData: Data?
    private var storedSender: String?
    var received: Data? { lock.lock(); defer { lock.unlock() }; return storedData }
    var sender: String? { lock.lock(); defer { lock.unlock() }; return storedSender }
    init(expectation: XCTestExpectation, topic: String = "pairdesk.test") { self.expectation = expectation; self.topic = topic }
    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        guard topic == self.topic, let participant else { return }
        lock.lock()
        guard storedData == nil else { lock.unlock(); return }
        storedData = data
        storedSender = participant.identity?.stringValue
        lock.unlock()
        expectation.fulfill()
    }
}
