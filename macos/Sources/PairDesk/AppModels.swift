import Foundation

struct TeamUser: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let email: String
    var online: Bool?
    var busy: Bool?
    var admin: Bool?
    var enabled: Bool?
    var initials: String { name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased() }
}

struct AdminAuditEvent: Decodable, Identifiable, Equatable {
    let actorId: String
    let targetId: String
    let action: String
    let occurredAt: String
    var id: String { "\(occurredAt)-\(action)-\(targetId)" }
    var date: Date { ISO8601DateFormatter().date(from: occurredAt) ?? .distantPast }
}

struct PairRoom: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    var participantCount: Int
    var participants: [TeamUser]
}

struct LoginResponse: Decodable { let token: String; let user: TeamUser; let expiresAt: String }
struct MeResponse: Decodable { let user: TeamUser }
struct UsersResponse: Decodable { let users: [TeamUser] }
struct AdminAuditResponse: Decodable { let events: [AdminAuditEvent] }
struct RoomsResponse: Decodable { let rooms: [PairRoom] }
struct ActiveCallsResponse: Decodable { let calls: [PairRoom] }
struct JoinRequestsResponse: Decodable { let requests: [CallJoinRequest] }
struct RoomResponse: Decodable { let room: PairRoom }
struct JoinResponse: Decodable { let room: PairRoom; let url: String; let token: String; let participantIdentity: String }
struct ErrorResponse: Decodable { let error: String }
struct EmptyBody: Encodable {}

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// Go's RFC 3339 timestamps can contain up to nine fractional-second digits.
enum ServerDate {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        // Before Swift 6.2, parsing requires fractional seconds to match the
        // format style exactly. Accept both forms on every supported macOS.
        return (try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(value, strategy: .iso8601))
    }
}

struct CallInvitation: Decodable, Identifiable, Equatable {
    let id: String
    let status: String
    let caller: TeamUser
    let target: TeamUser
    let room: PairRoom
    var createdAt: String? = nil
    var startedAt: String? = nil
    var endedAt: String? = nil
    let expiresAt: String
    init(id: String, status: String, caller: TeamUser, target: TeamUser, room: PairRoom, expiresAt: String) {
        self.id = id
        self.status = status
        self.caller = caller
        self.target = target
        self.room = room
        self.createdAt = nil
        self.expiresAt = expiresAt
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        status = try values.decode(String.self, forKey: .status)
        caller = try values.decode(TeamUser.self, forKey: .caller)
        target = try values.decode(TeamUser.self, forKey: .target)
        room = try values.decode(PairRoom.self, forKey: .room)
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
        startedAt = try values.decodeIfPresent(String.self, forKey: .startedAt)
        endedAt = try values.decodeIfPresent(String.self, forKey: .endedAt)
        expiresAt = try values.decode(String.self, forKey: .expiresAt)
    }
    private enum CodingKeys: String, CodingKey { case id, status, caller, target, room, createdAt, startedAt, endedAt, expiresAt }
    var createdDate: Date? { ServerDate.parse(createdAt) }
    var endedDate: Date? { ServerDate.parse(endedAt) }

    var historyDurationText: String? {
        guard status == "cancelled" else { return nil }
        guard let start = ServerDate.parse(startedAt), let end = endedDate, end >= start else {
            // A new unanswered attempt has an end time but no answer time.
            // Older completed calls have no reliable duration; never guess it.
            return startedAt == nil && endedAt != nil ? nil : "Duration unavailable"
        }
        let seconds = Int(end.timeIntervalSince(start))
        let duration = seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        return "Duration \(duration)"
    }

    var historyDateText: String? {
        if let endedDate { return "Ended \(endedDate.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))" }
        if let createdDate { return "Called \(createdDate.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))" }
        return nil
    }

    func historyStatusLabel(incoming: Bool) -> String {
        switch status {
        case "expired": incoming ? "Missed call" : "No answer"
        case "declined": incoming ? "Declined" : "Call declined"
        default: startedAt == nil && endedAt != nil ? "Cancelled" : "Call ended"
        }
    }
}
struct CallResponse: Decodable { let call: CallInvitation }
struct CallsResponse: Decodable { let calls: [CallInvitation] }
struct CallJoinRequest: Decodable, Identifiable, Equatable {
    let id: String
    let status: String
    let requester: TeamUser
    let room: PairRoom
    let expiresAt: String
}
struct CallJoinRequestResponse: Decodable { let request: CallJoinRequest }
