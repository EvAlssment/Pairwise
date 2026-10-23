import AppKit
import SwiftUI
import XCTest
@testable import PairDesk

@MainActor
final class ScreenShareIndicatorTests: XCTestCase {
    func testCaptureCoordinatesMapDisplayOffsetsAndCropToAppKit() {
        XCTAssertEqual(ScreenShareIndicator.appKitFrame(
            captureBounds: CGRect(x: -1920, y: -200, width: 1920, height: 1080), primaryScreenMaxY: 900),
            CGRect(x: -1920, y: 20, width: 1920, height: 1080))
        XCTAssertEqual(ScreenShareIndicator.appKitFrame(
            captureBounds: CGRect(x: 120, y: 100, width: 640, height: 480), primaryScreenMaxY: 900),
            CGRect(x: 120, y: 320, width: 640, height: 480))
    }

    func testNativePanelCoversOnlySharedDisplayOrCropAndCannotTakeInput() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let id = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).uint32Value
        guard CGDisplayIsActive(id) != 0 else {
            throw XCTSkip("The selected display is online but asleep, so macOS cannot draw a visible outline")
        }
        let indicator = ScreenShareIndicator()
        defer { indicator.hide() }
        indicator.show(.display(id, crop: .zero))
        let fullDisplay = try XCTUnwrap(indicator.panel)
        XCTAssertTrue(fullDisplay.isVisible)
        XCTAssertEqual(fullDisplay.frame, screen.frame)
        XCTAssertTrue(fullDisplay.ignoresMouseEvents)
        XCTAssertFalse(fullDisplay.canBecomeKey)
        XCTAssertFalse(fullDisplay.canBecomeMain)
        XCTAssertTrue(fullDisplay.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(fullDisplay.collectionBehavior.contains(.fullScreenAuxiliary))

        let crop = CGRect(x: 100, y: 120, width: 400, height: 300)
        indicator.show(.display(id, crop: crop))
        XCTAssertFalse(fullDisplay.isVisible)
        let panel = try XCTUnwrap(indicator.panel)
        let bounds = CGDisplayBounds(id)
        XCTAssertEqual(panel.frame, ScreenShareIndicator.appKitFrame(
            captureBounds: crop.offsetBy(dx: bounds.minX, dy: bounds.minY), primaryScreenMaxY: screen.frame.maxY))
        indicator.hide()
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(indicator.panel)
    }

    func testWindowIndicatorFollowsMovementAndHidesWhenWindowCloses() async throws {
        _ = NSApplication.shared
        guard let primaryScreen = NSScreen.screens.first,
              let displayNumber = primaryScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              CGDisplayIsActive(displayNumber.uint32Value) != 0 else {
            throw XCTSkip("WindowServer geometry tracking requires an awake display")
        }
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        let windowID = CGWindowID(window.windowNumber)
        let indicator = ScreenShareIndicator()
        defer { indicator.hide(); window.close() }
        indicator.show(.window(windowID))
        let panel = try XCTUnwrap(indicator.panel)
        try await waitFor { panel.isVisible && self.captureFrame(for: windowID) != nil }
        guard let initialCaptureFrame = captureFrame(for: windowID) else {
            throw XCTSkip("macOS did not expose the test window's capture bounds; Screen Recording access may be unavailable")
        }
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.frame, initialCaptureFrame)
        window.setFrame(CGRect(x: 250, y: 260, width: 600, height: 400), display: true)
        try await waitFor {
            guard let captureFrame = self.captureFrame(for: windowID) else { return false }
            return captureFrame != initialCaptureFrame && panel.frame == captureFrame
        }
        let movedCaptureFrame = try XCTUnwrap(captureFrame(for: windowID))
        XCTAssertNotEqual(movedCaptureFrame, initialCaptureFrame)
        XCTAssertEqual(panel.frame, movedCaptureFrame)
        window.orderOut(nil)
        try await waitFor { !panel.isVisible }
        XCTAssertFalse(panel.isVisible)
        window.orderFrontRegardless()
        try await waitFor { panel.isVisible && self.captureFrame(for: windowID) != nil }
        XCTAssertTrue(panel.isVisible)
        window.close()
        try await waitFor { !panel.isVisible }
        XCTAssertFalse(panel.isVisible)
    }

    func testBorderRendersThemeAccentWithTransparentInterior() throws {
        let accent = try XCTUnwrap(NSColor(Theme.accent).usingColorSpace(.deviceRGB))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = SharingBorderView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
            view.appearance = NSAppearance(named: appearance)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: bitmap)
            }
            let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
            XCTAssertEqual(center.alphaComponent, 0)
            let edge = try XCTUnwrap(bitmap.colorAt(x: Int(2 * CGFloat(bitmap.pixelsWide) / 800),
                                                   y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(edge.redComponent, accent.redComponent, accuracy: 0.01)
            XCTAssertEqual(edge.greenComponent, accent.greenComponent, accuracy: 0.01)
            XCTAssertEqual(edge.blueComponent, accent.blueComponent, accuracy: 0.01)
            XCTAssertGreaterThan(edge.alphaComponent, 0.9)
        }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<40 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func captureFrame(for windowID: CGWindowID) -> CGRect? {
        guard let primaryScreen = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let windowInfo = windows.first(where: {
                  ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID &&
                  ($0[kCGWindowIsOnscreen as String] as? Bool) == true
              }),
              let bounds = windowInfo[kCGWindowBounds as String] as? NSDictionary,
              let captureBounds = CGRect(dictionaryRepresentation: bounds) else { return nil }
        return ScreenShareIndicator.appKitFrame(captureBounds: captureBounds,
                                                primaryScreenMaxY: primaryScreen.frame.maxY)
    }
}
