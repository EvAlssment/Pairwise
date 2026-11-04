import Foundation

/// Adapter boundary for the future device-registration endpoint. The backend
/// contract is intentionally not assumed here; wire this protocol after the
/// server's POST /v1/devices schema is merged.
protocol PushRegistrationAPI: Sendable {
    func register(pushToken: Data, voipToken: Data?) async throws
    func unregister() async throws
}

struct APIClient {
    let baseURL: URL
    let token: String?
    var session: URLSession = .shared
    init(server: String, token: String? = nil, session: URLSession = .shared) throws {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw APIError(message: "Enter an HTTPS server address. HTTP is allowed only for a local development server.")
        }
        self.baseURL = url; self.token = token; self.session = session
    }
    func get<T: Decodable>(_ path: String) async throws -> T { try await request(path, method: "GET", body: nil) }
    func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await request(path, method: "POST", body: JSONEncoder().encode(body))
    }
    func send<B: Encodable>(_ path: String, body: B) async throws {
        _ = try await requestData(path, method: "POST", body: JSONEncoder().encode(body))
    }
    func delete(_ path: String) async throws {
        _ = try await requestData(path, method: "DELETE", body: nil)
    }
    func delete<B: Encodable>(_ path: String, body: B) async throws {
        _ = try await requestData(path, method: "DELETE", body: JSONEncoder().encode(body))
    }
    private func request<T: Decodable>(_ path: String, method: String, body: Data?) async throws -> T {
        let (data, _) = try await requestData(path, method: method, body: body)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError(message: "The server returned an incompatible response.") }
    }
    private func requestData(_ path: String, method: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 15)
        req.httpMethod = method; req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "No response from PairDesk server.") }
        guard (200..<300).contains(http.statusCode) else {
            let error = (try? JSONDecoder().decode(ServerError.self, from: data).error) ?? "Request failed (\(http.statusCode))."
            throw APIError(message: error, status: http.statusCode)
        }
        return (data, http)
    }
}
private struct ServerError: Decodable { let error: String }

/// Standard APNs is required for alert notifications. PushKit's VoIP token is
/// sent separately and only used for direct-call CallKit alerts.
struct PairDeskDeviceRegistration: PushRegistrationAPI {
    let client: APIClient
    let deviceID: String
    func register(pushToken: Data, voipToken: Data?) async throws {
        struct Body: Encodable { let deviceId: String; let platform: String; let pushToken: String; let voipToken: String? }
        func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
        try await client.send("v1/devices", body: Body(deviceId: deviceID, platform: "ios", pushToken: hex(pushToken), voipToken: voipToken.map(hex)))
    }
    func unregister() async throws { try await client.delete("v1/devices/\(deviceID)") }
}

enum DeviceInstallation {
    static var id: String {
        if let value = UserDefaults.standard.string(forKey: "pairdesk.installation-id") { return value }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: "pairdesk.installation-id")
        return value
    }
}
