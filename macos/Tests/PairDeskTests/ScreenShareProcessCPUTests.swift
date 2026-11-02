import XCTest
@testable import PairDesk

final class ScreenShareProcessCPUTests: XCTestCase {
    func testCaptureReadsMonotonicProcessCPUAndUptime() throws {
        let first = try XCTUnwrap(ProcessCPUReading.capture())
        let second = try XCTUnwrap(ProcessCPUReading.capture())
        XCTAssertTrue(first.isValid)
        XCTAssertGreaterThan(second.uptimeSeconds, first.uptimeSeconds)
        XCTAssertGreaterThanOrEqual(second.cpuSeconds, first.cpuSeconds)
    }

    func testUsageEstimatesPercentOfOneCoreAndSummarizesWindow() {
        var window = ScreenShareProcessCPUWindow()
        window.observe(ProcessCPUReading(uptimeSeconds: 10, cpuSeconds: 100))
        XCTAssertEqual(window.usage, .unavailable)

        window.observe(ProcessCPUReading(uptimeSeconds: 11, cpuSeconds: 101.25))
        window.observe(ProcessCPUReading(uptimeSeconds: 12, cpuSeconds: 102.05))

        XCTAssertEqual(window.usage.averagePercent ?? -1, 102.5, accuracy: 0.001)
        XCTAssertEqual(window.usage.peakPercent ?? -1, 125, accuracy: 0.001)
        XCTAssertEqual(window.usage.durationSeconds, 2)
        XCTAssertEqual(window.usage.summary, "avg 102% · peak 125% · 2s")
    }

    func testAverageWeightsUnevenSamplingIntervalsByTheirWallDuration() {
        var window = ScreenShareProcessCPUWindow()
        window.observe(ProcessCPUReading(uptimeSeconds: 10, cpuSeconds: 100))
        window.observe(ProcessCPUReading(uptimeSeconds: 11, cpuSeconds: 101))
        window.observe(ProcessCPUReading(uptimeSeconds: 14, cpuSeconds: 101.3))

        XCTAssertEqual(window.usage.averagePercent ?? -1, 32.5, accuracy: 0.001)
        XCTAssertEqual(window.usage.peakPercent ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(window.usage.durationSeconds, 4)
    }

    func testWindowDropsOldSamplesAndKeepsOnlyRecentBoundedReadings() {
        var window = ScreenShareProcessCPUWindow()
        for second in 0...25 {
            window.observe(ProcessCPUReading(uptimeSeconds: Double(second), cpuSeconds: Double(second)))
        }

        XCTAssertEqual(window.usage.averagePercent ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(window.usage.peakPercent ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(window.usage.durationSeconds, 15)
    }

    func testCounterResetAndLongGapRebaseWithoutInventingCPUUsage() {
        var window = ScreenShareProcessCPUWindow()
        window.observe(ProcessCPUReading(uptimeSeconds: 1, cpuSeconds: 3))
        window.observe(ProcessCPUReading(uptimeSeconds: 2, cpuSeconds: 4))
        XCTAssertNotNil(window.usage.averagePercent)

        window.observe(ProcessCPUReading(uptimeSeconds: 3, cpuSeconds: 1))
        XCTAssertEqual(window.usage, .unavailable)
        window.observe(ProcessCPUReading(uptimeSeconds: 20, cpuSeconds: 10))
        XCTAssertEqual(window.usage, .unavailable)
        window.observe(ProcessCPUReading(uptimeSeconds: 21, cpuSeconds: 10.5))
        XCTAssertEqual(window.usage.averagePercent ?? -1, 50, accuracy: 0.001)

        window.observe(nil)
        XCTAssertEqual(window.usage, .unavailable)
    }
}
