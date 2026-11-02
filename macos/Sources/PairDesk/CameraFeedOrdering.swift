import Foundation

/// Keeps the current speaker at the front of camera layouts, with a stable
/// participant order between speaking-state updates. The local preview follows
/// remote feeds when nobody is speaking so it does not take the lead tile.
enum CameraFeedOrdering {
    static func speakersFirst(_ participants: [CallParticipant]) -> [CallParticipant] {
        participants.sorted { lhs, rhs in
            if lhs.isSpeaking != rhs.isSpeaking { return lhs.isSpeaking }
            if lhs.isLocal != rhs.isLocal { return !lhs.isLocal }
            return lhs.identity < rhs.identity
        }
    }
}
