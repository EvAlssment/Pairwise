import AppKit
import ScreenCaptureKit
import SwiftUI
import XCTest
@testable import PairDesk

@MainActor
final class HostCursorOverlayTests: XCTestCase {
    func testDesktopOverlayMapsCropAndKeepsWindowIDWhileCursorsMoveAndHide() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let overlay = HostCursorOverlay()
        defer { overlay.hide() }
        let crop = CGRect(x: -1200, y: 140, width: 800, height: 500)
        overlay.prepare(captureBounds: crop)
        let panel = try XCTUnwrap(overlay.panel)
        XCTAssertEqual(panel.frame, ScreenShareIndicator.appKitFrame(captureBounds: crop, primaryScreenMaxY: screen.frame.maxY))
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        let windowID = panel.windowNumber
        let names = ["a": "Alex", "b": "Sam"]
        let pointer = RemotePointer(id: "a", x: 0.25, y: 0.75, updatedAt: .now)
        overlay.update(pointers: [pointer], names: names)
        let content = try XCTUnwrap(panel.contentView as? NSHostingView<SharedCursorLayer>)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(content.rootView.names, names)
        XCTAssertEqual(content.rootView.pointers, [pointer])
        XCTAssertEqual(content.rootView.contentSize, crop.size)
        let moved = RemotePointer(id: "a", x: 0.8, y: 0.2, updatedAt: .now)
        overlay.update(pointers: [moved], names: names)
        XCTAssertEqual(content.rootView.pointers, [moved])
        overlay.clear()
        XCTAssertFalse(panel.isVisible)
        overlay.update(pointers: [moved], names: names)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.windowNumber, windowID, "The capture exclusion must keep the same window ID")
        overlay.hide()
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(overlay.panel)
    }

    func testOwnOverlayCanBeFoundForCaptureExclusionWithoutRecording() async throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("Own-process content lookup requires macOS 14.4") }
        _ = NSApplication.shared
        let overlay = HostCursorOverlay()
        defer { overlay.hide() }
        overlay.prepare(captureBounds: CGDisplayBounds(CGMainDisplayID()))
        let panel = try XCTUnwrap(overlay.panel)
        let content = try await HostCursorOverlay.currentProcessContent()
        XCTAssertTrue(content.windows.contains { $0.windowID == CGWindowID(panel.windowNumber) },
                      "The cursor panel must be discoverable for explicit capture exclusion")
        // Displays may be redacted without capture consent; production gets
        // the selected display from the native picker on macOS 15.2+.
        if #available(macOS 15.2, *), let display = content.displays.first(where: { $0.width > 0 && $0.height > 0 }) {
            let selection = SCContentFilter(display: display, excludingWindows: [])
            selection.includeMenuBar = true
            let filterResult = try await overlay.captureFilter(from: selection, displayID: display.displayID)
            let filtered = try XCTUnwrap(filterResult)
            XCTAssertEqual(filtered.includedDisplays.map(\.displayID), [display.displayID])
            XCTAssertEqual(filtered.contentRect, selection.contentRect)
            XCTAssertTrue(filtered.includeMenuBar)
            XCTAssertFalse(filtered.includedWindows.contains { $0.windowID == CGWindowID(panel.windowNumber) })
        }
    }

    @MainActor
    func testCaptureFilterExcludesSelectedWindowAndCursorOverlayTogether() async throws {
        guard #available(macOS 15.2, *) else { throw XCTSkip("Display filtering requires macOS 15.2") }
        _ = NSApplication.shared
        let protected = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 320, height: 180),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
        protected.title = "PairDesk privacy test window"
        protected.animationBehavior = .none
        protected.isReleasedWhenClosed = false
        protected.orderFrontRegardless()
        defer { protected.close() }

        let overlay = HostCursorOverlay()
        defer { overlay.hide() }
        overlay.prepare(captureBounds: CGDisplayBounds(CGMainDisplayID()))
        let panel = try XCTUnwrap(overlay.panel)
        let content = try await HostCursorOverlay.currentProcessContent()
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() && $0.width > 0 && $0.height > 0 }),
              let protectedContentWindow = content.windows.first(where: { $0.windowID == CGWindowID(protected.windowNumber) }) else {
            throw XCTSkip("The current-process ScreenCaptureKit window list is redacted")
        }
        let selection = SCContentFilter(display: display, excludingWindows: [])
        let filteredResult = try await overlay.captureFilter(
            from: selection, displayID: display.displayID, excludingWindows: [protectedContentWindow]
        )
        let filtered = try XCTUnwrap(filteredResult)

        XCTAssertFalse(filtered.includedWindows.contains { $0.windowID == CGWindowID(panel.windowNumber) },
                       "The app's collaborator cursor overlay must remain excluded")
        XCTAssertFalse(filtered.includedWindows.contains { $0.windowID == protectedContentWindow.windowID },
                       "The selected private window must be excluded from the display filter")
        XCTAssertEqual(filtered.includedDisplays.map(\.displayID), [display.displayID])
    }

    func testWhenCaptureExclusionIsUnavailableKeepPickerFilterAndHideHostOverlay() async throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("Capture exclusion lookup requires macOS 14.4") }
        _ = NSApplication.shared
        let content = try await HostCursorOverlay.currentProcessContent()
        guard let display = content.displays.first(where: { $0.width > 0 && $0.height > 0 }) else {
            throw XCTSkip("The current-process display list is redacted on this system")
        }
        let pickerFilter = SCContentFilter(display: display, excludingWindows: [])
        let overlay = HostCursorOverlay()
        defer { overlay.hide() }
        overlay.prepare(captureBounds: CGDisplayBounds(display.displayID))
        XCTAssertNotNil(overlay.panel)

        let exclusionFilter = try await overlay.captureFilter(from: pickerFilter,
                                                              displayID: display.displayID,
                                                              exclusionSupported: false)

        XCTAssertNil(exclusionFilter)
        XCTAssertNil(overlay.panel, "The host overlay must be disabled when it cannot be excluded from capture")
        XCTAssertTrue((exclusionFilter ?? pickerFilter) === pickerFilter,
                      "The user's authorized picker filter remains available for screen sharing")
    }

    func testWhenPickerOmitsSelectedDisplayHideHostOverlayAndKeepPickerFilter() async throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("Capture exclusion lookup requires macOS 14.4") }
        _ = NSApplication.shared
        let content = try await HostCursorOverlay.currentProcessContent()
        guard let display = content.displays.first(where: { $0.width > 0 && $0.height > 0 }) else {
            throw XCTSkip("The current-process display list is redacted on this system")
        }
        let pickerFilter = SCContentFilter(display: display, excludingWindows: [])
        let overlay = HostCursorOverlay()
        defer { overlay.hide() }
        overlay.prepare(captureBounds: CGDisplayBounds(display.displayID))

        let unavailableID = CGDirectDisplayID.max
        XCTAssertFalse(content.displays.contains { $0.displayID == unavailableID })
        let exclusionFilter = try await overlay.captureFilter(from: pickerFilter, displayID: unavailableID)

        XCTAssertNil(exclusionFilter)
        XCTAssertNil(overlay.panel, "A redacted or unmatched picker display must not leave the host overlay visible")
        XCTAssertTrue((exclusionFilter ?? pickerFilter) === pickerFilter)
    }

}
