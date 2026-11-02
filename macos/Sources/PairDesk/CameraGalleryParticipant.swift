import Foundation

struct CameraGalleryParticipant: Identifiable {
    let identity: String
    let name: String
    let feed: CameraFeed?
    let isSpeaking: Bool
    let isMicrophoneMuted: Bool
    let isLocal: Bool
    let isCameraEnabled: Bool
    let isHandRaised: Bool

    var id: String { identity }
    var hasVideoFeed: Bool { if case .some = feed { return true }; return false }
}

enum CameraGalleryParticipants {
    static func make(participants: [CallParticipant], feeds: [CameraFeed],
                     raisedHandIdentities: Set<String> = []) -> [CameraGalleryParticipant] {
        let feedsByIdentity = Dictionary(uniqueKeysWithValues: feeds.map { ($0.identity, $0) })
        return CameraFeedOrdering.speakersFirst(participants).map { person in
            let feed = person.isCameraEnabled ? feedsByIdentity[person.identity] : nil
            return CameraGalleryParticipant(identity: person.identity,
                                            name: person.name,
                                            feed: feed,
                                            isSpeaking: person.isSpeaking,
                                            isMicrophoneMuted: person.isMicrophoneMuted,
                                            isLocal: person.isLocal,
                                            isCameraEnabled: person.isCameraEnabled,
                                            isHandRaised: raisedHandIdentities.contains(person.identity))
        }
    }
}
