import XCTest
@testable import PairDesk

final class ControlChannelLatencyTests: XCTestCase {
    func testReportsMedianAndLatestFromRecentSamples() {
        var metrics = ControlChannelLatency()
        XCTAssertEqual(metrics.summary(at: 0), "Measuring")

        [100, 40, 60].enumerated().forEach { index, sample in
            metrics.record(milliseconds: sample, at: TimeInterval(index + 1))
        }

        XCTAssertEqual(metrics.medianMilliseconds, 60)
        XCTAssertEqual(metrics.latestMilliseconds, 60)
        XCTAssertEqual(metrics.summary(at: 3), "median 60 ms · latest 60 ms · 3 samples")
        XCTAssertEqual(metrics.summary(at: 14), "No recent response · median 60 ms")
    }

    func testKeepsOnlyFiveSamplesAndRejectsInvalidValues() {
        var metrics = ControlChannelLatency()
        [-1, 60_001].forEach { metrics.record(milliseconds: $0) }
        XCTAssertNil(metrics.medianMilliseconds)

        [500, 100, 200, 300, 400, 250].enumerated().forEach { index, sample in
            metrics.record(milliseconds: sample, at: TimeInterval(index + 1))
        }

        XCTAssertEqual(metrics.medianMilliseconds, 250)
        XCTAssertEqual(metrics.latestMilliseconds, 250)
        XCTAssertEqual(metrics.summary(at: 6), "median 250 ms · latest 250 ms · 5 samples")
    }

    func testResetClearsCallScopedMeasurements() {
        var metrics = ControlChannelLatency()
        metrics.record(milliseconds: 85, at: 1)
        metrics.reset()

        XCTAssertEqual(metrics, ControlChannelLatency())
    }
}
