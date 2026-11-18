import Foundation
import XCTest
@testable import PairDesk

final class WindowsProtocolCompatibilityTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("shared/protocol-fixtures/\(name).json"))
    }

    func testWindowsUsesExistingMacVirtualKeyCodec() throws {
        let message = try JSONDecoder().decode(RemoteControlMessage.self, from: fixture("control-v1"))
        XCTAssertEqual(message.version, 1)
        XCTAssertEqual(message.kind, .key)
        XCTAssertEqual(message.code, 8)
        XCTAssertEqual(message.modifiers, 1 << 20)
        XCTAssertEqual(message.sequence, 42)
        var gate = RemoteControlGate()
        gate.grant(identity: "windows", epoch: message.epoch, now: 0)
        XCTAssertTrue(gate.accept(message, sender: "windows", now: 1))
        XCTAssertFalse(gate.accept(message, sender: "windows", now: 1))
    }

    func testWindowsClipboardUsesSwiftReferenceDateAndUnicode() throws {
        let data = try fixture("clipboard-v1")
        let message = try JSONDecoder().decode(ClipboardTransferMessage.self, from: data)
        XCTAssertEqual(message.createdAt, Date(timeIntervalSinceReferenceDate: 815_097_600))
        XCTAssertEqual(message.text, "Pairwise Windows ↔ macOS 🙂\nsecond line")
        try message.validate(authenticatedSender: "windows", localIdentity: "recipient", now: message.createdAt)
        let roundTrip = try JSONDecoder().decode(ClipboardTransferMessage.self, from: message.encoded())
        XCTAssertEqual(roundTrip, message)
    }
}
