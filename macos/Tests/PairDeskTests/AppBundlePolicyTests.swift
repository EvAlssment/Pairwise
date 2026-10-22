import Foundation
import XCTest

final class AppBundlePolicyTests: XCTestCase {
    func testLaunchServicesPreventsMultiplePairDeskInstances() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = sourceRoot.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plistURL)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )

        XCTAssertEqual(propertyList["LSMultipleInstancesProhibited"] as? Bool, true)
    }
}
