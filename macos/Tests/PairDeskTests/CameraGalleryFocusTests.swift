import XCTest
@testable import PairDesk

final class CameraGalleryFocusTests: XCTestCase {
    func testLayoutChoicesHaveStablePersistableValues() {
        XCTAssertEqual(CameraGalleryLayout.allCases.map(\.rawValue), ["spotlight", "grid"])
        XCTAssertEqual(CameraGalleryLayout(rawValue: "grid"), .grid)
        XCTAssertEqual(CameraGalleryLayout(rawValue: "unknown"), nil)
    }

    func testPinnedParticipantStaysInSpotlightWhileSpeakerChanges() {
        XCTAssertEqual(
            CameraGalleryFocus.primaryIdentity(
                feedIdentities: ["bharat", "harshit", "akshat"],
                speakingIdentities: ["akshat"],
                pinnedIdentity: "harshit"
            ),
            "harshit"
        )
    }

    func testUnpinnedGalleryFollowsFirstActiveSpeaker() {
        XCTAssertEqual(
            CameraGalleryFocus.primaryIdentity(
                feedIdentities: ["bharat", "harshit", "akshat"],
                speakingIdentities: ["akshat", "harshit"],
                pinnedIdentity: nil
            ),
            "harshit"
        )
    }

    func testMissingPinFallsBackToSpeakerThenFirstFeed() {
        XCTAssertEqual(
            CameraGalleryFocus.primaryIdentity(
                feedIdentities: ["bharat", "akshat"],
                speakingIdentities: ["akshat"],
                pinnedIdentity: "offline"
            ),
            "akshat"
        )
        XCTAssertEqual(
            CameraGalleryFocus.primaryIdentity(
                feedIdentities: ["bharat", "akshat"],
                speakingIdentities: [],
                pinnedIdentity: "offline"
            ),
            "bharat"
        )
        XCTAssertNil(CameraGalleryFocus.primaryIdentity(feedIdentities: [], speakingIdentities: [], pinnedIdentity: nil))
    }

    func testSpeakerFocusStartsWithCurrentSpeakerOrFirstAvailableFeed() {
        var tracker = CameraGalleryFocusTracker()
        XCTAssertEqual(tracker.update(feedIdentities: ["bharat", "harshit"],
                                      speakingIdentities: ["harshit"], pinnedIdentity: nil, now: 1), "harshit")

        var quietTracker = CameraGalleryFocusTracker()
        XCTAssertEqual(quietTracker.update(feedIdentities: ["bharat", "harshit"],
                                           speakingIdentities: [], pinnedIdentity: nil, now: 1), "bharat")
    }

    func testSpeakerSwitchWaitsForStableVoiceActivity() {
        var tracker = CameraGalleryFocusTracker()
        _ = tracker.update(feedIdentities: ["bharat", "harshit"], speakingIdentities: [],
                           pinnedIdentity: nil, now: 1)

        XCTAssertEqual(tracker.update(feedIdentities: ["bharat", "harshit"], speakingIdentities: ["harshit"],
                                      pinnedIdentity: nil, now: 2), "bharat")
        XCTAssertEqual(tracker.update(feedIdentities: ["bharat", "harshit"], speakingIdentities: ["harshit"],
                                      pinnedIdentity: nil, now: 2.64), "bharat")
        XCTAssertEqual(tracker.update(feedIdentities: ["bharat", "harshit"], speakingIdentities: ["harshit"],
                                      pinnedIdentity: nil, now: 2.66), "harshit")
    }

    func testCurrentSpeakerDoesNotYieldToOverlappingSpeakerAndPinIsImmediate() {
        var tracker = CameraGalleryFocusTracker()
        _ = tracker.update(feedIdentities: ["bharat", "harshit"], speakingIdentities: ["bharat"],
                           pinnedIdentity: nil, now: 1)

        XCTAssertEqual(tracker.update(feedIdentities: ["bharat", "harshit"], speakingIdentities: ["bharat", "harshit"],
                                      pinnedIdentity: nil, now: 2), "bharat")
        XCTAssertEqual(tracker.update(feedIdentities: ["bharat", "harshit"], speakingIdentities: [],
                                      pinnedIdentity: "harshit", now: 2.1), "harshit")
    }

    func testFocusFallsBackWhenFocusedCameraLeaves() {
        var tracker = CameraGalleryFocusTracker()
        _ = tracker.update(feedIdentities: ["bharat", "harshit"], speakingIdentities: ["harshit"],
                           pinnedIdentity: nil, now: 1)

        XCTAssertEqual(tracker.update(feedIdentities: ["bharat"], speakingIdentities: [],
                                      pinnedIdentity: nil, now: 2), "bharat")
    }
}
