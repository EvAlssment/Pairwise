import Foundation

struct TeamUser: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let email: String
    var online: Bool?
    var busy: Bool?
    var initials: String { name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
}
struct PairRoom: Codable, Identifiable, Equatable {
    let id: String; let name: String; var participantCount: Int; var participants: [TeamUser]
}
struct LoginResponse: Decodable { let token: String; let user: TeamUser }
struct MeResponse: Decodable { let user: TeamUser }
struct UsersResponse: Decodable { let users: [TeamUser] }
struct CallsResponse: Decodable { let calls: [CallInvitation] }
struct ActiveCallsResponse: Decodable { let calls: [PairRoom] }
struct JoinRequestsResponse: Decodable { let requests: [CallJoinRequest] }
struct JoinResponse: Decodable { let room: PairRoom; let url: String; let token: String; let participantIdentity: String }
struct CallResponse: Decodable { let call: CallInvitation }
struct JoinRequestResponse: Decodable { let request: CallJoinRequest }
struct CallInvitation: Decodable, Identifiable, Equatable {
    let id: String; let status: String; let caller: TeamUser; let target: TeamUser; let room: PairRoom; let createdAt: String?; let expiresAt: String
    var createdDate: Date? { guard let createdAt else { return nil }; return ISO8601DateFormatter().date(from: createdAt) }
}
struct CallJoinRequest: Decodable, Identifiable, Equatable {
    let id: String; let status: String; let requester: TeamUser; let room: PairRoom; let expiresAt: String
}
struct APIError: LocalizedError {
    let message: String
    let status: Int?
    init(message: String, status: Int? = nil) { self.message = message; self.status = status }
    var errorDescription: String? { message }
}
struct EmptyBody: Encodable {}
