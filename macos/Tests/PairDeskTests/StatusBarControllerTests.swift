import AppKit
import XCTest
@testable import PairDesk

final class StatusBarControllerTests: XCTestCase {
    private func click(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    func testRightClickAndControlClickOpenTheStatusMenu() {
        XCTAssertTrue(StatusBarController.opensMenu(click(.rightMouseUp)))
        XCTAssertTrue(StatusBarController.opensMenu(click(.leftMouseUp, modifiers: .control)))
    }

    func testPlainClickAndCodeDrivenOpenUseThePopover() {
        XCTAssertFalse(StatusBarController.opensMenu(click(.leftMouseUp)))
        XCTAssertFalse(StatusBarController.opensMenu(click(.leftMouseUp, modifiers: .command)))
        XCTAssertFalse(StatusBarController.opensMenu(nil))
    }
}
