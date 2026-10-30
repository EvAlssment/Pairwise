import AppKit
import XCTest
@testable import PairDesk

final class ScreenClipboardTests: XCTestCase {
    func testNativeClipboardShortcutBalancesCommandEvenAfterViewerReleasedIt() {
        for code: UInt16 in [8, 9] {
            guard let events = RemoteInputInjector.clipboardShortcutEvents(code: code) else {
                XCTFail("Native shortcut events couldn't be created"); return
            }
            XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [55, Int64(code), Int64(code), 55])
            XCTAssertTrue(events[0].flags.contains(.maskCommand))
            XCTAssertTrue(events[1].flags.contains(.maskCommand))
            XCTAssertTrue(events[2].flags.contains(.maskCommand))
            XCTAssertFalse(events[3].flags.contains(.maskCommand))
            XCTAssertEqual(events[1].type, .keyDown)
            XCTAssertEqual(events[2].type, .keyUp)
            for event in events { XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), RemoteInputInjector.eventMarker) }
        }
        XCTAssertNil(RemoteInputInjector.clipboardShortcutEvents(code: 0))
    }

    func testAutomaticClipboardSyncUsesResponsiveOptInPollingInterval() {
        XCTAssertEqual(ClipboardSyncPolicy.pollInterval, .milliseconds(75))
    }

    @MainActor
    func testPasteWaitsForAllPartsAndPostsExactlyOneShortcut() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("old remote clipboard", forType: .string)
        var pasted: [String] = []
        let clipboard = ScreenClipboard(pasteboard: board) { code in
            XCTAssertEqual(code, 9)
            pasted.append(board.string(forType: .string) ?? "")
            return true
        }
        let text = String(repeating: "hello 👩🏽‍💻\n", count: 2_000)
        let parts = try ClipboardTransferMessage.parts(recipientIdentity: "host", text: text)
        for part in parts.dropLast().reversed() {
            XCTAssertNil(try clipboard.paste(part, from: "viewer", epoch: "lease"))
        }
        XCTAssertEqual(board.string(forType: .string), "old remote clipboard")
        XCTAssertTrue(pasted.isEmpty)
        XCTAssertEqual(try clipboard.paste(parts.last!, from: "viewer", epoch: "lease"), text)
        XCTAssertEqual(pasted, [text])
        for part in parts { XCTAssertNil(try clipboard.paste(part, from: "viewer", epoch: "lease")) }
        XCTAssertEqual(pasted.count, 1, "Replayed clips must never paste twice")
    }

    @MainActor
    func testPartialPasteCannotCrossControlLeases() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var shortcuts = 0
        let clipboard = ScreenClipboard(pasteboard: board) { _ in shortcuts += 1; return true }
        let parts = try ClipboardTransferMessage.parts(recipientIdentity: "host", text: String(repeating: "x", count: 7_000))
        XCTAssertNil(try clipboard.paste(parts[0], from: "viewer", epoch: "old"))
        XCTAssertNil(try clipboard.paste(parts[1], from: "viewer", epoch: "new"))
        XCTAssertEqual(shortcuts, 0)
        clipboard.reset()
        XCTAssertNil(try clipboard.paste(parts[0], from: "viewer", epoch: "new"))
        XCTAssertEqual(shortcuts, 0)
    }

    @MainActor
    func testCopyWaitsForTheRemoteAppAndAcceptsRecopyingTheSameText() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("same text", forType: .string)
        let clipboard = ScreenClipboard(pasteboard: board) { code in
            XCTAssertEqual(code, 8)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                board.clearContents()
                board.setString("same text", forType: .string)
            }
            return true
        }
        let copied = try await clipboard.copyText { true }
        XCTAssertEqual(copied, "same text")
    }

    @MainActor
    func testCopyNeverReturnsAnUnchangedStaleClipboard() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("unrelated secret", forType: .string)
        let clipboard = ScreenClipboard(pasteboard: board) { _ in true }
        do {
            _ = try await clipboard.copyText { true }
            XCTFail("An app that doesn't copy must not return the old clipboard")
        } catch {
            XCTAssertEqual(error as? ScreenClipboardError, .copyTimedOut)
        }
    }

    @MainActor
    func testConsentRevokedWhileCopyIsPendingStopsTheRead() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var allowed = true
        let clipboard = ScreenClipboard(pasteboard: board) { _ in
            allowed = false
            board.setString("must not return", forType: .string)
            return true
        }
        do {
            _ = try await clipboard.copyText { allowed }
            XCTFail("A revoked operation must not return clipboard text")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testPrivateNonTextAndOversizedLocalClipboardsAreRejected() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clipboard = ScreenClipboard(pasteboard: board) { _ in true }
        XCTAssertThrowsError(try clipboard.readText())
        board.setString(String(repeating: "x", count: 65_537), forType: .string)
        XCTAssertThrowsError(try clipboard.readText())
        board.clearContents()
        board.setString("password", forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        XCTAssertThrowsError(try clipboard.readText()) {
            XCTAssertEqual($0 as? ScreenClipboardError, .privateText)
        }
        XCTAssertEqual(try clipboard.readText(includePrivate: true), "password", "An explicit paste must honor the user's action")
    }

    @MainActor
    func testFailedNativePasteIsReportedAndNotRetriedOnReplay() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var attempts = 0
        let clipboard = ScreenClipboard(pasteboard: board) { _ in attempts += 1; return false }
        let part = try ClipboardTransferMessage(recipientIdentity: "host", text: "new")
        XCTAssertThrowsError(try clipboard.paste(part, from: "viewer", epoch: "lease")) {
            XCTAssertEqual($0 as? ScreenClipboardError, .inputFailed)
        }
        XCTAssertNil(try clipboard.paste(part, from: "viewer", epoch: "lease"))
        XCTAssertEqual(attempts, 1)
    }

    func testOnlyStandardCopyPasteShortcutsAreIntercepted() {
        for code: UInt16 in [8, 9] {
            XCTAssertTrue(ScreenClipboard.shortcut(code: code, modifiers: .command))
            XCTAssertTrue(ScreenClipboard.shortcut(code: code, modifiers: [.command, .capsLock]))
            for flags: NSEvent.ModifierFlags in [[], .control, [.command, .shift], [.command, .option]] {
                XCTAssertFalse(ScreenClipboard.shortcut(code: code, modifiers: flags))
            }
        }
        XCTAssertFalse(ScreenClipboard.shortcut(code: 7, modifiers: .command))
    }

    func testControlCharactersAndHugeGraphemesFitInsideControlEnvelopes() throws {
        for text in [String(repeating: "\u{0}", count: 65_536),
                     String(repeating: "\u{0}/", count: 32_768),
                     "a" + String(repeating: "\u{301}", count: 30_000),
                     String(repeating: "🙂", count: 16_384)] {
            let parts = try ClipboardTransferMessage.parts(recipientIdentity: "host", text: text)
            XCTAssertEqual(parts.map(\.text).joined(), text)
            for part in parts {
                let message = RemoteControlMessage(epoch: UUID().uuidString, sequence: 100, kind: .clipboardCopied,
                                                   clipboard: part, clipboardRequestID: part.id)
                XCTAssertLessThanOrEqual(try JSONEncoder().encode(message).count, ClipboardTransferMessage.maximumWireBytes)
            }
        }
    }
}
