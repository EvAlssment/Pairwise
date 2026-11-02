import Foundation

struct ServerReadinessResult: Decodable, Equatable {
    let ok: Bool
    let media: Bool?
    let dependency: String?
}

struct ServerReadinessCheck {
    static func displayAddress(_ server: String) -> String {
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else { return "Not configured" }
        guard let url = URL(string: server),
              let host = url.host else { return "Unavailable" }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    static func isLocalOnly(_ server: String) -> Bool {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    static func run(server: String, session: URLSession? = nil) async throws -> (result: ServerReadinessResult, milliseconds: Int) {
        let client = try APIClient(server: server)
        var request = URLRequest(url: client.baseURL.appendingPathComponent("readyz"), timeoutInterval: 6)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Deliberately use an unauthenticated, cookie-free readiness request. It tests
        // service availability without sending the user's PairDesk session token.
        let readinessSession: URLSession
        if let session {
            readinessSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 6
            readinessSession = URLSession(configuration: configuration)
        }

        let start = ContinuousClock.now
        let (data, response) = try await readinessSession.data(for: request)
        let elapsed = start.duration(to: .now).components
        let milliseconds = Int(Double(elapsed.seconds) * 1_000
            + Double(elapsed.attoseconds) / 1_000_000_000_000_000)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(status: 0, message: "No response from the team server.")
        }
        return (try parse(data: data, statusCode: http.statusCode), milliseconds)
    }

    static func parse(data: Data, statusCode: Int) throws -> ServerReadinessResult {
        guard let response = try? JSONDecoder().decode(ServerReadinessResult.self, from: data) else {
            throw APIError(status: statusCode, message: "The team server returned an incompatible readiness response.")
        }
        return ServerReadinessResult(
            ok: statusCode == 200 && response.ok,
            media: statusCode == 200 && response.media == true,
            dependency: response.dependency
        )
    }
}
