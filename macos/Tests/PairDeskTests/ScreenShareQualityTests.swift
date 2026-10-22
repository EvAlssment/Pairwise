import XCTest
@testable import PairDesk

final class ScreenShareQualityTests: XCTestCase {
    func testReceivedStreamMetricsFormatMeasuredResolutionFrameRateAndLoss() {
        let metrics = ScreenStreamMetrics(width: 2_560,
                                          height: 1_440,
                                          framesPerSecond: 29.6,
                                          packetsReceived: 9_900,
                                          packetsLost: 100)
        XCTAssertEqual(metrics.width, 2_560)
        XCTAssertEqual(metrics.height, 1_440)
        XCTAssertEqual(metrics.framesPerSecond, 30)
        XCTAssertEqual(try XCTUnwrap(metrics.packetLossPercent), 1.0, accuracy: 0.0001)
        XCTAssertEqual(metrics.summary, "2560 × 1440 · 30 fps · 1.0% loss")
    }

    func testReceivedStreamMetricsOmitInvalidOrUnavailableValues() {
        XCTAssertEqual(ScreenStreamMetrics().summary, "Stream stats unavailable")
        XCTAssertEqual(ScreenStreamMetrics(width: 0, height: 1, framesPerSecond: .infinity).summary,
                       "Stream stats unavailable")
        XCTAssertNil(ScreenStreamMetrics(packetsReceived: 10, packetsLost: -1).packetLossPercent)
        XCTAssertNil(ScreenStreamMetrics(packetsReceived: UInt64.max, packetsLost: 1).packetLossPercent)
    }

    func testPresetsMapToRequestedResolutionFrameRateAndBitrate() {
        XCTAssertEqual(ScreenShareQuality.fast.width, 1_920)
        XCTAssertEqual(ScreenShareQuality.fast.height, 1_080)
        XCTAssertEqual(ScreenShareQuality.fast.framesPerSecond, 30)
        XCTAssertEqual(ScreenShareQuality.fast.maxBitrate, 3_000_000)

        XCTAssertEqual(ScreenShareQuality.balanced.width, 2_560)
        XCTAssertEqual(ScreenShareQuality.balanced.height, 1_440)
        XCTAssertEqual(ScreenShareQuality.balanced.framesPerSecond, 30)
        XCTAssertEqual(ScreenShareQuality.balanced.maxBitrate, 5_000_000)

        XCTAssertEqual(ScreenShareQuality.sharp.width, 3_840)
        XCTAssertEqual(ScreenShareQuality.sharp.height, 2_160)
        XCTAssertEqual(ScreenShareQuality.sharp.framesPerSecond, 30)
        XCTAssertEqual(ScreenShareQuality.sharp.maxBitrate, 8_000_000)
    }

    func testPresetSelectionPersistsAndInvalidStoredValueFallsBackToBalanced() {
        let suiteName = "ScreenShareQualityTests.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(ScreenShareQuality.load(from: defaults), .balanced)
        ScreenShareQuality.sharp.persist(to: defaults)
        XCTAssertEqual(ScreenShareQuality.load(from: defaults), .sharp)

        defaults.set("unknown-quality", forKey: ScreenShareQuality.defaultsKey)
        XCTAssertEqual(ScreenShareQuality.load(from: defaults), .balanced)
    }

    func testRTTUsesExactlyTheSelectedCandidatePair() {
        let pairs = [
            CandidatePairRTT(id: "selected-relay", roundTripTimeSeconds: 0.24),
            CandidatePairRTT(id: "unused-direct-probe", roundTripTimeSeconds: 0.02),
        ]

        let selectedRTT = ScreenNetworkQuality.selectedRoundTripTimeSeconds(
            selectedPairID: "selected-relay",
            pairs: pairs
        )
        XCTAssertEqual(selectedRTT, 0.24)
        XCTAssertEqual(ScreenNetworkQuality.from(roundTripTimeSeconds: selectedRTT), .fair(roundTripMilliseconds: 240))
    }

    func testRTTIsUnavailableWhenTransportHasNoMatchingSelectedPair() {
        let pairs = [CandidatePairRTT(id: "candidate-a", roundTripTimeSeconds: 0.01)]
        XCTAssertNil(ScreenNetworkQuality.selectedRoundTripTimeSeconds(selectedPairID: nil, pairs: pairs))
        XCTAssertNil(ScreenNetworkQuality.selectedRoundTripTimeSeconds(selectedPairID: "candidate-b", pairs: pairs))
        XCTAssertEqual(ScreenNetworkQuality.from(roundTripTimeSeconds: nil), .measuring)
    }

    func testAdaptiveQualityOnlyReducesBelowTheSelectedMaximumAndRecoversWithHysteresis() {
        var controller = AdaptiveShareController(maximum: .sharp)
        XCTAssertEqual(controller.current, .fourK)
        XCTAssertNil(controller.observe(.init(availableOutgoingBitrate: nil, bandwidthLimited: false, cpuLimited: false)))

        let constrained = AdaptiveShareSignal(availableOutgoingBitrate: 2_000_000, bandwidthLimited: true, cpuLimited: false)
        XCTAssertNil(controller.observe(constrained))
        XCTAssertNil(controller.observe(constrained))
        XCTAssertEqual(controller.observe(constrained), .q1440)
        XCTAssertEqual(controller.current.dimensions.width, 2_560)
        XCTAssertEqual(controller.current.fps, 30)

        let healthy = AdaptiveShareSignal(availableOutgoingBitrate: 12_000_000, bandwidthLimited: false, cpuLimited: false,
                                         receiversHealthy: true)
        for _ in 0..<7 { XCTAssertNil(controller.observe(healthy)) }
        XCTAssertEqual(controller.observe(healthy), .fourK)
        XCTAssertEqual(controller.current.dimensions.width, 3_840)
        XCTAssertEqual(controller.current.fps, 30)
    }

    func testRecoveryNeedsHeadroomAboveTheHigherTiersStepDownBand() {
        var controller = AdaptiveShareController(maximum: .sharp)
        let constrained = AdaptiveShareSignal(availableOutgoingBitrate: 2_000_000, bandwidthLimited: true, cpuLimited: false)
        for _ in 0..<2 { XCTAssertNil(controller.observe(constrained)) }
        XCTAssertEqual(controller.observe(constrained), .q1440)

        // 8.5 Mbps clears 1440p's own budget but sits inside 4K's step-down band
        // (below 8 Mbps × 1.15), so it must not count as recovery.
        let marginal = AdaptiveShareSignal(availableOutgoingBitrate: 8_500_000, bandwidthLimited: false, cpuLimited: false,
                                          receiversHealthy: true)
        for _ in 0..<12 { XCTAssertNil(controller.observe(marginal)) }
        XCTAssertEqual(controller.current, .q1440)

        let roomy = AdaptiveShareSignal(availableOutgoingBitrate: 10_500_000, bandwidthLimited: false, cpuLimited: false,
                                       receiversHealthy: true)
        for _ in 0..<7 { XCTAssertNil(controller.observe(roomy)) }
        XCTAssertEqual(controller.observe(roomy), .fourK)
        XCTAssertNil(controller.observe(roomy), "10.5 Mbps is above 4K's step-down threshold, so it stays")
    }

    func testAdaptiveQualityCountsEachReceiverFeedbackReportOnlyOnce() {
        var controller = AdaptiveShareController(maximum: .sharp)
        let firstPoorReport = AdaptiveShareSignal(availableOutgoingBitrate: nil,
                                                  bandwidthLimited: false,
                                                  cpuLimited: false,
                                                  receiverLimited: true,
                                                  receiverFeedbackRevision: 1)

        XCTAssertNil(controller.observe(firstPoorReport))
        for _ in 0..<10 { XCTAssertNil(controller.observe(firstPoorReport)) }
        XCTAssertEqual(controller.poorSamples, 1, "polling one stale report must not multiply its weight")
        XCTAssertEqual(controller.current, .fourK)

        let secondPoorReport = AdaptiveShareSignal(availableOutgoingBitrate: nil,
                                                   bandwidthLimited: false,
                                                   cpuLimited: false,
                                                   receiverLimited: true,
                                                   receiverFeedbackRevision: 2)
        XCTAssertNil(controller.observe(secondPoorReport))
        XCTAssertNil(controller.observe(secondPoorReport))
        XCTAssertEqual(controller.poorSamples, 2)

        let thirdPoorReport = AdaptiveShareSignal(availableOutgoingBitrate: nil,
                                                  bandwidthLimited: false,
                                                  cpuLimited: false,
                                                  receiverLimited: true,
                                                  receiverFeedbackRevision: 3)
        XCTAssertEqual(controller.observe(thirdPoorReport), .q1440)
    }

    func testAdaptiveQualityNeverFallsBelow1080p30AndNeverExceedsFourK30() {
        let balanced = AdaptiveShareController(maximum: .balanced)
        XCTAssertEqual(balanced.current, .q1440)
        XCTAssertFalse(AdaptiveShareTier.tiers(maximum: .fast).contains(.fourK))
        XCTAssertEqual(AdaptiveShareTier.tiers(maximum: .fast), [.q1080])
        XCTAssertFalse(AdaptiveShareTier.allCases.contains { $0.dimensions.height < 1_080 || $0.fps < 30 })
        XCTAssertTrue(AdaptiveShareTier.allCases.allSatisfy { $0.fps <= 30 && $0.dimensions.width <= 3_840 })

        var constrained = AdaptiveShareController(maximum: .sharp)
        let poor = AdaptiveShareSignal(availableOutgoingBitrate: 500_000,
                                      bandwidthLimited: true,
                                      cpuLimited: true,
                                      receiverLimited: true)
        for _ in 0..<3 { _ = constrained.observe(poor) }
        XCTAssertEqual(constrained.current, .q1440)
        for _ in 0..<3 { _ = constrained.observe(poor) }
        XCTAssertEqual(constrained.current, .q1080)
        for _ in 0..<9 { _ = constrained.observe(poor) }
        XCTAssertEqual(constrained.current, .q1080, "congestion must not silently reduce the stream below 1080p30")
    }
}
