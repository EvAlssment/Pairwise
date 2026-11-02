import Foundation

/// Small, ephemeral call-presence message. The sender identity always comes
/// from LiveKit's authenticated data-packet metadata, never from this payload.
struct CallHandRaiseMessage: Codable, Equatable {
    static let currentVersion = 1
    static let maximumWireBytes = 64

    let version: Int
    let raised: Bool

    init(raised: Bool) {
        version = Self.currentVersion
        self.raised = raised
    }

    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumWireBytes else { throw CallHandRaiseError.messageTooLarge }
        return data
    }

    static func decode(_ data: Data) -> Self? {
        guard !data.isEmpty, data.count <= maximumWireBytes,
              let message = try? JSONDecoder().decode(Self.self, from: data),
              message.version == currentVersion else { return nil }
        return message
    }
}

enum CallHandRaiseError: Error {
    case messageTooLarge
}
