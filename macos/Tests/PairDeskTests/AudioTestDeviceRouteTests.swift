import XCTest
@testable import PairDesk

final class AudioTestDeviceRouteTests: XCTestCase {
    func testSystemDefaultDoesNotRequireAResolvedCoreAudioDevice() {
        XCTAssertEqual(AudioTestDeviceRoute.resolve(isDefault: true, explicitDeviceID: nil), .systemDefault)
    }

    func testExplicitDeviceUsesItsResolvedCoreAudioID() {
        XCTAssertEqual(AudioTestDeviceRoute.resolve(isDefault: false, explicitDeviceID: 42), .device(42))
    }

    func testMissingExplicitDeviceCannotBeTested() {
        XCTAssertNil(AudioTestDeviceRoute.resolve(isDefault: false, explicitDeviceID: nil))
    }

    func testSystemDefaultIgnoresAnExplicitDeviceID() {
        XCTAssertEqual(AudioTestDeviceRoute.resolve(isDefault: true, explicitDeviceID: 42), .systemDefault)
    }
}
