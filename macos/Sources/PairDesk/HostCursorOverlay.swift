import AppKit
import ScreenCaptureKit
import SwiftUI

/// Named viewer cursors on the sharing desktop. This window never accepts input.
@MainActor
final class HostCursorOverlay {
    private(set) var panel: NSPanel?
    private var content: NSHostingView<SharedCursorLayer>?

    func prepare(captureBounds: CGRect) {
        hide()
        guard let primary = NSScreen.screens.first, captureBounds.width > 0, captureBounds.height > 0,
              !captureBounds.isInfinite, !captureBounds.isNull else { return }
        let frame = ScreenShareIndicator.appKitFrame(captureBounds: captureBounds,
                                                     primaryScreenMaxY: primary.frame.maxY)
        let panel = CursorOverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        panel.title = "PairDesk · Remote cursors"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.sharingType = .none
        panel.animationBehavior = .none
        let content = NSHostingView(rootView: SharedCursorLayer(pointers: [], names: [:], contentSize: frame.size))
        panel.contentView = content
        self.content = content
        self.panel = panel
        // Register the empty, transparent window before constructing the capture
        // filter. Keep this window ID for the entire share, even with no cursors.
        panel.orderFrontRegardless()
    }

    /// The picker selects a complete display; retain that display and crop while
    /// excluding our own overlay so viewers don't receive duplicate cursors.
    func captureFilter(from selection: SCContentFilter, displayID: CGDirectDisplayID,
                       excludingApplications: [SCRunningApplication] = [],
                       excludingWindows: [SCWindow] = [],
                       exclusionSupported: Bool = true) async throws -> SCContentFilter? {
        // Keep the normal screen share available on systems where the picker
        // doesn't expose enough metadata to exclude our own overlay. In that
        // case the host-side overlay must stay hidden: the picker filter includes
        // the whole display and would otherwise transmit the cursors in-band.
        guard exclusionSupported, let panel, selection.style == .display, #available(macOS 14.4, *) else {
            hide()
            return nil
        }
        let owned: SCShareableContent
        do {
            owned = try await Self.currentProcessContent()
        } catch {
            hide()
            return nil
        }
        guard self.panel === panel else { throw CancellationError() }
        let display: SCDisplay?
        if #available(macOS 15.2, *) { display = selection.includedDisplays.first { $0.displayID == displayID } }
        else { display = owned.displays.first { $0.displayID == displayID } }
        // Before 15.2 a picker-only grant may redact display information. Keep
        // the authorized filter and the legacy window sharing type in that case.
        guard let display, display.width > 0, display.height > 0 else {
            hide()
            return nil
        }
        guard let window = owned.windows.first(where: { $0.windowID == CGWindowID(panel.windowNumber) }) else {
            hide()
            return nil
        }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: excludingApplications,
                                     exceptingWindows: [window] + excludingWindows)
        filter.includeMenuBar = selection.includeMenuBar
        return filter
    }

    @available(macOS 14.4, *)
    static func currentProcessContent() async throws -> SCShareableContent {
        // Handle nullable replies directly instead of using the imported async
        // getter, which crashes in the macOS 15 test runner.
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getCurrentProcessShareableContent { content, error in
                if let content { continuation.resume(returning: content) }
                else {
                    continuation.resume(throwing: error ?? NSError(domain: "PairDesk.HostCursorOverlay", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Current-process capture information was unavailable."]))
                }
            }
        }
    }

    func update(pointers: [RemotePointer], names: [String: String]) {
        guard let panel, let content else { return }
        content.rootView = SharedCursorLayer(pointers: pointers, names: names, contentSize: panel.frame.size)
        if pointers.isEmpty { panel.orderOut(nil) }
        else if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func clear() { update(pointers: [], names: [:]) }

    func hide() {
        panel?.close()
        panel = nil
        content = nil
    }
}

private final class CursorOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
