import XCTest
import Foundation
import Darwin
@testable import PairDesk

@MainActor
final class LocalAgentBridgeTests: XCTestCase {
    func testSocketRequiresGrantedCapabilityAndRevokesImmediately() throws {
        let root = URL(fileURLWithPath: "/tmp/pdb-\(UUID().uuidString)", isDirectory: true)
        let socket = root.appendingPathComponent("agent.sock")
        let audit = root.appendingPathComponent("audit.jsonl")
        let bridge = LocalAgentBridge(socketURL: socket, auditURL: audit)
        bridge.update(callID: "call-1", participants: [["name": "Harshit"]], transcript: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        let credential = try XCTUnwrap(bridge.authorize(capabilities: ["participants"]))
        defer { bridge.revoke(); try? FileManager.default.removeItem(at: root) }
        var socketInfo = stat()
        XCTAssertEqual(lstat(socket.path, &socketInfo), 0)
        XCTAssertEqual(socketInfo.st_mode & 0o777, 0o600)
        try runUnauthorizedMCPClient(socket: socket.path)

        let denied = try request(socket: socket.path, token: "wrong", method: "participants")
        XCTAssertEqual(denied["ok"] as? Bool, false)
        let granted = try request(socket: socket.path, token: credential, method: "participants")
        XCTAssertEqual(granted["ok"] as? Bool, true)
        XCTAssertNotNil(granted["result"] as? [String: Any])
        let ungranted = try request(socket: socket.path, token: credential, method: "transcript")
        XCTAssertEqual(ungranted["ok"] as? Bool, false)
        let auditText = try String(contentsOf: audit, encoding: .utf8)
        XCTAssertFalse(auditText.contains("Harshit"))
        XCTAssertFalse(auditText.contains("transcript text"))
        XCTAssertTrue(auditText.contains("denied"))

        bridge.revoke()
        XCTAssertThrowsError(try request(socket: socket.path, token: credential, method: "participants"))
        bridge.update(callID: "call-1", participants: [], transcript: [])
        let secondCredential = try XCTUnwrap(bridge.authorize(capabilities: ["participants"]))
        bridge.update(callID: nil, participants: [], transcript: [])
        XCTAssertThrowsError(try request(socket: socket.path, token: secondCredential, method: "participants"))
        XCTAssertNil(bridge.credential)
    }

    private func runUnauthorizedMCPClient(socket: String) throws {
        let helper = Bundle(for: LocalAgentBridgeTests.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("pairdesk-agent-mcp")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw XCTSkip("SwiftPM MCP helper executable was not built beside the test bundle")
        }
        let process = Process()
        process.executableURL = helper
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PAIRDESK_BRIDGE_TOKEN": "unauthorized-process-token",
            "PAIRDESK_BRIDGE_SOCKET": socket
        ]) { _, new in new }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#
        ].joined(separator: "\n") + "\n"
        input.fileHandleForWriting.write(Data(requests.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let response = try XCTUnwrap(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
        let last = try XCTUnwrap(response.split(separator: "\n").last)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
        let result = try XCTUnwrap(payload["result"] as? [String: Any])
        XCTAssertEqual((result["tools"] as? [Any])?.count, 0)
    }

    private func request(socket path: String, token: String, method: String) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let data = try JSONSerialization.data(withJSONObject: ["token": token, "method": method]) + Data([0x0a])
        let wrote = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        guard wrote == data.count else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer.prefix(count))) as? [String: Any])
    }
}
