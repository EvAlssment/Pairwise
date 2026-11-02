import XCTest
@testable import PairDesk

final class ScreenShareQualityTests: XCTestCase {
    func testSenderMetricsReportActualOutputAndEncoderConstraint() {
        XCTAssertEqual(
            ScreenShareSenderMetrics(width: 3_840, height: 2_160, framesPerSecond: 30,
                                     bitrateMegabitsPerSecond: 8.25,
                                     limitation: .bandwidth).summary,
            "3840 × 2160 · 30 fps · 8.2 Mbps · network constrained"
        )
        XCTAssertEqual(
            ScreenShareSenderMetrics(width: 1_920, height: 1_080, framesPerSecond: 24,
                                     bitrateMegabitsPerSecond: 2.4,
                                     limitation: .cpu).summary,
            "1920 × 1080 · 24 fps · 2.4 Mbps · Mac load constrained"
        )
        XCTAssertEqual(ScreenShareSenderMetrics().summary, "Measuring outbound video")
        XCTAssertEqual(ScreenShareSenderMetrics(width: 0, height: 2_160, framesPerSecond: .infinity).summary,
                       "Measuring outbound video")
        XCTAssertNil(ScreenShareSenderMetrics(bitrateMegabitsPerSecond: .infinity).bitrateMegabitsPerSecond)
    }

    func testSenderReportContainsOnlyReviewableTechnicalMeasurements() {
        let report = ScreenShareSenderReport.text(
            metrics: ScreenShareSenderMetrics(width: 3_840, height: 2_160,
                                               framesPerSecond: 30,
                                               bitrateMegabitsPerSecond: 8.2,
                                               limitation: .bandwidth),
            maximum: .sharp,
            adaptiveQualityEnabled: true,
            localProcessCPU: ScreenShareProcessCPUUsage(averagePercent: 24,
                                                        peakPercent: 36,
                                                        durationSeconds: 10)
        )

        XCTAssertTrue(report.contains("Encoder output: 3840 × 2160 · 30 fps · 8.2 Mbps · network constrained"))
        XCTAssertTrue(report.contains("Selected maximum: Sharp · 4K"))
        XCTAssertTrue(report.contains("Adaptive quality: on"))
        XCTAssertTrue(report.contains("avg 24% · peak 36% · 10s"))
        XCTAssertTrue(report.contains("no account names, screen content, or network addresses"))
        XCTAssertFalse(report.localizedCaseInsensitiveContains("email"))
        XCTAssertFalse(report.localizedCaseInsensitiveContains("token"))
    }

    func testSenderBitrateUsesByteCounterDeltaAndNeedsTwoSamples() {
        var estimator = ScreenShareBitrateEstimator()
        XCTAssertNil(estimator.sample(byteCount: 1_000, at: 10))
        XCTAssertEqual(try XCTUnwrap(estimator.sample(byteCount: 2_000_000, at: 11)), 15.992, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(estimator.sample(byteCount: 3_000_000, at: 12)), 8.0, accuracy: 0.001)
    }

    func testSenderBitrateDropsStaleOrResetCountersAndRebases() {
        var estimator = ScreenShareBitrateEstimator()
        XCTAssertNil(estimator.sample(byteCount: 10_000, at: 10))
        XCTAssertNil(estimator.sample(byteCount: 20_000, at: 10))
        XCTAssertNil(estimator.sample(byteCount: 2_000, at: 11), "counter reset starts a fresh measurement window")
        XCTAssertEqual(try XCTUnwrap(estimator.sample(byteCount: 1_002_000, at: 12)), 8.0, accuracy: 0.001)
        XCTAssertNil(estimator.sample(byteCount: nil, at: 13))
        XCTAssertNil(estimator.sample(byteCount: 2_000_000, at: 14), "missing stats clear the previous baseline")
    }

    func testQualityHistoryKeepsOnlyLatestMinuteAndSummarizesLatency() {
        var history = ScreenQualityHistory()
        for second in 0..<65 {
            history.record(ScreenQualitySample(uptimeSeconds: Double(second),
                                               roundTripMilliseconds: second,
                                               framesPerSecond: 30,
                                               packetLossPercent: 0.5))
        }

        XCTAssertEqual(history.samples.count, 60)
        XCTAssertEqual(history.samples.first?.uptimeSeconds, 5)
        XCTAssertEqual(history.medianRoundTripMilliseconds, 34)
        XCTAssertEqual(history.peakRoundTripMilliseconds, 64)
        XCTAssertEqual(history.summary, "RTT median 34 ms · peak 64 ms · 60 readings")
    }

    func testQualityHistoryRejectsInvalidAndOutOfOrderSamplesAndShowsGaps() {
        var history = ScreenQualityHistory()
        history.record(ScreenQualitySample(uptimeSeconds: 10, roundTripMilliseconds: 80,
                                           framesPerSecond: 30, packetLossPercent: 1))
        history.record(ScreenQualitySample(uptimeSeconds: 9, roundTripMilliseconds: 20,
                                           framesPerSecond: 30, packetLossPercent: 1))
        history.record(ScreenQualitySample(uptimeSeconds: 11, roundTripMilliseconds: nil,
                                           framesPerSecond: nil, packetLossPercent: nil))
        history.record(ScreenQualitySample(uptimeSeconds: 12, roundTripMilliseconds: -1,
                                           framesPerSecond: 30, packetLossPercent: 1))
        history.record(ScreenQualitySample(uptimeSeconds: 80, roundTripMilliseconds: 95,
                                           framesPerSecond: 30, packetLossPercent: 1))

        XCTAssertEqual(history.samples.count, 1, "samples older than the one-minute window expire")
        XCTAssertEqual(history.roundTripReadings, [95])
        XCTAssertEqual(history.chartCeilingMilliseconds, 150)
        history.reset()
        XCTAssertTrue(history.samples.isEmpty)
        XCTAssertEqual(history.summary, "RTT unavailable")
    }

    func testReceivedStreamMetricsFormatMeasuredResolutionFrameRateBitrateAndLoss() {
        let metrics = ScreenStreamMetrics(width: 2_560,
                                          height: 1_440,
                                          framesPerSecond: 29.6,
                                          bitrateMegabitsPerSecond: 4.75,
                                          packetsReceived: 9_900,
                                          packetsLost: 100)
        XCTAssertEqual(metrics.width, 2_560)
        XCTAssertEqual(metrics.height, 1_440)
        XCTAssertEqual(metrics.framesPerSecond, 30)
        XCTAssertEqual(metrics.bitrateMegabitsPerSecond, 4.75)
        XCTAssertEqual(try XCTUnwrap(metrics.packetLossPercent), 1.0, accuracy: 0.0001)
        XCTAssertEqual(metrics.summary, "2560 × 1440 · 30 fps · 4.8 Mbps · 1.0% loss")
    }

    func testReceivedStreamMetricsOmitInvalidOrUnavailableValues() {
        XCTAssertEqual(ScreenStreamMetrics().summary, "Stream stats unavailable")
        XCTAssertEqual(ScreenStreamMetrics(width: 0, height: 1, framesPerSecond: .infinity).summary,
                       "Stream stats unavailable")
        XCTAssertNil(ScreenStreamMetrics(bitrateMegabitsPerSecond: .infinity).bitrateMegabitsPerSecond)
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

    func testPresetSelectionPersistsAndInvalidStoredValueFallsBackToFourKMaximum() {
        let suiteName = "ScreenShareQualityTests.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(ScreenShareQuality.load(from: defaults), .sharp)
        ScreenShareQuality.sharp.persist(to: defaults)
        XCTAssertEqual(ScreenShareQuality.load(from: defaults), .sharp)

        defaults.set("unknown-quality", forKey: ScreenShareQuality.defaultsKey)
        XCTAssertEqual(ScreenShareQuality.load(from: defaults), .sharp)
    }

    func testDefaultScreenShareMaximumIsFourKAtThirtyFrames() {
        XCTAssertEqual(ScreenShareQuality.defaultValue, .sharp)
        XCTAssertEqual(ScreenShareQuality.defaultValue.dimensions.width, 3_840)
        XCTAssertEqual(ScreenShareQuality.defaultValue.framesPerSecond, 30)
        XCTAssertEqual(AdaptiveShareController(maximum: .sharp).current, .fourK)
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
