import AppKit
import SwiftUI
import LiveKit

struct InteractiveScreenView: NSViewRepresentable {
    let track: VideoTrack
    @ObservedObject var rtc: RTCService
    func makeNSView(context: Context) -> ScreenCanvas { ScreenCanvas(rtc: rtc) }
    func updateNSView(_ view: ScreenCanvas, context: Context) {
        view.setTrack(track)
        // Keep the viewer interactive while the host grants control. Without
        // this, a denied first request leaves no path to request again after
        // Accessibility is enabled during the same share.
        view.driving = rtc.canRequestRemoteControl
        view.independentCursor = rtc.usesIndependentCursors
        view.needsLayout = true
    }
    static func dismantleNSView(_ view: ScreenCanvas, coordinator: ()) {
        if view.driving { view.rtc?.releaseHeldInputs() }
        view.stopCursorPresence()
        view.firstFrameTask?.cancel()
        view.video.track = nil
    }
}

@MainActor
final class ScreenCanvas: NSView {
    let video = VideoView()
    weak var rtc: RTCService?
    var driving = false { didSet { if !driving && oldValue { window?.makeFirstResponder(nil) } } }
    var independentCursor = false {
        didSet { if independentCursor != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    private var lastCursorPoint: CGPoint?
    private var cursorPresenceTask: Task<Void, Never>?
    fileprivate var firstFrameTask: Task<Void, Never>?
    private var firstFrameStartedAt: TimeInterval?
    private static let transparentCursor = NSCursor(image: NSImage(size: NSSize(width: 16, height: 16)), hotSpot: .zero)
    private var tracking: NSTrackingArea?
    private var clipboardShortcutKeys = Set<UInt16>()
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(rtc: RTCService) {
        self.rtc = rtc
        super.init(frame: .zero)
        video.layoutMode = .fit
        video.mirrorMode = .off
        addSubview(video)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func setTrack(_ track: VideoTrack) {
        guard video.track !== track else { return }
        firstFrameTask?.cancel()
        rtc?.resetScreenFirstFrameMeasurement()
        firstFrameStartedAt = ProcessInfo.processInfo.systemUptime
        video.track = track
        let startedAt = firstFrameStartedAt
        firstFrameTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let startedAt else { return }
                if self.video.didRenderFirstFrame {
                    let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startedAt)
                    self.rtc?.recordScreenFirstFrame(milliseconds: Int((elapsed * 1_000).rounded()))
                    self.firstFrameTask = nil
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }
    override func layout() { super.layout(); video.frame = bounds }
    override func resetCursorRects() {
        super.resetCursorRects()
        // The sharing Mac renders the coloured pointer into the video. Hide
        // the viewer's OS pointer only inside the canvas to avoid a duplicate.
        if independentCursor, let dimensions = video.track?.dimensions,
           let content = ScreenCoordinateMapper.contentRect(container: bounds, contentSize: CGSize(width: Int(dimensions.width), height: Int(dimensions.height))) {
            addCursorRect(content, cursor: Self.transparentCursor)
        } else { addCursorRect(bounds, cursor: .arrow) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    private func normalized(_ event: NSEvent) -> CGPoint? {
        guard let dimensions = video.track?.dimensions, dimensions.width > 0, dimensions.height > 0 else { return nil }
        return ScreenCoordinateMapper.normalized(point: convert(event.locationInWindow, from: nil), container: bounds,
                                                  contentSize: CGSize(width: Int(dimensions.width), height: Int(dimensions.height)))
    }
    private func pointer(_ event: NSEvent) {
        guard driving || independentCursor, let point = normalized(event) else { return }
        lastCursorPoint = point
        startCursorPresence()
        rtc?.sendPointer(x: point.x, y: point.y)
    }
    override func mouseEntered(with event: NSEvent) { pointer(event) }
    override func mouseExited(with event: NSEvent) { stopCursorPresence(); rtc?.releaseHeldInputs() }
    private func startCursorPresence() {
        guard independentCursor, cursorPresenceTask == nil else { return }
        cursorPresenceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.independentCursor, self.window?.isKeyWindow == true,
                      let point = self.lastCursorPoint else { self?.stopCursorPresence(); return }
                self.rtc?.sendCursor(x: point.x, y: point.y)
            }
        }
    }
    func stopCursorPresence() {
        cursorPresenceTask?.cancel()
        cursorPresenceTask = nil
        lastCursorPoint = nil
        rtc?.sendCursor(visible: false)
    }
    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) { dragPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { dragPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { dragPointer(event) }
    private func dragPointer(_ event: NSEvent) {
        pointer(event)
    }
    override func mouseDown(with event: NSEvent) { press(event, down: true) }
    override func mouseUp(with event: NSEvent) { press(event, down: false) }
    override func rightMouseDown(with event: NSEvent) { press(event, down: true) }
    override func rightMouseUp(with event: NSEvent) { press(event, down: false) }
    override func otherMouseDown(with event: NSEvent) { press(event, down: true) }
    private func press(_ event: NSEvent, down: Bool) {
        guard let point = normalized(event), (0...2).contains(event.buttonNumber) else { return }
        if independentCursor { rtc?.sendCursor(x: point.x, y: point.y) }
        window?.makeFirstResponder(self)
        rtc?.sendButton(button: event.buttonNumber, down: down, x: point.x, y: point.y)
    }
    override func scrollWheel(with event: NSEvent) {
        guard let point = normalized(event) else { return }
        rtc?.sendScroll(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, x: point.x, y: point.y)
    }
    override func keyDown(with event: NSEvent) {
        guard let rtc else { return }
        if event.keyCode == 53 && event.modifierFlags.contains([.control, .option]) { rtc.emergencyStop(); return }
        if driving, ScreenClipboard.shortcut(code: event.keyCode, modifiers: event.modifierFlags) {
            clipboardShortcutKeys.insert(event.keyCode)
            if !event.isARepeat { rtc.sendScreenClipboardShortcut(code: event.keyCode) }
            return
        }
        rtc.sendKey(code: event.keyCode, down: true, modifiers: UInt64(event.modifierFlags.rawValue))
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard driving, window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
    /// AppKit's Edit menu can route standard actions through the responder
    /// chain without calling keyDown. Keep those on the same remote path.
    @objc func copy(_ sender: Any?) {
        guard driving, window?.firstResponder === self else { return }
        rtc?.sendScreenClipboardShortcut(code: 8)
    }
    @objc func paste(_ sender: Any?) {
        guard driving, window?.firstResponder === self else { return }
        rtc?.sendScreenClipboardShortcut(code: 9)
    }
    override func keyUp(with event: NSEvent) {
        if clipboardShortcutKeys.remove(event.keyCode) != nil { return }
        guard rtc != nil else { return }
        rtc?.sendKey(code: event.keyCode, down: false, modifiers: UInt64(event.modifierFlags.rawValue))
    }
    override func flagsChanged(with event: NSEvent) {
        guard rtc != nil else { return }
        let flag: NSEvent.ModifierFlags
        switch event.keyCode {
        case 54, 55: flag = .command
        case 56, 60: flag = .shift
        case 58, 61: flag = .option
        case 59, 62: flag = .control
        case 57: flag = .capsLock
        default: return
        }
        rtc?.sendKey(code: event.keyCode, down: event.modifierFlags.contains(flag), modifiers: UInt64(event.modifierFlags.rawValue))
    }
    override func resignFirstResponder() -> Bool {
        clipboardShortcutKeys.removeAll()
        if driving { rtc?.releaseHeldInputs() }
        stopCursorPresence()
        return true
    }
}

enum ScreenCoordinateMapper {
    static func contentRect(container: CGRect, contentSize: CGSize) -> CGRect? {
        guard contentSize.width > 0, contentSize.height > 0, container.width > 0, container.height > 0 else { return nil }
        let scale = min(container.width / contentSize.width, container.height / contentSize.height)
        return CGRect(x: container.midX - contentSize.width * scale / 2,
                      y: container.midY - contentSize.height * scale / 2,
                      width: contentSize.width * scale, height: contentSize.height * scale)
    }

    static func normalized(point: CGPoint, container: CGRect, contentSize: CGSize) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite,
              let rect = contentRect(container: container, contentSize: contentSize) else { return nil }
        guard rect.contains(point) else { return nil }
        return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    static func displayedPoint(normalized: CGPoint, container: CGRect, contentSize: CGSize) -> CGPoint? {
        guard normalized.x.isFinite, normalized.y.isFinite,
              (0...1).contains(normalized.x), (0...1).contains(normalized.y),
              let rect = contentRect(container: container, contentSize: contentSize) else { return nil }
        return CGPoint(x: rect.minX + normalized.x * rect.width, y: rect.minY + normalized.y * rect.height)
    }
}
