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

enum PairDeskPasswordPolicy {
    static let minimumCharacters = 12
    static let maximumUTF8Bytes = 72

    static func isValid(_ password: String) -> Bool {
        password.count >= minimumCharacters && password.utf8.count <= maximumUTF8Bytes
    }

    static func hint(for password: String) -> String {
        if password.utf8.count > maximumUTF8Bytes {
            return "Too long by \(password.utf8.count - maximumUTF8Bytes) UTF-8 bytes"
        }
        if password.count < minimumCharacters {
            let remaining = minimumCharacters - password.count
            return password.isEmpty ? "At least 12 characters · max 72 UTF-8 bytes" : "\(remaining) more \(remaining == 1 ? "character" : "characters") needed"
        }
        return "Password meets the requirements"
    }
}

enum CallInviteAvailability: Equatable {
    case available
    case offline
    case inAnotherCall
    case alreadyInvited
    case alreadyInThisCall
    case callFull

    static func resolve(user: TeamUser, participantIDs: Set<String>,
                        outgoingInviteIDs: Set<String>, canAddPerson: Bool) -> Self {
        if participantIDs.contains(user.id) { return .alreadyInThisCall }
        if outgoingInviteIDs.contains(user.id) { return .alreadyInvited }
        guard user.online == true else { return .offline }
        guard user.busy != true else { return .inAnotherCall }
        guard canAddPerson else { return .callFull }
        return .available
    }

    var title: String {
        switch self {
        case .available: "Available"
        case .offline: "Offline"
        case .inAnotherCall: "In another call"
        case .alreadyInvited: "Calling…"
        case .alreadyInThisCall: "In this call"
        case .callFull: "Call full"
        }
    }

    var canInvite: Bool { self == .available }
}

enum CallMediaMode {
    static func title(screenSharing: Bool, cameraActive: Bool) -> String {
        switch (screenSharing, cameraActive) {
        case (true, true): "Screen + video"
        case (true, false): "Screen share"
        case (false, true): "Video call"
        case (false, false): "Audio call"
        }
    }
}

struct AdminAuditEvent: Decodable, Identifiable, Equatable {
    let actorId: String
    let targetId: String
    let action: String
    let occurredAt: String
    var id: String { "\(occurredAt)-\(action)-\(targetId)" }
    var date: Date? { ServerDate.parse(occurredAt) }
}

struct PairRoom: Codable, Identifiable, Equatable {
    static let maximumParticipants = 4
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
    init(id: String, status: String, caller: TeamUser, target: TeamUser, room: PairRoom, expiresAt: String, createdAt: String? = nil) {
        self.id = id
        self.status = status
        self.caller = caller
        self.target = target
        self.room = room
        self.createdAt = createdAt
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

    var historyDurationHelp: String {
        historyDurationText == "Duration unavailable"
            ? "Answer and end times are missing or unreadable for this call. Older calls may not have recorded them."
            : "Time from answer to end, excluding ringing."
    }

    func historyStatusLabel(incoming: Bool) -> String {
        switch status {
        case "expired": incoming ? "Missed call" : "No answer"
        case "declined": incoming ? "Declined" : "Call declined"
        default: startedAt == nil && endedAt != nil ? "Cancelled" : "Call ended"
        }
    }

    func pendingParticipantLabel(viewerID: String?) -> String {
        let state = status == "accepted" ? "Joining…" : "Calling…"
        return caller.id == viewerID ? state : "\(state) · invited by \(caller.name)"
    }

    func canCancelPendingInvitation(userID: String?) -> Bool { status == "pending" && caller.id == userID }
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
