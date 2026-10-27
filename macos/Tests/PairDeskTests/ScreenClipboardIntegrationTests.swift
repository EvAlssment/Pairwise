import AppKit
import XCTest
@preconcurrency import LiveKit
@testable import PairDesk

final class ScreenClipboardIntegrationTests: XCTestCase {
    /// Two real RTCService clients with independent pasteboards. Replace the
    /// OS shortcut boundary so CI never types into the runner's foreground app.
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
            host.setClipboardSyncEnabled(true)
            viewer.setClipboardSyncEnabled(true)
            let selectedRemoteText = String(repeating: "remote selection 👩🏽‍💻\n", count: 1_000)
            var pastedTexts: [String] = []
            host.debugConfigureScreenClipboard(pasteboard: hostBoard, peer: viewerJoin.participantIdentity,
                                                epoch: "clipboard-fixture", sharing: true) { code in
                if code == 8 {
                    // Model a destination app that handles Copy asynchronously.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(40))
                        hostBoard.clearContents()
                        hostBoard.setString(selectedRemoteText, forType: .string)
                    }
                } else if code == 9 { pastedTexts.append(hostBoard.string(forType: .string) ?? "") }
                return true
            }
            viewer.debugConfigureScreenClipboard(pasteboard: viewerBoard, peer: hostJoin.participantIdentity,
                                                  epoch: "clipboard-fixture", sharing: false, controllerGranted: false) { _ in
                XCTFail("The viewer must never inject a copy/paste shortcut locally")
                return false
            }

            // The fixture restarts opted-in polling after installing isolated
            // pasteboards, so this exercises the same authenticated room as
            // the explicit shortcut checks without resetting control state.
            let autoSyncedText = "automatic clipboard sync · café 🚀"
            viewerBoard.clearContents()
            viewerBoard.setString(autoSyncedText, forType: .string)
            try await waitFor { hostBoard.string(forType: .string) == autoSyncedText }
            XCTAssertEqual(hostBoard.string(forType: .string), autoSyncedText)
            viewerBoard.clearContents()
            viewerBoard.setString(localText, forType: .string)
            try await waitFor { hostBoard.string(forType: .string) == localText }

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
                XCTAssertTrue(canvas.performKeyEquivalent(with: event))
                let up = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: .command,
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
                canvas.keyUp(with: up)
            }

            try shortcut(9, characters: "v")
            try await waitFor { pastedTexts.count == 1 }
            XCTAssertEqual(pastedTexts, [localText], "Remote paste must see the transferred text, not an older clipboard")

            try shortcut(8, characters: "c")
            try await waitFor { viewerBoard.string(forType: .string) == selectedRemoteText }
            XCTAssertEqual(viewerBoard.string(forType: .string), selectedRemoteText)
            try shortcut(9, characters: "v")
            try await waitFor { pastedTexts.count == 2 }
            XCTAssertEqual(pastedTexts, [localText, selectedRemoteText])

            // Neither an observer nor a message from a previous share can paste.
            let forbidden = try ClipboardTransferMessage(recipientIdentity: hostJoin.participantIdentity, text: "forbidden")
            let currentEpoch = try XCTUnwrap(host.debugControlEpoch)
            host.debugReceiveControl(.init(epoch: currentEpoch, sequence: 1_000, kind: .clipboardPaste, clipboard: forbidden), sender: "observer")
            host.debugReceiveControl(.init(epoch: "old-share", sequence: 1_001, kind: .clipboardPaste, clipboard: forbidden), sender: viewerJoin.participantIdentity)
            XCTAssertEqual(pastedTexts.count, 2)
            host.setClipboardSyncEnabled(false)
            host.debugReceiveControl(.init(epoch: currentEpoch, sequence: 1_002, kind: .clipboardPaste, clipboard: forbidden), sender: viewerJoin.participantIdentity)
            XCTAssertEqual(pastedTexts.count, 2)
            XCTAssertEqual(hostBoard.string(forType: .string), selectedRemoteText)
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
