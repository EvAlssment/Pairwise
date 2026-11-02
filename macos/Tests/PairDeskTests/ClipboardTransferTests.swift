import AppKit
import XCTest
@testable import PairDesk

final class ClipboardTransferTests: XCTestCase {
    func testTextOfferRoundTripsOnlyForAuthenticatedIntendedRecipient() throws {
        let sent = try ClipboardTransferMessage(recipientIdentity: "bharat", text: "hello 👋")
        let bytes = try sent.encoded()
        let received = try ClipboardTransferMessage.decode(bytes, authenticatedSender: "harshit",
                                                             localIdentity: "bharat")
        XCTAssertEqual(received, sent)
    }

    func testDeliveryReceiptBindsTransferAndAuthenticatedPeers() throws {
        let id = UUID()
        let receipt = ClipboardDeliveryReceipt(transferID: id, senderIdentity: "bharat", recipientIdentity: "harshit")
        let bytes = try receipt.encoded()
        XCTAssertEqual(ClipboardDeliveryReceipt.decode(bytes, authenticatedSender: "bharat", localIdentity: "harshit"), receipt)
        XCTAssertNil(ClipboardDeliveryReceipt.decode(bytes, authenticatedSender: "mallory", localIdentity: "harshit"))
        XCTAssertNil(ClipboardDeliveryReceipt.decode(bytes, authenticatedSender: "bharat", localIdentity: "akshat"))
    }

    func testRejectsWrongRecipientAndUnauthenticatedOrLocalSender() throws {
        let bytes = try ClipboardTransferMessage(recipientIdentity: "bharat", text: "hello").encoded()
        XCTAssertThrowsError(try ClipboardTransferMessage.decode(bytes, authenticatedSender: "harshit",
                                                                  localIdentity: "akshat")) {
            XCTAssertEqual($0 as? ClipboardTransferError, .wrongRecipient)
        }
        for sender in ["", "bharat"] {
            XCTAssertThrowsError(try ClipboardTransferMessage.decode(bytes, authenticatedSender: sender,
                                                                      localIdentity: "bharat")) {
                XCTAssertEqual($0 as? ClipboardTransferError, .invalidSender)
            }
        }
    }

    func testRejectsStaleOrFutureDatedOffers() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let stale = try ClipboardTransferMessage(recipientIdentity: "bharat",
                                                  createdAt: now.addingTimeInterval(-121), text: "old")
        XCTAssertThrowsError(try ClipboardTransferMessage.decode(stale.encoded(), authenticatedSender: "harshit",
                                                                  localIdentity: "bharat", now: now)) {
            XCTAssertEqual($0 as? ClipboardTransferError, .expired)
        }
        let future = try ClipboardTransferMessage(recipientIdentity: "bharat",
                                                   createdAt: now.addingTimeInterval(6), text: "future")
        XCTAssertThrowsError(try ClipboardTransferMessage.decode(future.encoded(), authenticatedSender: "harshit",
                                                                  localIdentity: "bharat", now: now)) {
            XCTAssertEqual($0 as? ClipboardTransferError, .expired)
        }
    }

    func testEnforcesPayloadAndWireLimits() throws {
        XCTAssertThrowsError(try ClipboardTransferMessage(recipientIdentity: "bharat",
                                                           text: String(repeating: "x", count: ClipboardTransferMessage.maximumTextBytes + 1))) {
            XCTAssertEqual($0 as? ClipboardTransferError, .textTooLarge)
        }
        XCTAssertThrowsError(try ClipboardTransferMessage.decode(Data(repeating: 0, count: ClipboardTransferMessage.maximumWireBytes + 1),
                                                                  authenticatedSender: "harshit", localIdentity: "bharat")) {
            XCTAssertEqual($0 as? ClipboardTransferError, .messageTooLarge)
        }
    }

    func testLargeClipSplitsIntoPacketSizedPartsThatReassembleInAnyOrder() throws {
        let line = "let s = \"quoted \\ text\" // 🙂🙂 café\n"
        let text = String(repeating: line, count: 1_200)
        XCTAssertGreaterThan(text.utf8.count, 3 * ClipboardTransferMessage.maximumPartTextBytes)
        let parts = try ClipboardTransferMessage.parts(recipientIdentity: "bharat", text: text)
        XCTAssertGreaterThan(parts.count, 3)
        XCTAssertEqual(Set(parts.map(\.id)).count, 1)
        for part in parts {
            XCTAssertLessThanOrEqual(try part.encoded().count, ClipboardTransferMessage.maximumWireBytes)
            XCTAssertLessThanOrEqual(part.text.utf8.count, ClipboardTransferMessage.maximumPartTextBytes)
        }
        XCTAssertEqual(parts.map(\.text).joined(), text)

        var assembler = ClipboardTransferAssembler()
        var whole: ClipboardTransferMessage?
        for part in parts.shuffled() {
            let decoded = try ClipboardTransferMessage.decode(part.encoded(), authenticatedSender: "harshit", localIdentity: "bharat")
            if let done = assembler.add(decoded, from: "harshit") { whole = done }
        }
        XCTAssertEqual(whole?.text, text)
        XCTAssertEqual(whole?.id, parts[0].id)
        XCTAssertEqual(assembler.pendingCount, 0)
    }

    func testEveryPartStaysUnderTheReliablePacketCeiling() throws {
        // The worst case for JSON growth: every character escapes to two bytes.
        let text = String(repeating: "\"", count: ClipboardTransferMessage.maximumTextBytes)
        for part in try ClipboardTransferMessage.parts(recipientIdentity: "bharat", text: text) {
            XCTAssertLessThanOrEqual(try part.encoded().count, ClipboardTransferMessage.maximumWireBytes)
        }
        XCTAssertLessThan(ClipboardTransferMessage.maximumWireBytes, 15 * 1024 + 1)
    }

    func testSinglePartClipPassesStraightThroughTheAssembler() throws {
        var assembler = ClipboardTransferAssembler()
        let message = try ClipboardTransferMessage(recipientIdentity: "bharat", text: "short")
        XCTAssertEqual(assembler.add(message, from: "harshit"), message)
        XCTAssertEqual(assembler.pendingCount, 0)
    }

    func testAssemblerDropsOversizedAndInconsistentClips() throws {
        let id = UUID()
        var assembler = ClipboardTransferAssembler()
        let chunk = String(repeating: "x", count: 10 * 1024)
        for index in 0..<7 {
            let part = try ClipboardTransferMessage(id: id, recipientIdentity: "bharat", part: index, parts: 8, text: chunk)
            XCTAssertNil(assembler.add(part, from: "harshit"))
        }
        XCTAssertEqual(assembler.pendingCount, 0, "70 KiB of parts exceeds the clip limit and is discarded")

        let first = try ClipboardTransferMessage(id: id, recipientIdentity: "bharat", part: 0, parts: 2, text: "a")
        XCTAssertNil(assembler.add(first, from: "harshit"))
        let mismatched = try ClipboardTransferMessage(id: id, recipientIdentity: "bharat", part: 1, parts: 3, text: "b")
        XCTAssertNil(assembler.add(mismatched, from: "harshit"))
        XCTAssertEqual(assembler.pendingCount, 0)

        let stale = Date(timeIntervalSince1970: 10_000)
        XCTAssertNil(assembler.add(first, from: "harshit", now: stale))
        XCTAssertEqual(assembler.pendingCount, 1)
        let second = try ClipboardTransferMessage(id: id, recipientIdentity: "bharat", part: 1, parts: 2, text: "b")
        XCTAssertNil(assembler.add(second, from: "harshit", now: stale.addingTimeInterval(121)), "the first part expired")
        XCTAssertEqual(assembler.pendingCount, 1)
    }

    func testDecodeRejectsInconsistentPartNumbers() throws {
        let json = #"{"version":1,"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","recipientIdentity":"bharat","createdAt":"#
            + "\(Date().timeIntervalSinceReferenceDate)" + #","part":3,"parts":2,"text":"x"}"#
        XCTAssertThrowsError(try ClipboardTransferMessage.decode(Data(json.utf8), authenticatedSender: "harshit", localIdentity: "bharat")) {
            XCTAssertEqual($0 as? ClipboardTransferError, .malformedMessage)
        }
        XCTAssertThrowsError(try ClipboardTransferMessage(recipientIdentity: "bharat", part: 0, parts: 0, text: "x"))
    }

    func testSyncSkipsPasteboardItemsMarkedPrivateByTheirApp() {
        XCTAssertTrue(ClipboardSyncPolicy.mayShare(pasteboardTypes: ["public.utf8-plain-text"]))
        XCTAssertFalse(ClipboardSyncPolicy.mayShare(pasteboardTypes: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertFalse(ClipboardSyncPolicy.mayShare(pasteboardTypes: ["org.nspasteboard.TransientType", "public.utf8-plain-text"]))
        XCTAssertFalse(ClipboardSyncPolicy.mayShare(pasteboardTypes: ["org.nspasteboard.AutoGeneratedType"]))
        XCTAssertTrue(ClipboardSyncPolicy.mayShare(pasteboardTypes: []))
    }

    func testClipboardReadRetryWaitsForLazyTextThenExpires() {
        var retry = ClipboardPasteboardReadRetry()
        XCTAssertTrue(retry.mayRead(changeCount: 10, now: 1))
        XCTAssertTrue(retry.mayRead(changeCount: 10, now: 2.9))
        XCTAssertFalse(retry.mayRead(changeCount: 10, now: 3))

        retry.reset()
        XCTAssertTrue(retry.mayRead(changeCount: 11, now: 3.1))
        XCTAssertTrue(retry.mayRead(changeCount: 12, now: 3.2), "a new pasteboard write starts a fresh retry window")
    }

    func testPasteboardWriterReplacesContentsAndConfirmsWrite() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PairDeskClipboardWriter-\(UUID().uuidString)"))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }

        XCTAssertTrue(pasteboard.setString("old value", forType: .string))
        XCTAssertTrue(ClipboardPasteboardWriter.writeText("new value", to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "new value")
        XCTAssertFalse(ClipboardPasteboardWriter.writeText("", to: pasteboard))
    }

    func testClipboardSyncBatchReportsEveryRecipientOutcome() {
        let bharat = ClipboardSyncRecipient(identity: "bharat", name: "Bharat")
        let akshat = ClipboardSyncRecipient(identity: "akshat", name: "Akshat")
        var batch = ClipboardSyncBatch(recipients: [bharat, akshat])

        XCTAssertEqual(batch.status, "Syncing clipboard · 0/2 teammates")
        batch.record(identity: "bharat", delivered: true)
        XCTAssertEqual(batch.status, "Syncing clipboard · 1/2 teammates")
        batch.record(identity: "akshat", delivered: false)
        XCTAssertEqual(batch.status, "Synced with Bharat; failed for Akshat")
        XCTAssertTrue(batch.isComplete)
        XCTAssertEqual(batch.failedRecipients, [akshat])
    }

    func testClipboardSyncBatchIgnoresUnknownAndDuplicateResults() {
        var batch = ClipboardSyncBatch(recipients: [
            ClipboardSyncRecipient(identity: "bharat", name: "Bharat")
        ])

        batch.record(identity: "unknown", delivered: true)
        XCTAssertEqual(batch.status, "Syncing clipboard · 0/1 teammates")
        batch.record(identity: "bharat", delivered: false)
        batch.record(identity: "bharat", delivered: true)

        XCTAssertEqual(batch.status, "Clipboard sync failed for Bharat")
    }

    func testClipboardRetryTargetsOnlyFailedPeersStillInCall() {
        let bharat = ClipboardSyncRecipient(identity: "bharat", name: "Bharat")
        let akshat = ClipboardSyncRecipient(identity: "akshat", name: "Akshat")
        var batch = ClipboardSyncBatch(recipients: [bharat, akshat])
        batch.record(identity: "bharat", delivered: true)
        batch.record(identity: "akshat", delivered: false)

        XCTAssertEqual(batch.failedRecipientsAvailable(inCall: ["bharat", "akshat"]), [akshat])
        XCTAssertTrue(batch.failedRecipientsAvailable(inCall: ["bharat"]).isEmpty)
    }

    func testClipboardRetryWaitsForEveryRecipientOutcomeBeforeCancellingBatch() {
        var batch = ClipboardSyncBatch(recipients: [
            ClipboardSyncRecipient(identity: "bharat", name: "Bharat"),
            ClipboardSyncRecipient(identity: "akshat", name: "Akshat"),
        ])
        batch.record(identity: "bharat", delivered: false)

        XCTAssertFalse(batch.isComplete)
        XCTAssertFalse(batch.canRetryFailedRecipients, "Retrying now could cancel Akshat's still-running transfer")

        batch.record(identity: "akshat", delivered: true)
        XCTAssertTrue(batch.isComplete)
        XCTAssertTrue(batch.canRetryFailedRecipients)
        XCTAssertEqual(batch.failedRecipients.map(\.identity), ["bharat"])
    }

    func testClipboardSyncNoticeUsesDistinctVisualStates() {
        XCTAssertEqual(ClipboardSyncNoticePresentation.resolve("Syncing clipboard · 1/2 teammates"),
                       ClipboardSyncNoticePresentation(symbol: "arrow.triangle.2.circlepath", tone: .progress))
        XCTAssertEqual(ClipboardSyncNoticePresentation.resolve("Clipboard synced with Bharat"),
                       ClipboardSyncNoticePresentation(symbol: "checkmark.circle.fill", tone: .success))
        XCTAssertEqual(ClipboardSyncNoticePresentation.resolve("Clipboard sync failed for Bharat"),
                       ClipboardSyncNoticePresentation(symbol: "exclamationmark.triangle.fill", tone: .warning))
    }

    func testReplayWindowRejectsDuplicateAndEvictsOldestWithinBound() {
        var window = ClipboardTransferReplayWindow(capacity: 2)
        let first = UUID(), second = UUID(), third = UUID()
        XCTAssertTrue(window.insert(first))
        XCTAssertFalse(window.insert(first))
        XCTAssertTrue(window.insert(second))
        XCTAssertTrue(window.insert(third))
        XCTAssertFalse(window.seen.contains(first))
        XCTAssertTrue(window.insert(first))
    }
}
