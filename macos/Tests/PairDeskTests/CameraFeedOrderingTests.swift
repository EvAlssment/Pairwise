import XCTest
@testable import PairDesk

final class CameraFeedOrderingTests: XCTestCase {
    func testSpeakingParticipantsLeadAndRemainingFeedsHaveStableOrder() {
        let participants = [
            CallParticipant(identity: "me", name: "Me", isLocal: true),
            CallParticipant(identity: "zara", name: "Zara", isLocal: false),
            CallParticipant(identity: "bharat", name: "Bharat", isLocal: false, isSpeaking: true),
            CallParticipant(identity: "aman", name: "Aman", isLocal: false)
        ]

        let ordered = CameraFeedOrdering.speakersFirst(participants)

        XCTAssertEqual(ordered.map(\.identity), ["bharat", "aman", "zara", "me"])
    }

    func testSimultaneousSpeakersUseStableIdentityOrder() {
        let participants = [
            CallParticipant(identity: "zara", name: "Zara", isLocal: false, isSpeaking: true),
            CallParticipant(identity: "aman", name: "Aman", isLocal: false, isSpeaking: true)
        ]

        XCTAssertEqual(CameraFeedOrdering.speakersFirst(participants).map(\.identity), ["aman", "zara"])
    }
}
