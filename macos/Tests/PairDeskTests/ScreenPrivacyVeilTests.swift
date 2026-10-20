import XCTest
@testable import PairDesk

final class ScreenPrivacyVeilTests: XCTestCase {
    func testOnlyEnumeratedApplicationIdentifiersCanBeExcluded() {
        let selected = PrivacyVeilSelection.resolve(
            ["com.example.private", "com.example.not-running"],
            availableBundleIDs: ["com.example.private", "com.example.editor"]
        )

        XCTAssertEqual(selected, ["com.example.private"])
    }

    func testEmptySelectionKeepsTheDisplayUnfiltered() {
        XCTAssertTrue(PrivacyVeilSelection.resolve([], availableBundleIDs: ["com.example.editor"]).isEmpty)
    }
}
