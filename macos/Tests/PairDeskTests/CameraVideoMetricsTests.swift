import XCTest
@testable import PairDesk

final class CameraVideoMetricsTests: XCTestCase {
    func testAspectRatioUsesMeasuredGeometryAndSafeFallback() {
        XCTAssertEqual(CameraVideoMetrics(width: 1920, height: 1080).aspectRatio, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(CameraVideoMetrics(width: 640, height: 480).aspectRatio, 4.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(CameraVideoMetrics(width: 720, height: 1280).aspectRatio, 9.0 / 16.0, accuracy: 0.001)
        XCTAssertEqual(CameraVideoMetrics().aspectRatio, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(CameraVideoMetrics(width: 10, height: 100).aspectRatio, 16.0 / 9.0, accuracy: 0.001)
    }

    func testCameraMetricsSummarizeMeasuredDimensionsAndFrameRate() {
        let metrics = CameraVideoMetrics(width: 1_280, height: 720, framesPerSecond: 29.6)
        XCTAssertEqual(metrics.summary, "1280 × 720 · 30 fps")
    }

    func testCameraMetricsKeepUnavailableAndInvalidValuesDistinctFromZero() {
        XCTAssertEqual(CameraVideoMetrics().summary, "Video stats unavailable")
        XCTAssertEqual(CameraVideoMetrics(width: 0, height: 720, framesPerSecond: .infinity).summary,
                       "Video stats unavailable")
        XCTAssertEqual(CameraVideoMetrics(width: 1_920, height: 1_080).summary, "1920 × 1080")
    }
}
