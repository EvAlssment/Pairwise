import Foundation

enum CallRosterOrdering {
    static func raisedHandsFirst(_ participants: [CallParticipant], raisedHandIdentities: Set<String>) -> [CallParticipant] {
        participants.sorted { lhs, rhs in
            let lhsRaised = raisedHandIdentities.contains(lhs.identity)
            let rhsRaised = raisedHandIdentities.contains(rhs.identity)
            if lhsRaised != rhsRaised { return lhsRaised }
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.identity < rhs.identity
        }
    }
}
