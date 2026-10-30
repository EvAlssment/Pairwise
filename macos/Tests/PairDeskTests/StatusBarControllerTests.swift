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

    func testClickWhoseMouseDownDismissedThePopoverDoesNotReopenIt() {
        // The mouse-down dismissed the popover 80 ms before the mouse-up action ran.
        XCTAssertTrue(StatusBarController.clickDismissedPopover(now: 1000.08, dismissedAt: 1000.0))
        // A dismissal from a click elsewhere a second earlier is unrelated.
        XCTAssertFalse(StatusBarController.clickDismissedPopover(now: 1001.0, dismissedAt: 1000.0))
        // Never dismissed.
        XCTAssertFalse(StatusBarController.clickDismissedPopover(now: 1000.0, dismissedAt: -.infinity))
    }

    func testOutsideDismissalDoesNotSuppressAQuickSubsequentStatusClick() {
        let buttonFrame = NSRect(x: 100, y: 900, width: 25, height: 25)
        XCTAssertTrue(StatusBarController.dismissalWasOnStatusItem(mouseLocation: NSPoint(x: 110, y: 910), buttonFrame: buttonFrame))
        XCTAssertFalse(StatusBarController.dismissalWasOnStatusItem(mouseLocation: NSPoint(x: 400, y: 400), buttonFrame: buttonFrame))
        XCTAssertFalse(StatusBarController.clickDismissedPopover(now: 1000.08, dismissedAt: -.infinity))
    }
}
