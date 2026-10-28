import Foundation
import XCTest
import CoreVideo
import CoreText
import Darwin
import Vision
@preconcurrency import LiveKit
@testable import PairDesk

final class CallIntegrationTests: XCTestCase {
    @MainActor
    func testOneToOneSyntheticScreenQualityProfile() async throws {
        guard let address = ProcessInfo.processInfo.environment["PAIRDESK_TEST_API"],
              let password = ProcessInfo.processInfo.environment["PAIRDESK_TEST_PASSWORD"] else {
            throw XCTSkip("Run scripts/test-call.sh for isolated LiveKit integration")
        }
        struct LoginBody: Encodable { let email: String; let password: String }
        struct RoomBody: Encodable { let name: String }
        struct ShareBody: Encodable { let enabled: Bool }
        let unsigned = try APIClient(server: address)
        var clients: [APIClient] = []
        for index in 1...2 {
            let result: LoginResponse = try await unsigned.post("v1/login", body: LoginBody(
                email: "integration-\(index)@pairdesk.invalid", password: password))
            clients.append(try APIClient(server: address, token: result.token))
        }
        let created: RoomResponse = try await clients[0].post("v1/rooms", body: RoomBody(name: "Synthetic 1:1 benchmark"))
        let roomID = created.room.id
        var media: [Room] = []
        var frameTask: Task<Void, Never>?
        defer { frameTask?.cancel() }
        do {
            for index in 0..<2 {
                // Only participants who already joined have a room reservation
                // to refresh. Heartbeating a future participant is rejected.
                for client in clients.prefix(index) {
                    try await client.send("v1/rooms/\(roomID)/heartbeat", body: EmptyBody())
                }
                let join: JoinResponse = try await clients[index].post("v1/rooms/\(roomID)/join", body: EmptyBody())
                let room = Room(roomOptions: RoomOptions(reportRemoteTrackStatistics: true))
                media.append(room)
                let relayOnly = ProcessInfo.processInfo.environment["PAIRDESK_TEST_RELAY_ONLY"] == "1"
                try await room.connect(url: join.url, token: join.token,
                    connectOptions: ConnectOptions(iceTransportPolicy: relayOnly ? .relay : .all))
                XCTAssertEqual(room.connectionState, .connected)
            }
            try await clients[0].send("v1/rooms/\(roomID)/share", body: ShareBody(enabled: true))
            try await Task.sleep(for: .milliseconds(500))
            try await activateNetworkConditionerIfNeeded()

            let receiver = SyntheticVideoReceiver(expectation: expectation(description: "1:1 synthetic screen frame delivered"))
            media[1].add(delegate: receiver)
            let track = await LocalVideoTrack.createBufferTrack(name: "pairdesk.screen.1to1",
                source: .screenShareVideo, options: BufferCaptureOptions(dimensions: .h1080_169, fps: 30))
            let capturer = try XCTUnwrap(track.capturer as? BufferCapturer)
            let frames = try (0..<6).map {
                try syntheticPixelBuffer(width: 1_920, height: 1_080, phase: $0 * 29, includeTextPattern: true)
            }
            capturer.capture(try XCTUnwrap(frames.first))
            frameTask = Task {
                var frame = 1
                while !Task.isCancelled {
                    capturer.capture(frames[frame % frames.count])
                    frame += 1
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
            let publication = try await media[0].localParticipant.publish(videoTrack: track,
                options: VideoPublishOptions(screenShareEncoding: VideoEncoding(maxBitrate: 5_000_000, maxFps: 30),
                                             simulcast: false))
            await fulfillment(of: [receiver.expectation], timeout: 15)
            let measurementStartedAt = ProcessInfo.processInfo.systemUptime
            let processCPUStart = ProcessCPUProbe.capture()
            try await Task.sleep(for: .seconds(6))
            let measurementWindowSeconds = ProcessInfo.processInfo.systemUptime - measurementStartedAt
            let metrics = try XCTUnwrap(receiver.snapshot(), "1:1 profile must receive measurable frames")
            let processCPUPercent = ProcessCPUProbe.capture().percent(since: processCPUStart)
            frameTask?.cancel()
            await frameTask?.value
            frameTask = nil

            receiver.markRecoveryStart()
            try await Task.sleep(for: .milliseconds(500))
            capturer.capture(try XCTUnwrap(frames.first))
            frameTask = Task {
                var frame = 1
                while !Task.isCancelled {
                    capturer.capture(frames[frame % frames.count])
                    frame += 1
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
            try await receiver.waitForRecovery(timeout: 10)
            let readability = try XCTUnwrap(SyntheticReadabilityMetrics.measure(metrics.firstFrame),
                                            "synthetic decoded frame should support OCR measurement")
            XCTAssertGreaterThan(readability.recognizedLines, 0, "text-pattern measurement should recognize at least one line")
            try writeSyntheticBenchmark(metrics, recoveryMilliseconds: receiver.recoveryMilliseconds,
                                        processCPUPercent: processCPUPercent, readability: readability,
                                        participantCount: media.count,
                                        measurementWindowSeconds: measurementWindowSeconds)
            frameTask?.cancel()
            await frameTask?.value
            frameTask = nil
            try await media[0].localParticipant.unpublish(publication: publication)
        } catch {
            for room in media { await room.disconnect() }
            for client in clients { try? await client.send("v1/rooms/\(roomID)/leave", body: EmptyBody()) }
            throw error
        }
        for room in media { await room.disconnect() }
        for client in clients { try? await client.send("v1/rooms/\(roomID)/leave", body: EmptyBody()) }
    }

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
                let room = Room(delegate: i == 1 ? receiver : nil,
                                roomOptions: RoomOptions(reportRemoteTrackStatistics: true))
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
            let cursorReceiver = DataReceiver(expectation: expectation(description: "Independent cursor delivered to host"),
                                              topic: "pairdesk.control.v1", accepts: {
                (try? JSONDecoder().decode(RemoteControlMessage.self, from: $0).kind) == .cursor
            })
            let bystanderExpectation = expectation(description: "Host relays cursor to another viewer")
            let bystander = DataReceiver(expectation: bystanderExpectation, topic: "pairdesk.control.v1", accepts: {
                (try? JSONDecoder().decode(RemoteControlMessage.self, from: $0).kind) == .cursorBroadcast
            })
            media[0].add(delegate: cursorReceiver)
            media[2].add(delegate: bystander)
            let hostID = try XCTUnwrap(media[0].localParticipant.identity)
            let viewerID = try XCTUnwrap(media[1].localParticipant.identity).stringValue
            let bystanderID = try XCTUnwrap(media[2].localParticipant.identity)
            // Hover samples are intentionally lossy; a single UDP sample may
            // disappear without indicating a cursor regression. Exercise a
            // short stream and require that at least one latest-state sample
            // reaches the host.
            let cursorSamples = (1...20).map { sequence in
                RemoteControlMessage(epoch: "fixture-share", sequence: UInt64(sequence), kind: .cursor,
                                     x: Double(sequence) / 20, y: 0.75, visible: true)
            }
            for cursor in cursorSamples {
                try await media[1].localParticipant.publish(
                    data: JSONEncoder().encode(cursor),
                    options: DataPublishOptions(destinationIdentities: [hostID], topic: "pairdesk.control.v1", reliable: false)
                )
                if cursorReceiver.received != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            await fulfillment(of: [cursorReceiver.expectation], timeout: 5)
            let receivedCursor = try JSONDecoder().decode(RemoteControlMessage.self, from: XCTUnwrap(cursorReceiver.received))
            XCTAssertTrue(cursorSamples.contains(receivedCursor))
            XCTAssertEqual(cursorReceiver.sender, media[1].localParticipant.identity?.stringValue)
            XCTAssertTrue(IndependentCursorPolicy.accepts(receivedCursor, session: "fixture-share", isParticipant: true, lastSequence: nil))
            let motionExpectation = expectation(description: "Coalesced control motion delivered independently of ordered inputs")
            let motionReceiver = DataReceiver(expectation: motionExpectation, topic: "pairdesk.control.v1", accepts: {
                (try? JSONDecoder().decode(RemoteControlMessage.self, from: $0).kind) == .pointer
            })
            media[0].add(delegate: motionReceiver)
            let motionSamples = (1...20).map { sequence in
                RemoteControlMessage(epoch: "fixture-share", sequence: UInt64(sequence),
                                     kind: .pointer, x: 0.4, y: 0.6)
            }
            for motion in motionSamples {
                try await media[1].localParticipant.publish(
                    data: JSONEncoder().encode(motion),
                    options: DataPublishOptions(destinationIdentities: [hostID], topic: "pairdesk.control.v1", reliable: false)
                )
                if motionReceiver.received != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            await fulfillment(of: [motionExpectation], timeout: 5)
            let receivedMotion = try JSONDecoder().decode(RemoteControlMessage.self, from: XCTUnwrap(motionReceiver.received))
            XCTAssertTrue(motionSamples.contains(receivedMotion))
            let viewerIdentity = try XCTUnwrap(motionReceiver.sender)
            var motionGate = RemoteControlGate()
            motionGate.grant(identity: viewerIdentity, epoch: "fixture-share", now: 1_000)
            XCTAssertTrue(motionGate.accept(receivedMotion, sender: viewerIdentity, now: 1_000.1))
            media[0].remove(delegate: motionReceiver)
            let relayedSamples = (1...20).map { sequence in
                RemoteControlMessage(epoch: "fixture-share", sequence: UInt64(sequence), kind: .cursorBroadcast,
                                     x: 0.25, y: 0.75, pointerIdentity: viewerID, visible: true)
            }
            for relayed in relayedSamples {
                try await media[0].localParticipant.publish(
                    data: JSONEncoder().encode(relayed),
                    options: DataPublishOptions(destinationIdentities: [bystanderID], topic: "pairdesk.control.v1", reliable: false)
                )
                if bystander.received != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            await fulfillment(of: [bystanderExpectation], timeout: 5)
            let receivedRelay = try JSONDecoder().decode(RemoteControlMessage.self, from: XCTUnwrap(bystander.received))
            XCTAssertTrue(relayedSamples.contains(receivedRelay))
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
            try await activateNetworkConditionerIfNeeded()
            let videoReceiver = SyntheticVideoReceiver(expectation: expectation(description: "Synthetic screen frame delivered"))
            media[1].add(delegate: videoReceiver)
            let track = await LocalVideoTrack.createBufferTrack(
                name: "pairdesk.screen.fixture", source: .screenShareVideo,
                options: BufferCaptureOptions(dimensions: .h1080_169, fps: 30))
            let capturer = try XCTUnwrap(track.capturer as? BufferCapturer)
            let screenFrames = try (0..<8).map {
                try syntheticPixelBuffer(width: 1_920, height: 1_080, phase: $0 * 37, includeTextPattern: true)
            }
            capturer.capture(try XCTUnwrap(screenFrames.first))
            frameTask = Task {
                var phase = 1
                while !Task.isCancelled {
                    capturer.capture(screenFrames[phase % screenFrames.count])
                    phase += 1
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
            let publication = try await media[0].localParticipant.publish(
                videoTrack: track,
                options: VideoPublishOptions(screenShareEncoding: VideoEncoding(maxBitrate: 5_000_000, maxFps: 30),
                                             simulcast: false))
            await fulfillment(of: [videoReceiver.expectation], timeout: 15)
            XCTAssertTrue(videoReceiver.receivedFrame)
            let measurementStartedAt = ProcessInfo.processInfo.systemUptime
            let processCPUStart = ProcessCPUProbe.capture()
            try await Task.sleep(for: .seconds(6))
            let measurementWindowSeconds = ProcessInfo.processInfo.systemUptime - measurementStartedAt
            let videoMetrics = videoReceiver.snapshot()
            let processCPUPercent = ProcessCPUProbe.capture().percent(since: processCPUStart)
            frameTask?.cancel()
            await frameTask?.value
            frameTask = nil
            videoReceiver.markRecoveryStart()
            capturer.capture(try XCTUnwrap(screenFrames.first))
            frameTask = Task {
                var phase = 102
                while !Task.isCancelled {
                    capturer.capture(screenFrames[phase % screenFrames.count])
                    phase += 1
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
            try await videoReceiver.waitForRecovery(timeout: 10)
            let recoveryMilliseconds = videoReceiver.recoveryMilliseconds
            if let metrics = videoMetrics {
                let readability = try XCTUnwrap(SyntheticReadabilityMetrics.measure(metrics.firstFrame),
                                                "synthetic decoded frame should support OCR measurement")
                XCTAssertGreaterThan(readability.recognizedLines, 0,
                                     "text-pattern measurement should recognize at least one line")
                try writeSyntheticBenchmark(metrics, recoveryMilliseconds: recoveryMilliseconds,
                                            processCPUPercent: processCPUPercent, readability: readability,
                                            participantCount: media.count,
                                            measurementWindowSeconds: measurementWindowSeconds)
            }
            frameTask?.cancel()
            await frameTask?.value
            frameTask = nil
            try await media[0].localParticipant.unpublish(publication: publication)
            if ProcessInfo.processInfo.environment["PAIRDESK_SKIP_CAMERA_PUBLICATION_TEST"] != "1" {
                let cameraReceiver = SyntheticVideoReceiver(expectation: expectation(description: "Synthetic camera frame delivered"),
                                                            source: .camera)
                media[1].add(delegate: cameraReceiver)
                let cameraTrack = await LocalVideoTrack.createBufferTrack(name: "pairdesk.camera.fixture", source: .camera)
                let cameraCapturer = try XCTUnwrap(cameraTrack.capturer as? BufferCapturer)
                let cameraPixel = try syntheticPixelBuffer()
                cameraCapturer.capture(cameraPixel)
                frameTask = Task {
                    while !Task.isCancelled {
                        cameraCapturer.capture(cameraPixel)
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
            }
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

    private func syntheticPixelBuffer(width: Int = 640, height: Int = 480, phase: Int = 0,
                                      includeTextPattern: Bool = false) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        XCTAssertEqual(result, kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel))
        let rowBytes = CVPixelBufferGetBytesPerRow(pixel)
        let width = CVPixelBufferGetWidth(pixel)
        let height = CVPixelBufferGetHeight(pixel)
        guard let context = CGContext(data: bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: rowBytes,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                                        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)).rawValue) else {
            throw NSError(domain: "SyntheticVideo", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create synthetic test-pattern context"])
        }
        context.setFillColor(CGColor(gray: includeTextPattern ? 0.04 : 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if includeTextPattern {
            for (index, size) in [12, 16, 20, 24].enumerated() {
                let label = "PAIRWISE \(size)PX SAMPLE 0123456789"
                let font = CTFontCreateWithName("Menlo" as CFString, CGFloat(size), nil)
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.82, alpha: 1),
                ]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
                context.textPosition = CGPoint(x: 48, y: CGFloat(height - 80 - index * 72))
                CTLineDraw(line, context)
            }
        }
        // Keep a moving marker so frame delivery/FPS still uses dynamic content.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let markerSize = 24
        let markerRow = phase % max(1, height - markerSize)
        let markerColumn = (phase * 7) % max(1, width - markerSize)
        context.fill(CGRect(x: markerColumn, y: markerRow, width: markerSize, height: markerSize))
        return pixel
    }
}

private final class SyntheticVideoReceiver: NSObject, RoomDelegate, VideoRenderer, @unchecked Sendable {
    struct Snapshot {
        let width: Int?
        let height: Int?
        let frameCount: Int
        let observedFramesPerSecond: Double?
        let receivedBitrateKilobitsPerSecond: Double?
        let timeToFirstFrameMilliseconds: Double?
        let packetLossPercent: Double?
        let selectedPathRTTMilliseconds: Double?
        let firstFrame: CVPixelBuffer?
    }

    let expectation: XCTestExpectation
    private let source: Track.Source
    private let lock = NSLock()
    private var didReceive = false
    private let measurementStartedAt = ProcessInfo.processInfo.systemUptime
    private var firstFrameAt: TimeInterval?
    private var lastFrameAt: TimeInterval?
    private var measuredFrameCount = 0
    private var measuredWidth: Int?
    private var measuredHeight: Int?
    private var firstFrame: CVPixelBuffer?
    private var remoteVideoTrack: RemoteVideoTrack?
    private var recoveryStartedAt: TimeInterval?
    private var storedRecoveryMilliseconds: Double?
    var receivedFrame: Bool { lock.lock(); defer { lock.unlock() }; return didReceive }
    var recoveryMilliseconds: Double? { lock.lock(); defer { lock.unlock() }; return storedRecoveryMilliseconds }
    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { CGSize(width: 640, height: 480) }
    init(expectation: XCTestExpectation, source: Track.Source = .screenShareVideo) {
        self.expectation = expectation
        self.source = source
    }
    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard let track = publication.track as? RemoteVideoTrack, track.source == source else { return }
        lock.lock()
        remoteVideoTrack = track
        lock.unlock()
        track.add(videoRenderer: self)
    }
    func render(frame: VideoFrame) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if !didReceive {
            didReceive = true
            firstFrameAt = now
        }
        measuredFrameCount += 1
        lastFrameAt = now
        if let recoveryStartedAt, storedRecoveryMilliseconds == nil {
            storedRecoveryMilliseconds = max(0, (now - recoveryStartedAt) * 1_000)
        }
        if measuredWidth == nil {
            measuredWidth = Int(frame.dimensions.width)
            measuredHeight = Int(frame.dimensions.height)
            firstFrame = frame.toCVPixelBuffer()
        }
        let shouldFulfill = measuredFrameCount == 1
        lock.unlock()
        if shouldFulfill { expectation.fulfill() }
    }

    func snapshot() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard measuredFrameCount > 0 else { return nil }
        let elapsed = if let firstFrameAt, let lastFrameAt { lastFrameAt - firstFrameAt } else { 0.0 }
        let fps = elapsed > 0 ? Double(max(0, measuredFrameCount - 1)) / elapsed : nil
        let firstFrameMilliseconds = firstFrameAt.map { max(0, ($0 - measurementStartedAt) * 1_000) }
        let stats = remoteVideoTrack?.statistics
        let videoStats = stats?.inboundRtpStream.first(where: { $0.kind == "video" })
        let received = Double(videoStats?.packetsReceived ?? 0)
        let lost = Double(max(0, videoStats?.packetsLost ?? 0))
        let packetLoss = received + lost > 0 ? lost / (received + lost) * 100 : nil
        let selectedPairID = stats?.transportStats?.selectedCandidatePairId
        let selectedPair = stats?.iceCandidatePair.first(where: { $0.id == selectedPairID })
        let rtt = selectedPair?.currentRoundTripTime.map { $0 * 1_000 }
        let bitrate = videoStats?.bytesReceived.flatMap { bytesReceived -> Double? in
            guard elapsed > 0, bytesReceived > 0 else { return nil }
            return Double(bytesReceived) * 8 / elapsed / 1_000
        }
        return Snapshot(width: measuredWidth, height: measuredHeight, frameCount: measuredFrameCount,
                        observedFramesPerSecond: fps, receivedBitrateKilobitsPerSecond: bitrate,
                        timeToFirstFrameMilliseconds: firstFrameMilliseconds,
                        packetLossPercent: packetLoss, selectedPathRTTMilliseconds: rtt,
                        firstFrame: firstFrame)
    }

    func markRecoveryStart() {
        lock.lock()
        recoveryStartedAt = ProcessInfo.processInfo.systemUptime
        storedRecoveryMilliseconds = nil
        lock.unlock()
    }

    func waitForRecovery(timeout: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if recoveryMilliseconds != nil { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Synthetic video did not recover after sender resumed")
        throw NSError(domain: "SyntheticVideoReceiver", code: 1)
    }
}

private struct SyntheticMediaBenchmark: Encodable {
    let schemaVersion = 6
    let classification: String
    let networkProfile: String
    let configuredNetwork: SyntheticNetworkProfile
    let commit: String?
    let runID: String?
    let generatedAt: String
    let participantCount: Int
    let source: String
    let width: Int?
    let height: Int?
    let observedFramesPerSecond: Double?
    let receivedBitrateKilobitsPerSecond: Double?
    let framesReceived: Int
    let measurementWindowSeconds: Double
    let timeToFirstFrameMilliseconds: Double?
    let syntheticSenderPauseRecoveryMilliseconds: Double?
    let packetLossPercent: Double?
    let selectedPathRTTMilliseconds: Double?
    let harnessProcessCPUPercent: Double?
    let syntheticReadability: SyntheticReadabilityMetrics?
    let runner: BenchmarkRunnerMetadata
    let unmeasured: [String]
}

private struct SyntheticReadabilityMetrics: Encodable {
    let recognizedLines: Int
    let totalLines: Int
    let recognizedTextPercent: Double
    let testedFontSizesPixels: [Int]
    let recognizedFontSizesPixels: [Int]
    let smallestRecognizedFontPixels: Int?
    let measurement: String

    static func measure(_ pixelBuffer: CVPixelBuffer?) -> Self? {
        guard let pixelBuffer else { return nil }
        let sizes = [12, 16, 20, 24]
        let expected = sizes.map { "PAIRWISE \($0)PX SAMPLE 0123456789" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer).perform([request])
        } catch {
            return nil
        }
        let observations = request.results ?? []
        let normalizedObservations = observations.compactMap { observation in
            observation.topCandidates(1).first?.string
                .replacingOccurrences(of: " ", with: "")
                .uppercased()
        }
        let recognizedSizes = zip(sizes, expected).compactMap { size, expectedLine -> Int? in
            let normalized = expectedLine.replacingOccurrences(of: " ", with: "").uppercased()
            return normalizedObservations.contains { $0.contains(normalized) } ? size : nil
        }
        return Self(recognizedLines: recognizedSizes.count, totalLines: expected.count,
                    recognizedTextPercent: Double(recognizedSizes.count) / Double(expected.count) * 100,
                    testedFontSizesPixels: sizes, recognizedFontSizesPixels: recognizedSizes,
                    smallestRecognizedFontPixels: recognizedSizes.min(),
                    measurement: "Vision OCR of a transient synthetic decoded frame; recognized text is not stored")
    }
}

private struct ProcessCPUProbe {
    let wallTime: TimeInterval
    let cpuTime: TimeInterval

    static func capture() -> Self {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return Self(wallTime: ProcessInfo.processInfo.systemUptime, cpuTime: 0)
        }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return Self(wallTime: ProcessInfo.processInfo.systemUptime, cpuTime: user + system)
    }

    func percent(since earlier: Self) -> Double? {
        let elapsed = wallTime - earlier.wallTime
        guard elapsed > 0 else { return nil }
        return max(0, (cpuTime - earlier.cpuTime) / elapsed * 100)
    }
}

private struct SyntheticNetworkProfile: Encodable {
    let outboundBandwidthKbitPerSecond: Int
    let outboundOneWayDelayMilliseconds: Int
    let outboundDelayVariationMilliseconds: [Int]
    let outboundPacketLossProbabilityPercent: Double
}

private func writeSyntheticBenchmark(_ snapshot: SyntheticVideoReceiver.Snapshot,
                                    recoveryMilliseconds: Double?, processCPUPercent: Double?,
                                    readability: SyntheticReadabilityMetrics?,
                                    participantCount: Int,
                                    measurementWindowSeconds: Double) throws {
    guard let path = ProcessInfo.processInfo.environment["PAIRDESK_MEDIA_BENCHMARK_OUTPUT"] else { return }
    let profile = ProcessInfo.processInfo.environment["PAIRDESK_BENCHMARK_PROFILE"] ?? "baseline"
    guard profile == "baseline" || profile == "constrained" else {
        throw NSError(domain: "SyntheticMediaBenchmark", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Unknown network benchmark profile: \(profile)"])
    }
    let isConstrained = profile == "constrained"
    let conditionerActive = ProcessInfo.processInfo.environment["PAIRDESK_NETWORK_CONDITION_ACTIVE_FILE"]
        .map { FileManager.default.fileExists(atPath: $0) } ?? false
    guard !isConstrained || conditionerActive else {
        throw NSError(domain: "SyntheticMediaBenchmark", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Constrained profile requires the active macOS network conditioner"])
    }
    let environment = ProcessInfo.processInfo.environment
    let delaySequence = (environment["PAIRDESK_NETWORK_CONDITION_DELAY_SEQUENCE_MS"] ?? "0")
        .split(separator: ",").compactMap { Int($0) }
    let configuredNetwork = SyntheticNetworkProfile(
        outboundBandwidthKbitPerSecond: Int(environment["PAIRDESK_NETWORK_CONDITION_BANDWIDTH_KBIT"] ?? "0") ?? 0,
        outboundOneWayDelayMilliseconds: isConstrained ? 40 : 0,
        outboundDelayVariationMilliseconds: delaySequence.isEmpty ? [0] : delaySequence,
        outboundPacketLossProbabilityPercent: Double(environment["PAIRDESK_NETWORK_CONDITION_PACKET_LOSS_PERCENT"] ?? "0") ?? 0)
    let formatter = ISO8601DateFormatter()
    let report = SyntheticMediaBenchmark(
        classification: "synthetic-\(profile)-ci", networkProfile: profile,
        configuredNetwork: configuredNetwork,
        commit: ProcessInfo.processInfo.environment["PAIRDESK_BENCHMARK_COMMIT"],
        runID: ProcessInfo.processInfo.environment["PAIRDESK_BENCHMARK_RUN_ID"],
        generatedAt: formatter.string(from: Date()), participantCount: participantCount,
        source: "synthetic-screen-track", width: snapshot.width, height: snapshot.height,
        observedFramesPerSecond: snapshot.observedFramesPerSecond,
        receivedBitrateKilobitsPerSecond: snapshot.receivedBitrateKilobitsPerSecond,
        framesReceived: snapshot.frameCount, measurementWindowSeconds: measurementWindowSeconds,
        timeToFirstFrameMilliseconds: snapshot.timeToFirstFrameMilliseconds,
        syntheticSenderPauseRecoveryMilliseconds: recoveryMilliseconds,
        packetLossPercent: snapshot.packetLossPercent,
        selectedPathRTTMilliseconds: snapshot.selectedPathRTTMilliseconds,
        harnessProcessCPUPercent: processCPUPercent,
        syntheticReadability: readability,
        runner: BenchmarkRunnerMetadata.current(),
        unmeasured: ["pointer_to_render_latency", "sender_cpu", "receiver_cpu", "physical_readability"])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let requestedOutput = URL(fileURLWithPath: path)
    let profileName = "\(requestedOutput.deletingPathExtension().lastPathComponent)-\(profile)-\(participantCount)p.json"
    let output = requestedOutput.deletingLastPathComponent().appendingPathComponent(profileName)
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try encoder.encode(report).write(to: output, options: .atomic)
}

@MainActor
private func activateNetworkConditionerIfNeeded() async throws {
    guard ProcessInfo.processInfo.environment["PAIRDESK_BENCHMARK_PROFILE"] == "constrained" else { return }
    let environment = ProcessInfo.processInfo.environment
    guard let readyPath = environment["PAIRDESK_NETWORK_CONDITION_READY_FILE"],
          let activePath = environment["PAIRDESK_NETWORK_CONDITION_ACTIVE_FILE"] else {
        throw NSError(domain: "SyntheticMediaBenchmark", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "Constrained profile is missing its activation handshake"])
    }
    if FileManager.default.fileExists(atPath: activePath) { return }
    guard FileManager.default.createFile(atPath: readyPath, contents: Data()) else {
        throw NSError(domain: "SyntheticMediaBenchmark", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "Could not request network conditioning"])
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 120
    while ProcessInfo.processInfo.systemUptime < deadline {
        if FileManager.default.fileExists(atPath: activePath) { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw NSError(domain: "SyntheticMediaBenchmark", code: 6,
                  userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for network conditioning to become active"])
}

private final class DataReceiver: RoomDelegate, @unchecked Sendable {
    let expectation: XCTestExpectation
    private let topic: String
    private let accepts: (Data) -> Bool
    private let lock = NSLock()
    private var storedData: Data?
    private var storedSender: String?
    var received: Data? { lock.lock(); defer { lock.unlock() }; return storedData }
    var sender: String? { lock.lock(); defer { lock.unlock() }; return storedSender }
    init(expectation: XCTestExpectation, topic: String = "pairdesk.test", accepts: @escaping (Data) -> Bool = { _ in true }) {
        self.expectation = expectation
        self.topic = topic
        self.accepts = accepts
    }
    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        guard topic == self.topic, let participant, accepts(data) else { return }
        lock.lock()
        guard storedData == nil else { lock.unlock(); return }
        storedData = data
        storedSender = participant.identity?.stringValue
        lock.unlock()
        expectation.fulfill()
    }
}
