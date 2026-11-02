import XCTest
@testable import PairDesk

final class AudioQualityWindowTests: XCTestCase {
    func testPacketLossUsesCounterDeltasInsteadOfLifetimeTotals() throws {
        var window = AudioQualityWindow()
        let first = window.record(streamID: "track-1", packetsReceived: 1_000, packetsLost: 0,
                                  jitterSeconds: 0.020, at: 10)
        XCTAssertNil(first?.packetLossPercent)
        XCTAssertEqual(first?.jitterMilliseconds, 20)

        let degraded = try XCTUnwrap(window.record(streamID: "track-1", packetsReceived: 1_990, packetsLost: 10,
                                                   jitterSeconds: 0.022, at: 12))
        XCTAssertEqual(try XCTUnwrap(degraded.packetLossPercent), 1.0, accuracy: 0.001)

        let recovered = try XCTUnwrap(window.record(streamID: "track-1", packetsReceived: 2_990, packetsLost: 10,
                                                    jitterSeconds: 0.021, at: 14))
        XCTAssertEqual(try XCTUnwrap(recovered.packetLossPercent), 0.5, accuracy: 0.001)
    }

    func testRecentWindowDropsOldLossAndUsesMedianJitter() throws {
        var window = AudioQualityWindow(windowDuration: 10)
        _ = window.record(streamID: "track-1", packetsReceived: 1_000, packetsLost: 0,
                          jitterSeconds: 0.020, at: 0)
        _ = window.record(streamID: "track-1", packetsReceived: 1_090, packetsLost: 10,
                          jitterSeconds: 0.022, at: 2)
        _ = window.record(streamID: "track-1", packetsReceived: 2_090, packetsLost: 10,
                          jitterSeconds: 0.020, at: 4)
        let transientSpike = try XCTUnwrap(window.record(streamID: "track-1", packetsReceived: 3_090,
                                                        packetsLost: 10, jitterSeconds: 0.100, at: 6))
        XCTAssertEqual(transientSpike.jitterMilliseconds, 21, "one jitter spike should not trigger a sustained warning")

        let recovered = try XCTUnwrap(window.record(streamID: "track-1", packetsReceived: 7_090,
                                                    packetsLost: 10, jitterSeconds: 0.020, at: 12.1))
        XCTAssertEqual(try XCTUnwrap(recovered.packetLossPercent), 0, accuracy: 0.001,
                       "loss samples older than the rolling window are discarded")
        XCTAssertEqual(recovered.jitterMilliseconds, 20)
    }

    func testCounterResetRebasesAndMissingStatsCanClearTrackState() throws {
        var window = AudioQualityWindow()
        _ = window.record(streamID: "track-1", packetsReceived: 5_000, packetsLost: 30,
                          jitterSeconds: 0.020, at: 1)
        let reset = try XCTUnwrap(window.record(streamID: "track-1", packetsReceived: 10, packetsLost: 0,
                                                jitterSeconds: 0.060, at: 3))
        XCTAssertNil(reset.packetLossPercent)
        XCTAssertEqual(reset.jitterMilliseconds, 40, "the recent jitter median includes the prior sample")

        window.reset(streamID: "track-1")
        XCTAssertNil(window.record(streamID: "track-1", packetsReceived: 100, packetsLost: 0,
                                   jitterSeconds: nil, at: 5))
    }

    func testWarningWaitsForThreeSamplesToAvoidFirstSampleSpike() throws {
        var window = AudioQualityWindow()
        let first = try XCTUnwrap(window.record(streamID: "track-1", packetsReceived: 100, packetsLost: 0,
                                                jitterSeconds: 0.080, at: 0))
        XCTAssertNil(first.warningSummary)
        let second = try XCTUnwrap(window.record(streamID: "track-1", packetsReceived: 200, packetsLost: 0,
                                                 jitterSeconds: 0.080, at: 2))
        XCTAssertNil(second.warningSummary)
        let third = try XCTUnwrap(window.record(streamID: "track-1", packetsReceived: 300, packetsLost: 0,
                                                jitterSeconds: 0.080, at: 4))
        XCTAssertEqual(third.warningSummary, "80 ms jitter")
    }

    func testParticipantWarningAggregationIgnoresTracksWithFewerThanThreeSamples() {
        let warmingTrack = AudioStreamQualityMetrics(packetLossPercent: nil, jitterMilliseconds: 90,
                                                     windowSampleCount: 1)
        let warmedTrack = AudioStreamQualityMetrics(packetLossPercent: 0.5, jitterMilliseconds: 50,
                                                    windowSampleCount: 3)
        XCTAssertNil(AudioQualitySummary(streams: [warmingTrack]).warningMetrics?.warningSummary)

        let summary = AudioQualitySummary(streams: [warmedTrack, warmingTrack])
        XCTAssertEqual(summary.warningMetrics?.warningSummary, "50 ms jitter")
        XCTAssertEqual(summary.warningMetrics?.windowSampleCount, 3)
    }
}
