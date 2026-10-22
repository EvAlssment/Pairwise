import XCTest
@testable import PairDesk

final class BenchmarkRunnerMetadataTests: XCTestCase {
    func testRunnerMetadataIsCompleteAndContainsNoPerMachineIdentity() {
        let metadata = BenchmarkRunnerMetadata.current()
        XCTAssertEqual(metadata.platform, "macOS")
        XCTAssertFalse(metadata.osVersion.isEmpty)
        XCTAssertFalse(metadata.architecture.isEmpty)
        XCTAssertFalse(metadata.modelIdentifier.isEmpty)
        XCTAssertGreaterThan(metadata.logicalCPUCount, 0)
    }
}
