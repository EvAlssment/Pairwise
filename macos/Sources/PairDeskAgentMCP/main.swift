import Foundation
import Darwin

// Minimal MCP stdio adapter. It has no network transport and only forwards
// read-only, capability-scoped requests to the app's active-call Unix socket.
let output = FileHandle.standardOutput
var initializedLegacy = false
while let line = readLine() {
    guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let method = request["method"] as? String else { continue }
    let id = request["id"] ?? NSNull()
    if method.hasPrefix("notifications/") { continue }
    let response: [String: Any]
    switch method {
    case "server/discover":
        response = ["jsonrpc": "2.0", "id": id, "result": ["resultType": "complete",
            "supportedVersions": ["2026-07-28", "2025-11-25"], "capabilities": ["tools": [:]],
            "_meta": ["io.modelcontextprotocol/serverInfo": ["name": "pairdesk-local", "version": "0.1.0"]],
            "instructions": "Read-only PairDesk call context. Access is limited by the person's active-call grants."]]
    case "initialize":
        initializedLegacy = true
        response = ["jsonrpc": "2.0", "id": id,
                    "result": ["protocolVersion": "2025-11-25",
                               "capabilities": ["tools": ["listChanged": false]],
                               "serverInfo": ["name": "pairdesk-local", "version": "0.1.0"]]]
    case "ping":
        guard supportsRequestMetadata(request, legacy: initializedLegacy) else {
            response = protocolError(id: id); send(response, to: output); continue
        }
        response = ["jsonrpc": "2.0", "id": id, "result": ["resultType": "complete"]]
    case "tools/list":
        guard supportsRequestMetadata(request, legacy: initializedLegacy) else {
            response = protocolError(id: id); send(response, to: output); continue
        }
        let capabilities = (try? callBridge(method: "capabilities")["capabilities"] as? [String]) ?? []
        var tools = [[String: Any]]()
        if capabilities.contains("participants") {
            tools.append(["name": "pairdesk_call_participants", "description": "Read participant names for the active PairDesk call.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]])
        }
        if capabilities.contains("transcript") {
            tools.append(["name": "pairdesk_call_transcript", "description": "Read the local transcript for the active PairDesk call.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]])
        }
        response = ["jsonrpc": "2.0", "id": id, "result": ["resultType": "complete", "tools": tools]]
    case "tools/call":
        guard supportsRequestMetadata(request, legacy: initializedLegacy) else {
            response = protocolError(id: id); send(response, to: output); continue
        }
        let params = request["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let bridgeMethod: String
        switch name {
        case "pairdesk_call_participants": bridgeMethod = "participants"
        case "pairdesk_call_transcript": bridgeMethod = "transcript"
        default:
            response = ["jsonrpc": "2.0", "id": id,
                        "error": ["code": -32602, "message": "Unknown PairDesk tool"]]
            send(response, to: output); continue
        }
        do {
            let result = try callBridge(method: bridgeMethod)
            let text = String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
            response = ["jsonrpc": "2.0", "id": id,
                        "result": ["resultType": "complete", "content": [["type": "text", "text": text]], "isError": false]]
        } catch {
            response = ["jsonrpc": "2.0", "id": id,
                        "result": ["resultType": "complete", "content": [["type": "text", "text": error.localizedDescription]], "isError": true]]
        }
    default:
        response = ["jsonrpc": "2.0", "id": id,
                    "error": ["code": -32601, "message": "Method not found"]]
    }
    send(response, to: output)
}

func supportsRequestMetadata(_ request: [String: Any], legacy: Bool) -> Bool {
    if legacy { return true }
    let params = request["params"] as? [String: Any] ?? [:]
    let metadata = params["_meta"] as? [String: Any] ?? [:]
    return metadata["io.modelcontextprotocol/protocolVersion"] as? String == "2026-07-28"
        && metadata["io.modelcontextprotocol/clientCapabilities"] is [String: Any]
}

func protocolError(id: Any) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "error": ["code": -32600,
        "message": "This request needs valid MCP metadata for protocol version 2026-07-28, or a legacy initialize handshake."]]
}

func send(_ response: [String: Any], to output: FileHandle) {
    guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
    output.write(data); output.write(Data([0x0a]))
}

func callBridge(method: String) throws -> [String: Any] {
    guard let token = ProcessInfo.processInfo.environment["PAIRDESK_BRIDGE_TOKEN"], !token.isEmpty else {
        throw BridgeError.message("PairDesk bridge token is missing; enable access in the active call and configure the current call token.")
    }
    let defaultPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("PairDesk/agent.sock").path
    let path = ProcessInfo.processInfo.environment["PAIRDESK_BRIDGE_SOCKET"] ?? defaultPath
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw BridgeError.message("Could not open PairDesk's local socket.") }
    defer { close(fd) }
    var noSignal: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw BridgeError.message("PairDesk socket path is too long.") }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { throw BridgeError.message("PairDesk local access is unavailable or has expired.") }
    let object: [String: String] = ["token": token, "method": method]
    let data = try JSONSerialization.data(withJSONObject: object) + Data([0x0a])
    let wrote = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    guard wrote == data.count else { throw BridgeError.message("Could not send the local PairDesk request.") }
    var buffer = [UInt8](repeating: 0, count: 128 * 1024)
    let count = read(fd, &buffer, buffer.count)
    guard count > 0, let result = try JSONSerialization.jsonObject(with: Data(buffer.prefix(count))) as? [String: Any] else {
        throw BridgeError.message("PairDesk returned an invalid local response.")
    }
    guard result["ok"] as? Bool == true else {
        throw BridgeError.message(result["error"] as? String ?? "PairDesk denied this capability.")
    }
    return result["result"] as? [String: Any] ?? [:]
}

enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
