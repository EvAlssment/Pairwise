import XCTest
@testable import PairDesk

final class CallRosterOrderingTests: XCTestCase {
    func testRaisedHandsMoveToTopAndKeepStableNameOrder() {
        let people = [
            CallParticipant(identity: "zara", name: "Zara", isLocal: false),
            CallParticipant(identity: "alex", name: "Alex", isLocal: false),
            CallParticipant(identity: "ben", name: "Ben", isLocal: false),
            CallParticipant(identity: "a2", name: "Alex", isLocal: false)
        ]

        let ordered = CallRosterOrdering.raisedHandsFirst(people, raisedHandIdentities: ["zara", "a2"])

        XCTAssertEqual(ordered.map(\.identity), ["a2", "zara", "alex", "ben"])
    }

    func testRosterFallsBackToStableNameOrderWhenNoHandsAreRaised() {
        let people = [
            CallParticipant(identity: "zara", name: "Zara", isLocal: false),
            CallParticipant(identity: "ben", name: "Ben", isLocal: false),
            CallParticipant(identity: "alex", name: "Alex", isLocal: false)
        ]

        XCTAssertEqual(CallRosterOrdering.raisedHandsFirst(people, raisedHandIdentities: []).map(\.identity),
                       ["alex", "ben", "zara"])
    }
}
