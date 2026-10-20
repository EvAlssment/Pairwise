import Combine
import Foundation
import Darwin
import Security

/// Call-scoped, local-only bridge for explicitly granted coding-agent context.
/// The socket is created only after the person grants at least one capability.
@MainActor
final class LocalAgentBridge: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var grantedCapabilities: Set<String> = []
    @Published private(set) var socketPath = ""
    @Published private(set) var credential: String?

    private let state: AgentBridgeState
    private let endpoint: URL
    private var listener: Int32 = -1
    private var listenerQueue: DispatchQueue?
    private var callID: String?

    init(socketURL: URL? = nil, auditURL: URL? = nil) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        endpoint = socketURL ?? root.appendingPathComponent("PairDesk/agent.sock")
        state = AgentBridgeState(auditURL: auditURL ?? LocalAgentBridgeAudit.url)
    }

    func update(callID: String?, participants: [[String: String]], transcript: [[String: String]]) {
        if self.callID != callID {
            revoke(reason: "call-ended")
            self.callID = callID
        }
        state.update(callID: callID, participants: participants, transcript: transcript)
    }

    @discardableResult
    func authorize(capabilities: Set<String>) -> String? {
        guard callID != nil, !capabilities.isEmpty,
              capabilities.isSubset(of: ["participants", "transcript"]) else { return nil }
        revoke(reason: "replaced")
        guard let token = Self.randomCredential() else { return nil }
        let path = endpoint.path
        guard startListener(path: path) else { return nil }
        state.authorize(token: token, capabilities: capabilities)
        credential = token
        grantedCapabilities = capabilities
        socketPath = path
        isEnabled = true
        state.audit("grant", capability: capabilities.sorted().joined(separator: ","))
        return token
    }

    func revoke(reason: String = "user-revoked") {
        guard isEnabled || listener >= 0 else { return }
        state.revoke(reason: reason)
        if listener >= 0 {
            shutdown(listener, SHUT_RDWR)
            close(listener)
            listener = -1
        }
        if !socketPath.isEmpty { unlink(socketPath) }
        credential = nil
        grantedCapabilities = []
        isEnabled = false
        socketPath = ""
    }

    private func startListener(path: String) -> Bool {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch { return false }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd); unlink(path); return false
        }
        listener = fd
        listenerQueue = DispatchQueue(label: "app.pairdesk.agent-bridge", qos: .utility)
        let bridgeState = state
        listenerQueue?.async { Self.acceptLoop(fd, state: bridgeState) }
        return true
    }

    nonisolated private static func acceptLoop(_ fd: Int32, state: AgentBridgeState) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            defer { close(client) }
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let count = read(client, &buffer, buffer.count - 1)
            guard count > 0, let request = try? JSONDecoder().decode(AgentBridgeRequest.self,
                from: Data(buffer.prefix(count))) else { continue }
            let response = state.handle(request)
            guard let data = try? JSONEncoder().encode(response) else { continue }
            _ = data.withUnsafeBytes { write(client, $0.baseAddress, data.count) }
            _ = write(client, "\n", 1)
        }
    }

    private static func randomCredential() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct AgentBridgeRequest: Decodable {
    let token: String
    let method: String
}

struct AgentBridgeResponse: Encodable {
    let ok: Bool
    let result: [String: AnyCodable]?
    let error: String?
    init(result: [String: Any]?) {
        self.ok = true
        self.result = result?.mapValues(AnyCodable.init)
        self.error = nil
    }
    init(error: String) { self.ok = false; self.result = nil; self.error = error }
}

struct AnyCodable: Encodable {
    private let value: Any
    init(_ value: Any) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let value as String: try container.encode(value)
        case let value as [String]: try container.encode(value)
        case let value as [[String: String]]: try container.encode(value)
        case let value as [String: String]: try container.encode(value)
        default: try container.encodeNil()
        }
    }
}

final class AgentBridgeState: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCallID: String?
    private var token: String?
    private var capabilities = Set<String>()
    private var participants = [[String: String]]()
    private var transcript = [[String: String]]()
    private let auditURL: URL

    init(auditURL: URL) { self.auditURL = auditURL }

    func update(callID: String?, participants: [[String: String]], transcript: [[String: String]]) {
        lock.lock(); defer { lock.unlock() }
        activeCallID = callID
        self.participants = participants
        self.transcript = transcript
    }
    func authorize(token: String, capabilities: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        self.token = token
        self.capabilities = capabilities
    }
    func revoke(reason: String) {
        lock.lock(); defer { lock.unlock() }
        token = nil; capabilities = []
        LocalAgentBridgeAudit.write(action: "revoke", capability: reason, to: auditURL)
    }
    func audit(_ action: String, capability: String) {
        lock.lock(); defer { lock.unlock() }
        LocalAgentBridgeAudit.write(action: action, capability: capability, to: auditURL)
    }
    func handle(_ request: AgentBridgeRequest) -> AgentBridgeResponse {
        lock.lock(); defer { lock.unlock() }
        guard let token, Self.constantTimeEqual(token, request.token), activeCallID != nil else {
            LocalAgentBridgeAudit.write(action: "denied", capability: "unauthorized", to: auditURL)
            return AgentBridgeResponse(error: "unauthorized or call ended")
        }
        switch request.method {
        case "capabilities":
            LocalAgentBridgeAudit.write(action: "read", capability: "capabilities", to: auditURL)
            return AgentBridgeResponse(result: ["capabilities": Array(capabilities).sorted()])
        case "participants":
            guard capabilities.contains("participants") else {
                LocalAgentBridgeAudit.write(action: "denied", capability: "participants", to: auditURL)
                return AgentBridgeResponse(error: "participant capability not granted")
            }
            LocalAgentBridgeAudit.write(action: "read", capability: "participants", to: auditURL)
            return AgentBridgeResponse(result: ["participants": participants])
        case "transcript":
            guard capabilities.contains("transcript") else {
                LocalAgentBridgeAudit.write(action: "denied", capability: "transcript", to: auditURL)
                return AgentBridgeResponse(error: "transcript capability not granted")
            }
            LocalAgentBridgeAudit.write(action: "read", capability: "transcript", to: auditURL)
            return AgentBridgeResponse(result: ["segments": transcript])
        default:
            LocalAgentBridgeAudit.write(action: "denied", capability: "unknown", to: auditURL)
            return AgentBridgeResponse(error: "unknown method")
        }
    }
    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices {
            difference |= a[index] ^ b[index]
        }
        return difference == 0
    }
}

private enum LocalAgentBridgeAudit {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PairDesk/agent-audit.jsonl")
    }
    static func write(action: String, capability: String, to url: URL) {
        let row: [String: String] = ["time": ISO8601DateFormatter().string(from: Date()),
                                     "action": action, "capability": capability]
        guard let data = try? JSONSerialization.data(withJSONObject: row),
              let handle = try? FileHandle(forWritingTo: url) else {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let data = try JSONSerialization.data(withJSONObject: row) + Data([0x0a])
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { }
            return
        }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: data + Data([0x0a])) } catch { }
    }
}
