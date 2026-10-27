import Foundation

/// A bounded text clip used by explicit offers, opt-in sync, and screen control.
///
/// LiveKit delivers reliable data in packets of at most 15 KiB, so one clip is
/// sent as one or more parts that share an id; the receiver reassembles them.
struct ClipboardTransferMessage: Codable, Equatable {
    static let version = 1
    /// The whole clip, across all parts.
    static let maximumTextBytes = 64 * 1024
    /// Text per part. JSON escaping can expand control characters sixfold; the packet must stay
    /// under `maximumWireBytes` with the envelope.
    static let maximumPartTextBytes = 6 * 1024
    static let maximumPartEscapedBytes = 12 * 1024
    /// LiveKit's documented reliable packet ceiling.
    static let maximumWireBytes = 15_000
    static let maximumParts = 33
    static let lifetime: TimeInterval = 120

    let version: Int
    let id: UUID
    let recipientIdentity: String
    let createdAt: Date
    /// Zero-based index of this part and the number of parts in the clip.
    let part: Int
    let parts: Int
    let text: String

    init(id: UUID = UUID(), recipientIdentity: String, createdAt: Date = .now, part: Int = 0, parts: Int = 1, text: String) throws {
        guard !recipientIdentity.isEmpty, recipientIdentity.utf8.count <= 256 else {
            throw ClipboardTransferError.invalidRecipient
        }
        guard !text.isEmpty else { throw ClipboardTransferError.emptyText }
        guard text.utf8.count <= Self.maximumTextBytes else { throw ClipboardTransferError.textTooLarge }
        guard (1...Self.maximumParts).contains(parts), (0..<parts).contains(part) else {
            throw ClipboardTransferError.malformedMessage
        }
        self.version = Self.version
        self.id = id
        self.recipientIdentity = recipientIdentity
        self.createdAt = createdAt
        self.part = part
        self.parts = parts
        self.text = text
    }

    /// Splits one clip into packet-sized parts that share an id.
    static func parts(id: UUID = UUID(), recipientIdentity: String, createdAt: Date = .now, text: String) throws -> [ClipboardTransferMessage] {
        guard !text.isEmpty else { throw ClipboardTransferError.emptyText }
        guard text.utf8.count <= maximumTextBytes else { throw ClipboardTransferError.textTooLarge }
        let chunks = split(text, maximumBytes: maximumPartTextBytes)
        guard chunks.count <= maximumParts else { throw ClipboardTransferError.textTooLarge }
        return try chunks.enumerated().map { index, chunk in
            try ClipboardTransferMessage(id: id, recipientIdentity: recipientIdentity, createdAt: createdAt,
                                         part: index, parts: chunks.count, text: String(chunk))
        }
    }

    /// Cut at Unicode scalar boundaries. A grapheme can be arbitrarily large
    /// (combining marks), but joining the parts still reconstructs it exactly.
    static func split(_ text: String, maximumBytes: Int) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = start
            var bytes = 0
            var escapedBytes = 0
            while end < text.endIndex {
                let next = text.unicodeScalars.index(after: end)
                let size = text.utf8.distance(from: end, to: next)
                let scalar = text.unicodeScalars[end].value
                let escapedSize: Int
                switch scalar {
                case 8, 9, 10, 12, 13, 34, 47, 92: escapedSize = 2
                case 0..<32: escapedSize = 6
                default: escapedSize = size
                }
                if bytes + size > maximumBytes || escapedBytes + escapedSize > maximumPartEscapedBytes { break }
                bytes += size
                escapedBytes += escapedSize
                end = next
            }
            if end == start { end = text.unicodeScalars.index(after: start) }
            result.append(text[start..<end])
            start = end
        }
        return result
    }

    static func decode(_ data: Data, authenticatedSender: String, localIdentity: String,
                       now: Date = .now) throws -> ClipboardTransferMessage {
        guard data.count <= maximumWireBytes else { throw ClipboardTransferError.messageTooLarge }
        let message: ClipboardTransferMessage
        do { message = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ClipboardTransferError.malformedMessage }
        try message.validate(authenticatedSender: authenticatedSender, localIdentity: localIdentity, now: now)
        return message
    }

    func validate(authenticatedSender: String, localIdentity: String, now: Date = .now) throws {
        let message = self
        guard message.version == Self.version else { throw ClipboardTransferError.unsupportedVersion }
        guard !authenticatedSender.isEmpty, authenticatedSender != localIdentity else {
            throw ClipboardTransferError.invalidSender
        }
        guard message.recipientIdentity == localIdentity else { throw ClipboardTransferError.wrongRecipient }
        guard (1...Self.maximumParts).contains(message.parts), (0..<message.parts).contains(message.part),
              !message.text.isEmpty else { throw ClipboardTransferError.malformedMessage }
        guard message.text.utf8.count <= Self.maximumTextBytes else { throw ClipboardTransferError.textTooLarge }
        guard message.createdAt <= now.addingTimeInterval(5),
              now.timeIntervalSince(message.createdAt) <= Self.lifetime else {
            throw ClipboardTransferError.expired
        }
    }

    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumWireBytes else { throw ClipboardTransferError.messageTooLarge }
        return data
    }
}
enum ClipboardTransferError: Error, Equatable, LocalizedError {
    case invalidRecipient
    case emptyText
    case textTooLarge
    case messageTooLarge
    case malformedMessage
    case unsupportedVersion
    case invalidSender
    case wrongRecipient
    case expired
    case replayed

    var errorDescription: String? {
        switch self {
        case .invalidRecipient: "That teammate is no longer in this call."
        case .emptyText: "There is no text in the clipboard."
        case .textTooLarge: "Text is larger than the 64 KB sharing limit."
        case .messageTooLarge: "This text can't be shared: it is too large once encoded."
        case .malformedMessage, .unsupportedVersion, .invalidSender, .wrongRecipient, .expired, .replayed:
            "The clipboard text couldn't be delivered."
        }
    }
}

/// Reassembles multi-part clips per sender and id. Parts normally arrive in
/// order on the reliable channel, but any order is accepted. Incomplete clips
/// are dropped after `ClipboardTransferMessage.lifetime`.
struct ClipboardTransferAssembler {
    struct Key: Hashable {
        let sender: String
        let id: UUID
    }
    private struct Partial {
        var texts: [Int: String] = [:]
        var bytes = 0
        let parts: Int
        let startedAt: Date
    }
    private var partials: [Key: Partial] = [:]
    let capacity: Int

    init(capacity: Int = 16) { self.capacity = max(1, capacity) }

    var pendingCount: Int { partials.count }

    /// Returns the whole clip once every part has arrived.
    mutating func add(_ message: ClipboardTransferMessage, from sender: String, now: Date = .now) -> ClipboardTransferMessage? {
        partials = partials.filter { now.timeIntervalSince($0.value.startedAt) <= ClipboardTransferMessage.lifetime }
        if message.parts == 1 { return message }
        let key = Key(sender: sender, id: message.id)
        var partial = partials[key] ?? Partial(parts: message.parts, startedAt: now)
        guard partial.parts == message.parts, (0..<partial.parts).contains(message.part) else {
            partials[key] = nil
            return nil
        }
        if partial.texts[message.part] == nil {
            partial.bytes += message.text.utf8.count
            partial.texts[message.part] = message.text
        }
        guard partial.bytes <= ClipboardTransferMessage.maximumTextBytes else {
            partials[key] = nil
            return nil
        }
        guard partial.texts.count == partial.parts else {
            if partials[key] == nil, partials.count >= capacity,
               let oldest = partials.min(by: { $0.value.startedAt < $1.value.startedAt }) {
                partials[oldest.key] = nil
            }
            partials[key] = partial
            return nil
        }
        partials[key] = nil
        let text = (0..<partial.parts).compactMap { partial.texts[$0] }.joined()
        return try? ClipboardTransferMessage(id: message.id, recipientIdentity: message.recipientIdentity,
                                             createdAt: message.createdAt, text: text)
    }
}

/// Which pasteboard writes clipboard sync may share. Password managers mark
/// their items concealed; clipboard tools mark restores transient and scripted
/// writes auto-generated. None of those were copied for a teammate.
enum ClipboardSyncPolicy {
    /// Poll only while a call's clipboard sync is opted in. A shorter interval
    /// reduces paste latency and makes quick successive copies less likely to
    /// be coalesced into one observed pasteboard state.
    static let pollInterval = Duration.milliseconds(75)

    static let excludedPasteboardTypes = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
    ]

    static func mayShare(pasteboardTypes: [String]) -> Bool {
        !pasteboardTypes.contains(where: excludedPasteboardTypes.contains)
    }
}

/// Keeps a bounded in-memory replay window. Sender identity comes from the
/// LiveKit callback, never from clipboard JSON supplied by the remote peer.
struct ClipboardTransferReplayWindow {
    private(set) var seen = Set<UUID>()
    private var insertionOrder: [UUID] = []
    let capacity: Int

    init(capacity: Int = 128) { self.capacity = max(1, capacity) }

    mutating func insert(_ id: UUID) -> Bool {
        guard seen.insert(id).inserted else { return false }
        insertionOrder.append(id)
        if insertionOrder.count > capacity {
            seen.remove(insertionOrder.removeFirst())
        }
        return true
    }
}
