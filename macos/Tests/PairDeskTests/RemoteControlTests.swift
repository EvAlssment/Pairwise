import XCTest
@testable import PairDesk

final class RemoteControlTests: XCTestCase {
    func testOnlyGrantedIdentityWithCurrentEpochAndIncreasingSequenceIsAccepted() {
        var gate = RemoteControlGate()
        let now: TimeInterval = 1_000
        gate.grant(identity: "viewer-a", epoch: "epoch-1", now: now)

        XCTAssertFalse(gate.accept(message(epoch: "epoch-1", seq: 1), sender: "viewer-b", now: now))
        XCTAssertFalse(gate.accept(message(epoch: "old-epoch", seq: 1), sender: "viewer-a", now: now))
        XCTAssertTrue(gate.accept(message(epoch: "epoch-1", seq: 1), sender: "viewer-a", now: now))
        XCTAssertFalse(gate.accept(message(epoch: "epoch-1", seq: 1), sender: "viewer-a", now: now))
        XCTAssertTrue(gate.accept(message(epoch: "epoch-1", seq: 2), sender: "viewer-a", now: now))
    }

    func testPointerMotionHasItsOwnSequenceAndStaleSamplesAreDropped() {
        var gate = RemoteControlGate()
        let now: TimeInterval = 1_000
        gate.grant(identity: "viewer-a", epoch: "epoch-1", now: now)

        XCTAssertTrue(gate.accept(message(epoch: "epoch-1", seq: 5), sender: "viewer-a", now: now))
        // A lossy sample overtakes the click sent before it.
        XCTAssertTrue(gate.accept(message(epoch: "epoch-1", seq: 7), sender: "viewer-a", now: now))
        XCTAssertTrue(gate.accept(message(epoch: "epoch-1", seq: 6, kind: .button), sender: "viewer-a", now: now),
                      "a pointer sample must not block the reliable click behind it")
        // Samples sent before the click arrive late: stale, dropped.
        XCTAssertFalse(gate.accept(message(epoch: "epoch-1", seq: 4), sender: "viewer-a", now: now))
        XCTAssertFalse(gate.accept(message(epoch: "epoch-1", seq: 6), sender: "viewer-a", now: now))
        XCTAssertTrue(gate.accept(message(epoch: "epoch-1", seq: 8), sender: "viewer-a", now: now))
        // Reliable messages are compared only with reliable messages.
        XCTAssertTrue(gate.accept(message(epoch: "epoch-1", seq: 7, kind: .key), sender: "viewer-a", now: now))
        XCTAssertFalse(gate.accept(message(epoch: "epoch-1", seq: 7, kind: .key), sender: "viewer-a", now: now))
        XCTAssertEqual(gate.lastSequence, 7)
        XCTAssertEqual(gate.lastPointerSequence, 8)

        gate.revoke()
        XCTAssertEqual(gate.lastPointerSequence, 0)
    }

    func testOlderViewersSendingPointerMotionInOrderStillPass() {
        var gate = RemoteControlGate()
        let now: TimeInterval = 1_000
        gate.grant(identity: "viewer-a", epoch: "epoch-1", now: now)
        XCTAssertTrue(gate.accept(message(epoch: "epoch-1", seq: 1), sender: "viewer-a", now: now))
        XCTAssertTrue(gate.accept(message(epoch: "epoch-1", seq: 2, kind: .key), sender: "viewer-a", now: now))
        XCTAssertTrue(gate.accept(message(epoch: "epoch-1", seq: 3), sender: "viewer-a", now: now))
        XCTAssertTrue(gate.accept(message(epoch: "epoch-1", seq: 4, kind: .button), sender: "viewer-a", now: now))
        XCTAssertTrue(gate.accept(message(epoch: "epoch-1", seq: 5, kind: .scroll), sender: "viewer-a", now: now))
    }

    func testHeartbeatRenewsLeaseButCannotExtendBeyondTwoSeconds() {
        var gate = RemoteControlGate()
        let now: TimeInterval = 1_000
        gate.grant(identity: "viewer-a", epoch: "epoch-1", now: now)
        var heartbeat = message(epoch: "epoch-1", seq: 1, kind: .heartbeat)
        heartbeat.leaseMilliseconds = 60_000

        XCTAssertTrue(gate.accept(heartbeat, sender: "viewer-a", now: now + 1))
        XCTAssertEqual(gate.expiresAtUptime, 1_003)
        XCTAssertFalse(gate.accept(message(epoch: "epoch-1", seq: 2), sender: "viewer-a", now: now + 3))
    }

    func testRevokeMakesQueuedMessagesInert() {
        var gate = RemoteControlGate()
        gate.grant(identity: "viewer-a", epoch: "epoch-1")
        gate.revoke()
        XCTAssertFalse(gate.accept(message(epoch: "epoch-1", seq: 1), sender: "viewer-a"))
        XCTAssertNil(gate.driverIdentity)
    }

    func testArbiterGrantsOneDriverAndQueuesTheNextInArrivalOrder() {
        var arbiter = RemoteControlArbiter()
        arbiter.enable()

        XCTAssertEqual(arbiter.request(identity: "viewer-a"), .grant)
        XCTAssertEqual(arbiter.request(identity: "viewer-b"), .queued)
        XCTAssertEqual(arbiter.request(identity: "viewer-a"), .ignored)
        XCTAssertEqual(arbiter.driverIdentity, "viewer-a")

        XCTAssertEqual(arbiter.release(identity: "viewer-a"), "viewer-b")
        XCTAssertEqual(arbiter.driverIdentity, "viewer-b")
        XCTAssertNil(arbiter.release(identity: "viewer-b"))
        XCTAssertNil(arbiter.driverIdentity)
    }

    func testPausingAutomaticControlDropsDriverAndWaitingRequests() {
        var arbiter = RemoteControlArbiter()
        arbiter.enable()
        XCTAssertEqual(arbiter.request(identity: "viewer-a"), .grant)
        XCTAssertEqual(arbiter.request(identity: "viewer-b"), .queued)

        arbiter.disable()

        XCTAssertFalse(arbiter.isEnabled)
        XCTAssertNil(arbiter.driverIdentity)
        XCTAssertTrue(arbiter.waiting.isEmpty)
        XCTAssertEqual(arbiter.request(identity: "viewer-c"), .ignored)
    }

    func testIdleLeaseDoesNotExpireWhileAKeyOrButtonIsHeld() {
        XCTAssertFalse(RemoteControlLeasePolicy.canExpireIdleLease(heldKeyCount: 1, heldButtonCount: 0))
        XCTAssertFalse(RemoteControlLeasePolicy.canExpireIdleLease(heldKeyCount: 0, heldButtonCount: 1))
        XCTAssertTrue(RemoteControlLeasePolicy.canExpireIdleLease(heldKeyCount: 0, heldButtonCount: 0))
    }

    func testNormalizedPointerUsesSelectedDisplayOrigin() {
        let displayBounds = CGRect(x: -1_440, y: 120, width: 1_440, height: 900)
        XCTAssertEqual(RemoteInputInjector.point(x: 0.5, y: 0.25, in: displayBounds), CGPoint(x: -720, y: 345))
        XCTAssertEqual(RemoteInputInjector.point(x: 1, y: 1, in: displayBounds), CGPoint(x: 0, y: 1_020))
    }

    func testNormalizedPointerRejectsInvalidCoordinatesAndEmptyDisplays() {
        let bounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        XCTAssertNil(RemoteInputInjector.point(x: .nan, y: 0.5, in: bounds))
        XCTAssertNil(RemoteInputInjector.point(x: 1.01, y: 0.5, in: bounds))
        XCTAssertNil(RemoteInputInjector.point(x: 0.5, y: 0.5, in: .zero))
    }

    func testAvailabilityMessageRoundTripsAndUnknownKindsAreIgnored() throws {
        let sent = RemoteControlMessage(epoch: "", sequence: 7, kind: .availability, available: false,
                                        reason: RemoteControlUnavailableReason.accessibility.rawValue)
        let received = try JSONDecoder().decode(RemoteControlMessage.self, from: JSONEncoder().encode(sent))
        XCTAssertEqual(received, sent)
        XCTAssertEqual(received.reason.flatMap(RemoteControlUnavailableReason.init(rawValue:)), .accessibility)
        // Older builds drop kinds they don't know instead of failing the call.
        let future = Data(#"{"version":1,"epoch":"","sequence":1,"kind":"something-newer"}"#.utf8)
        XCTAssertNil(try? JSONDecoder().decode(RemoteControlMessage.self, from: future))
    }

    func testAvailabilityReportsTheFirstBlockingCondition() {
        let window = RemoteControlAvailability.evaluate(sharingWindow: true, accessibilityTrusted: true, automaticControlEnabled: true)
        XCTAssertFalse(window.available); XCTAssertEqual(window.reason, .windowShare)
        let untrusted = RemoteControlAvailability.evaluate(sharingWindow: false, accessibilityTrusted: false, automaticControlEnabled: true)
        XCTAssertFalse(untrusted.available); XCTAssertEqual(untrusted.reason, .accessibility)
        let paused = RemoteControlAvailability.evaluate(sharingWindow: false, accessibilityTrusted: true, automaticControlEnabled: false)
        XCTAssertFalse(paused.available); XCTAssertEqual(paused.reason, .paused)
        let veiled = RemoteControlAvailability.evaluate(sharingWindow: false, accessibilityTrusted: true,
                                                       automaticControlEnabled: true, privacyVeilEnabled: true)
        XCTAssertFalse(veiled.available); XCTAssertEqual(veiled.reason, .privacyVeil)
        let ready = RemoteControlAvailability.evaluate(sharingWindow: false, accessibilityTrusted: true, automaticControlEnabled: true)
        XCTAssertTrue(ready.available); XCTAssertNil(ready.reason)
    }

    private func message(epoch: String, seq: UInt64, kind: RemoteControlMessage.Kind = .pointer) -> RemoteControlMessage {
        RemoteControlMessage(epoch: epoch, sequence: seq, kind: kind, x: 0.5, y: 0.5)
    }

    func testIndependentHoverDoesNotDriveTheOSCursorButDragDoes() {
        XCTAssertFalse(IndependentCursorPolicy.movesSystemCursor(independent: true, heldButtonCount: 0))
        XCTAssertTrue(IndependentCursorPolicy.movesSystemCursor(independent: true, heldButtonCount: 1))
        XCTAssertTrue(IndependentCursorPolicy.movesSystemCursor(independent: false, heldButtonCount: 0))
    }

    func testCursorPresenceRequiresCurrentShareAuthenticatedSenderAndNewSequence() {
        let cursor = RemoteControlMessage(epoch: "share-2", sequence: 4, kind: .cursor, x: 0.4, y: 0.7, visible: true)
        XCTAssertTrue(IndependentCursorPolicy.accepts(cursor, session: "share-2", isParticipant: true, lastSequence: 3))
        XCTAssertFalse(IndependentCursorPolicy.accepts(cursor, session: "share-1", isParticipant: true, lastSequence: 3))
        XCTAssertFalse(IndependentCursorPolicy.accepts(cursor, session: "share-2", isParticipant: false, lastSequence: 3))
        XCTAssertFalse(IndependentCursorPolicy.accepts(cursor, session: "share-2", isParticipant: true, lastSequence: 4))
        XCTAssertFalse(IndependentCursorPolicy.accepts(cursor, session: nil, isParticipant: true, lastSequence: nil))
    }

    func testCursorPresenceRejectsInvalidPointsAndAcceptsExplicitLeave() {
        var cursor = RemoteControlMessage(epoch: "share", sequence: 2, kind: .cursor, x: .nan, y: 0.7)
        XCTAssertFalse(IndependentCursorPolicy.accepts(cursor, session: "share", isParticipant: true, lastSequence: 1))
        cursor.x = 1.1
        XCTAssertFalse(IndependentCursorPolicy.accepts(cursor, session: "share", isParticipant: true, lastSequence: 1))
        cursor.visible = false; cursor.x = nil; cursor.y = nil
        XCTAssertTrue(IndependentCursorPolicy.accepts(cursor, session: "share", isParticipant: true, lastSequence: 1))
    }

    func testCursorBroadcastRequiresSharerAndAuthenticOtherParticipant() {
        let broadcast = RemoteControlMessage(epoch: "share-2", sequence: 8, kind: .cursorBroadcast,
                                             x: 0.4, y: 0.7, pointerIdentity: "viewer-a", visible: true)
        XCTAssertTrue(IndependentCursorPolicy.acceptsBroadcast(broadcast, session: "share-2", senderIsSharer: true,
                                                               pointerIsParticipant: true, viewerIdentity: "viewer-b", lastSequence: 7))
        XCTAssertFalse(IndependentCursorPolicy.acceptsBroadcast(broadcast, session: "share-2", senderIsSharer: false,
                                                                pointerIsParticipant: true, viewerIdentity: "viewer-b", lastSequence: 7))
        XCTAssertFalse(IndependentCursorPolicy.acceptsBroadcast(broadcast, session: "share-2", senderIsSharer: true,
                                                                pointerIsParticipant: false, viewerIdentity: "viewer-b", lastSequence: 7))
        XCTAssertFalse(IndependentCursorPolicy.acceptsBroadcast(broadcast, session: "share-2", senderIsSharer: true,
                                                                pointerIsParticipant: true, viewerIdentity: "viewer-a", lastSequence: 7))
        XCTAssertFalse(IndependentCursorPolicy.acceptsBroadcast(broadcast, session: "old-share", senderIsSharer: true,
                                                                pointerIsParticipant: true, viewerIdentity: "viewer-b", lastSequence: 7))
    }

    func testCursorBroadcastCanExplicitlyHidePointer() {
        let broadcast = RemoteControlMessage(epoch: "share", sequence: 3, kind: .cursorBroadcast,
                                             pointerIdentity: "viewer-a", visible: false)
        XCTAssertTrue(IndependentCursorPolicy.acceptsBroadcast(broadcast, session: "share", senderIsSharer: true,
                                                               pointerIsParticipant: true, viewerIdentity: "viewer-b", lastSequence: 2))
    }

    func testOwnerActivityTemporarilyBlocksInputWithoutBecomingPermissionFailure() {
        let state = RemoteControlAvailability.evaluate(sharingWindow: false, accessibilityTrusted: true,
                                                       automaticControlEnabled: true, ownerActive: true)
        XCTAssertFalse(state.available); XCTAssertEqual(state.reason, .ownerActive)
        let ready = RemoteControlAvailability.evaluate(sharingWindow: false, accessibilityTrusted: true,
                                                       automaticControlEnabled: true, ownerActive: false)
        XCTAssertTrue(ready.available)
    }
}
