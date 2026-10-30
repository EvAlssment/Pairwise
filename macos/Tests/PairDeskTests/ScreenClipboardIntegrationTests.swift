import AppKit
import XCTest
@preconcurrency import LiveKit
@testable import PairDesk

final class ScreenClipboardIntegrationTests: XCTestCase {
    @MainActor
    func testNativeAppKitCopyPasteDispatch() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let destination = ClipboardDestination(pasteboard: board)
        board.setString("native paste · 你好", forType: .string)
        XCTAssertTrue(destination.dispatchShortcut(9))
        try await waitFor { destination.editor.string == "native paste · 你好" }
        XCTAssertEqual(destination.editor.string, "native paste · 你好")
        destination.editor.setSelectedRange(NSRange(location: 0, length: 6))
        XCTAssertTrue(destination.dispatchShortcut(8))
        try await waitFor { board.string(forType: .string) == "native" }
        XCTAssertEqual(board.string(forType: .string), "native")
    }

    @MainActor
    func testScreenSharingEnablesClipboardWithoutTheCallWideToggle() async {
        let rtc = RTCService()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        rtc.debugSetCall(participants: [], microphoneEnabled: false)
        XCTAssertFalse(rtc.clipboardSharingEnabled)
        rtc.debugConfigureScreenClipboard(pasteboard: board, peer: "host", epoch: "share", sharing: false) { _ in true }
        XCTAssertFalse(rtc.clipboardSyncEnabled)
        XCTAssertTrue(rtc.clipboardSharingEnabled)
        rtc.setClipboardSyncEnabled(false)
        XCTAssertTrue(rtc.clipboardSharingEnabled, "Screen sharing must not require a second opt-in")
        rtc.debugEndScreenClipboardShare()
        XCTAssertFalse(rtc.clipboardSharingEnabled)
        await rtc.disconnect()
    }

    /// Two real RTCService clients with independent pasteboards. Replace the
    /// system-wide posting boundary so CI never types into unrelated apps.
    @MainActor
    func testBidirectionalScreenClipboardOverAuthenticatedLiveKit() async throws {
        guard let address = ProcessInfo.processInfo.environment["PAIRDESK_TEST_API"],
              let password = ProcessInfo.processInfo.environment["PAIRDESK_TEST_PASSWORD"] else {
            throw XCTSkip("Run scripts/test-call.sh for screen clipboard integration")
        }
        _ = NSApplication.shared
        struct LoginBody: Encodable { let email: String; let password: String }
        struct RoomBody: Encodable { let name: String }
        let unsigned = try APIClient(server: address)
        var clients: [APIClient] = []
        for i in 1...2 {
            let login: LoginResponse = try await unsigned.post("v1/login", body: LoginBody(email: "integration-\(i)@pairdesk.invalid", password: password))
            clients.append(try APIClient(server: address, token: login.token))
        }
        let response: RoomResponse = try await clients[0].post("v1/rooms", body: RoomBody(name: "Screen clipboard fixture"))
        let host = RTCService(), viewer = RTCService()
        let hostBoard = NSPasteboard.withUniqueName(), viewerBoard = NSPasteboard.withUniqueName()
        defer { hostBoard.releaseGlobally(); viewerBoard.releaseGlobally() }
        let localText = String(repeating: "local code · 你好 🙂\n", count: 1_800)
        viewerBoard.setString(localText, forType: .string) // Copied before connecting or enabling sync.
        do {
            let hostJoin: JoinResponse = try await clients[0].post("v1/rooms/\(response.room.id)/join", body: EmptyBody())
            try await host.connect(url: hostJoin.url, token: hostJoin.token, identity: hostJoin.participantIdentity, name: "Host")
            let viewerJoin: JoinResponse = try await clients[1].post("v1/rooms/\(response.room.id)/join", body: EmptyBody())
            try await viewer.connect(url: viewerJoin.url, token: viewerJoin.token, identity: viewerJoin.participantIdentity, name: "Viewer")
            try await waitFor { host.participants.count == 2 && viewer.participants.count == 2 }
            let selectedRemoteText = String(repeating: "remote selection 👩🏽‍💻\n", count: 1_000)
            let destination = ClipboardDestination(pasteboard: hostBoard)
            host.debugConfigureScreenClipboard(pasteboard: hostBoard, peer: viewerJoin.participantIdentity,
                                                epoch: "clipboard-fixture", sharing: true) { code in
                destination.dispatchShortcut(code)
            }
            viewer.debugConfigureScreenClipboard(pasteboard: viewerBoard, peer: hostJoin.participantIdentity,
                                                  epoch: "clipboard-fixture", sharing: false, controllerGranted: false) { _ in
                XCTFail("The viewer must never inject a copy/paste shortcut locally")
                return false
            }

            XCTAssertFalse(host.clipboardSyncEnabled)
            XCTAssertFalse(viewer.clipboardSyncEnabled)
            XCTAssertTrue(host.automaticScreenClipboardEnabled)
            XCTAssertTrue(viewer.automaticScreenClipboardEnabled)

            let canvas = ScreenCanvas(rtc: viewer)
            canvas.driving = true
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = canvas
            window.makeFirstResponder(canvas)
            defer { window.contentView = nil }
            func shortcut(_ code: UInt16, characters: String) throws {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
                XCTAssertTrue(window.performKeyEquivalent(with: event))
                let up = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
                canvas.keyUp(with: up)
            }

            try shortcut(9, characters: "v")
            try await waitFor { destination.editor.pasteCount == 1 }
            XCTAssertEqual(destination.editor.string, localText, "Native destination must receive the new text")
            try await waitFor { viewer.clipboardSyncNotice?.hasPrefix("Paste sent") == true }
            XCTAssertNil(host.incomingClipboardTransfer)
            XCTAssertNil(viewer.incomingClipboardTransfer)

            // The fixture starts automatic screen-sharing polling after installing isolated
            // pasteboards, so this exercises the same authenticated room as
            // the explicit shortcut checks without resetting control state.
            var syncDurations: [Duration] = []
            for sample in 0..<5 {
                let autoSyncedText = "automatic clipboard sync \(sample) · café 🚀"
                viewerBoard.clearContents()
                let syncStartedAt = ContinuousClock.now
                viewerBoard.setString(autoSyncedText, forType: .string)
                try await waitFor { hostBoard.string(forType: .string) == autoSyncedText }
                syncDurations.append(syncStartedAt.duration(to: ContinuousClock.now))
                XCTAssertEqual(hostBoard.string(forType: .string), autoSyncedText)
            }
            let sortedSyncDurations = syncDurations.sorted()
            XCTAssertLessThanOrEqual(sortedSyncDurations[sortedSyncDurations.count / 2], .milliseconds(350),
                                     "Typical automatic clipboard sync should feel immediate")
            XCTAssertLessThanOrEqual(sortedSyncDurations.last ?? .zero, .milliseconds(750),
                                     "Clipboard sync should not have a long loopback tail")
            viewerBoard.clearContents()
            viewerBoard.setString(localText, forType: .string)
            try await waitFor { hostBoard.string(forType: .string) == localText }

            destination.editor.string = selectedRemoteText
            destination.editor.setSelectedRange(NSRange(location: 0, length: (selectedRemoteText as NSString).length))

            try shortcut(8, characters: "c")
            try await waitFor { viewerBoard.string(forType: .string) == selectedRemoteText }
            XCTAssertEqual(viewerBoard.string(forType: .string), selectedRemoteText)
            try shortcut(9, characters: "v")
            try await waitFor { destination.editor.pasteCount == 2 }
            XCTAssertEqual(destination.editor.string, selectedRemoteText)

            // Turning off the unrelated call-wide toggle must not block a
            // screen-share paste or bring back the review/approval UI.
            host.setClipboardSyncEnabled(false)
            viewer.setClipboardSyncEnabled(false)
            destination.editor.setSelectedRange(NSRange(location: 0, length: (selectedRemoteText as NSString).length))
            XCTAssertTrue(canvas.tryToPerform(#selector(NSText.paste(_:)), with: nil))
            try await waitFor { destination.editor.pasteCount == 3 }
            XCTAssertEqual(destination.editor.string, selectedRemoteText)
            XCTAssertNil(host.incomingClipboardTransfer)
            XCTAssertNil(viewer.incomingClipboardTransfer)

            // Neither an observer nor a message from a previous share can paste.
            let forbidden = try ClipboardTransferMessage(recipientIdentity: hostJoin.participantIdentity, text: "forbidden")
            let currentEpoch = try XCTUnwrap(host.debugControlEpoch)
            host.debugReceiveControl(.init(epoch: currentEpoch, sequence: 1_000, kind: .clipboardPaste, clipboard: forbidden), sender: "observer")
            host.debugReceiveControl(.init(epoch: "old-share", sequence: 1_001, kind: .clipboardPaste, clipboard: forbidden), sender: viewerJoin.participantIdentity)
            XCTAssertEqual(destination.editor.pasteCount, 3)
            host.pauseRemoteControl()
            host.debugReceiveControl(.init(epoch: currentEpoch, sequence: 1_002, kind: .clipboardPaste, clipboard: forbidden), sender: viewerJoin.participantIdentity)
            XCTAssertEqual(destination.editor.pasteCount, 3)
            XCTAssertEqual(hostBoard.string(forType: .string), selectedRemoteText)
            host.debugEndScreenClipboardShare()
            try await viewer.sendClipboard(text: "late screen clipboard", to: hostJoin.participantIdentity, screenSharing: true)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(hostBoard.string(forType: .string), selectedRemoteText)
            XCTAssertNil(host.incomingClipboardTransfer, "Late screen packets must not become approval offers after the share ends")
            viewer.debugEndScreenClipboardShare()
            XCTAssertFalse(host.clipboardSharingEnabled)
            XCTAssertFalse(viewer.clipboardSharingEnabled)
        } catch {
            await host.disconnect(); await viewer.disconnect()
            for client in clients { try? await client.send("v1/rooms/\(response.room.id)/leave", body: EmptyBody()) }
            throw error
        }
        await host.disconnect(); await viewer.disconnect()
        XCTAssertFalse(host.clipboardSyncEnabled)
        XCTAssertFalse(viewer.clipboardSyncEnabled)
        for client in clients { try? await client.send("v1/rooms/\(response.room.id)/leave", body: EmptyBody()) }
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Clipboard state did not propagate", file: file, line: line)
        throw ScreenClipboardError.copyTimedOut
    }
}

/// Exercise AppKit's real text selection, Edit-menu dispatch and insertion
/// using production CGEvent construction. Only the system-wide event posting
/// boundary is replaced, so CI never types into an unrelated application.
@MainActor
private final class ClipboardDestination {
    let editor: ClipboardDestinationTextView
    private let menu = NSMenu()
    private let window: NSWindow

    init(pasteboard: NSPasteboard) {
        editor = ClipboardDestinationTextView(pasteboard: pasteboard)
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        menu.autoenablesItems = false
        for (title, action, key) in [("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = editor
            menu.addItem(item)
        }
    }

    func dispatchShortcut(_ code: UInt16) -> Bool {
        guard let events = RemoteInputInjector.clipboardShortcutEvents(code: code) else { return false }
        for cgEvent in events where cgEvent.type == .keyDown && cgEvent.getIntegerValueField(.keyboardEventKeycode) == Int64(code) {
            let text = code == 8 ? "c" : "v"
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(cgEvent.flags.rawValue)), timestamp: 0,
                windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code), menu.performKeyEquivalent(with: event) else { return false }
        }
        return true
    }
}

@MainActor
private final class ClipboardDestinationTextView: NSTextView {
    let clipboard: NSPasteboard
    private(set) var pasteCount = 0

    init(pasteboard: NSPasteboard) {
        clipboard = pasteboard
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: 600, height: 400))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func copy(_ sender: Any?) {
        let selection = (string as NSString).substring(with: selectedRange())
        clipboard.clearContents()
        clipboard.setString(selection, forType: .string)
    }
    override func paste(_ sender: Any?) {
        if readSelection(from: clipboard, type: .string) { pasteCount += 1 }
    }
}
