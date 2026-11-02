import XCTest
@testable import PairDesk

final class CameraGalleryParticipantTests: XCTestCase {
    func testCameraOffTeammatesStayInGalleryAndSpeakingParticipantLeads() {
        let participants = [
            CallParticipant(identity: "me", name: "Me", isLocal: true),
            CallParticipant(identity: "zara", name: "Zara", isLocal: false),
            CallParticipant(identity: "alex", name: "Alex", isLocal: false, isSpeaking: true,
                            isMicrophoneMuted: false, isCameraEnabled: true)
        ]

        let gallery = CameraGalleryParticipants.make(participants: participants, feeds: [],
                                                    raisedHandIdentities: ["zara"])

        XCTAssertEqual(gallery.map(\.identity), ["alex", "zara", "me"])
        XCTAssertTrue(gallery.allSatisfy { !$0.hasVideoFeed })
        XCTAssertFalse(gallery[0].isMicrophoneMuted)
        XCTAssertTrue(gallery[0].isCameraEnabled, "A published camera without a subscribed frame should show as starting, not off")
        XCTAssertTrue(gallery[1].isMicrophoneMuted)
        XCTAssertTrue(gallery[2].isLocal)
        XCTAssertTrue(gallery[1].isHandRaised)
        XCTAssertFalse(gallery[0].isHandRaised)
    }

    func testCameraFeedMatchingCannotDropCallParticipants() {
        let participants = [
            CallParticipant(identity: "camera-on", name: "Camera On", isLocal: false, isCameraEnabled: true),
            CallParticipant(identity: "camera-off", name: "Camera Off", isLocal: false)
        ]

        let gallery = CameraGalleryParticipants.make(participants: participants, feeds: [])

        XCTAssertEqual(Set(gallery.map(\.identity)), ["camera-on", "camera-off"])
        XCTAssertEqual(gallery.first(where: { $0.identity == "camera-on" })?.isCameraEnabled, true)
    }
}
