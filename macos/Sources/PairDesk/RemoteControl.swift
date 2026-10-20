import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// A remote pointer marker expressed in normalized screen coordinates.
struct RemotePointer: Identifiable, Equatable {
    let id: String
    let x: Double
    let y: Double
    let updatedAt: Date
}

enum RemoteControlState: Equatable {
    case unavailable
    case viewer
    case requesting
    case hostPermissionRequired
    case host
    case granted(identity: String, expiresAt: Date)
}

extension RemoteControlState {
    var isGranted: Bool { if case .granted = self { return true }; return false }
}

/// Wire format for ephemeral control traffic. `identity` is deliberately not
/// encoded: the receiver must use LiveKit's authenticated participant identity.
struct RemoteControlMessage: Codable, Equatable {
    /// Unknown kinds are ignored by older clients.
    enum Kind: String, Codable { case request, grant, revoke, hostPermissionRequired, release, heartbeat, pointer, key, button, scroll, releaseAll, availability, cursor, cursorBroadcast, qualityFeedback }
    var version: Int = 1
    var epoch: String
    var sequence: UInt64
    var kind: Kind
    var leaseMilliseconds: UInt32?
    var x: Double?
    var y: Double?
    var code: UInt16?
    var down: Bool?
    var modifiers: UInt64?
    var deltaX: Double?
    var deltaY: Double?
    /// `.availability` only: whether the sharer would accept input now, and why not.
    var available: Bool?
    var reason: String?
    /// Display shares advertise an epoch for independent, non-controlling cursors.
    var cursorSession: String?
    /// `.cursorBroadcast` only: identity of the participant whose pointer is relayed.
    var pointerIdentity: String?
    var visible: Bool?
    var packetLossPercent: Double?
    var roundTripMilliseconds: Int?
}

enum RemoteControlUnavailableReason: String, Codable, Equatable {
    case accessibility
    case paused
    case windowShare
    case privacyVeil
    case ownerActive
    case displayGeometry

    func viewerDescription(host: String) -> String {
        switch self {
        case .accessibility: "\(host) needs to allow PairDesk in Accessibility before you can control"
        case .paused: "\(host) paused remote control"
        case .windowShare: "window sharing is view only"
        case .privacyVeil: "\(host) is hiding apps · remote control is disabled for privacy"
        case .ownerActive: "\(host) is using the mouse or keyboard · try again in a moment"
        case .displayGeometry: "the selected display could not be mapped safely for remote control"
        }
    }
}

/// What the sharing Mac tells viewers. Viewers otherwise can only guess from
/// the track name, and would show "control available" for a Mac that cannot
/// accept input.
enum RemoteControlAvailability {
    static func evaluate(sharingWindow: Bool, accessibilityTrusted: Bool, automaticControlEnabled: Bool,
                         privacyVeilEnabled: Bool = false, ownerActive: Bool = false,
                         displayGeometryKnown: Bool = true) -> (available: Bool, reason: RemoteControlUnavailableReason?) {
        if sharingWindow { return (false, .windowShare) }
        if privacyVeilEnabled { return (false, .privacyVeil) }
        if !displayGeometryKnown { return (false, .displayGeometry) }
        if !accessibilityTrusted { return (false, .accessibility) }
        if !automaticControlEnabled { return (false, .paused) }
        if ownerActive { return (false, .ownerActive) }
        return (true, nil)
    }
}

enum IndependentCursorPolicy {
    /// Hover is presence, never an OS mouse move or a control request.
    static func movesSystemCursor(independent: Bool, heldButtonCount: Int) -> Bool {
        !independent || heldButtonCount > 0
    }

    static func accepts(_ message: RemoteControlMessage, session: String?, isParticipant: Bool, lastSequence: UInt64?) -> Bool {
        guard isParticipant, message.version == 1, message.kind == .cursor,
              let session, !session.isEmpty, message.epoch == session,
              message.sequence > (lastSequence ?? 0) else { return false }
        if message.visible == false { return true }
        guard let x = message.x, let y = message.y else { return false }
        return x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
    }

    static func acceptsBroadcast(_ message: RemoteControlMessage, session: String?, senderIsSharer: Bool,
                                 pointerIsParticipant: Bool, viewerIdentity: String?, lastSequence: UInt64?) -> Bool {
        guard senderIsSharer, pointerIsParticipant, message.version == 1,
              message.kind == .cursorBroadcast,
              let pointerIdentity = message.pointerIdentity, !pointerIdentity.isEmpty,
              pointerIdentity != viewerIdentity,
              let session, !session.isEmpty, message.epoch == session,
              message.sequence > (lastSequence ?? 0) else { return false }
        if message.visible == false { return true }
        guard let x = message.x, let y = message.y else { return false }
        return x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
    }

}

/// First eligible requester owns the current lease; later requesters wait in
/// arrival order. The host enables this only after the user starts sharing.
struct RemoteControlArbiter {
    enum RequestResult: Equatable { case grant, queued, ignored }

    private(set) var isEnabled = false
    private(set) var driverIdentity: String?
    private(set) var waiting: [String] = []

    mutating func enable() { isEnabled = true }

    mutating func disable() {
        isEnabled = false
        driverIdentity = nil
        waiting.removeAll()
    }

    mutating func request(identity: String) -> RequestResult {
        guard isEnabled, !identity.isEmpty, identity != driverIdentity,
              !waiting.contains(identity) else { return .ignored }
        guard driverIdentity == nil else {
            waiting.append(identity)
            return .queued
        }
        driverIdentity = identity
        return .grant
    }

    @discardableResult
    mutating func release(identity: String) -> String? {
        waiting.removeAll { $0 == identity }
        guard driverIdentity == identity else { return nil }
        driverIdentity = waiting.isEmpty ? nil : waiting.removeFirst()
        return driverIdentity
    }
}

enum RemoteControlLeasePolicy {
    static func canExpireIdleLease(heldKeyCount: Int, heldButtonCount: Int) -> Bool {
        heldKeyCount == 0 && heldButtonCount == 0
    }
}

/// Checks the grant, epoch and monotonic sequence before an input event can be
/// posted. A new grant creates a fresh epoch, making old queued messages inert.
///
/// The viewer numbers every message from one counter but sends pointer motion
/// on the lossy channel, so pointer samples are checked against their own
/// high-water mark: a sample that overtakes a key or click must not block it,
/// and one that arrives after a later click is stale and is dropped.
struct RemoteControlGate {
    private(set) var driverIdentity: String?
    private(set) var epoch: String?
    private(set) var expiresAtUptime: TimeInterval?
    private(set) var lastSequence: UInt64 = 0
    private(set) var lastPointerSequence: UInt64 = 0

    mutating func grant(identity: String, epoch: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        driverIdentity = identity
        self.epoch = epoch
        expiresAtUptime = now + 2
        lastSequence = 0
        lastPointerSequence = 0
    }

    mutating func revoke() {
        driverIdentity = nil
        epoch = nil
        expiresAtUptime = nil
        lastSequence = 0
        lastPointerSequence = 0
    }

    mutating func accept(_ message: RemoteControlMessage, sender: String,
                         now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard message.version == 1,
              let driverIdentity,
              sender == driverIdentity,
              message.epoch == epoch,
              let currentExpiry = expiresAtUptime, currentExpiry > now
        else { return false }
        if message.kind == .pointer {
            guard message.sequence > max(lastPointerSequence, lastSequence) else { return false }
            lastPointerSequence = message.sequence
            return true
        }
        guard message.sequence > lastSequence else { return false }
        lastSequence = message.sequence
        if message.kind == .heartbeat {
            let duration = min(Double(message.leaseMilliseconds ?? 2_000), 2_000) / 1_000
            expiresAtUptime = now + max(0.1, duration)
        }
        return true
    }

    var isActive: Bool { expiresAtUptime.map { $0 > ProcessInfo.processInfo.systemUptime } ?? false }
}

enum RemoteInputInjector {
    static let eventMarker: Int64 = 0x504149524445534B

    static var currentPointerPosition: CGPoint? { CGEvent(source: nil)?.location }

    static func restorePointer(to point: CGPoint) {
        guard AXIsProcessTrusted(), point.x.isFinite, point.y.isFinite else { return }
        _ = CGWarpMouseCursorPosition(point)
    }

    static func point(x: Double, y: Double, in bounds: CGRect) -> CGPoint? {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
              bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0
        else { return nil }
        return CGPoint(x: bounds.minX + CGFloat(x) * bounds.width,
                       y: bounds.minY + CGFloat(y) * bounds.height)
    }

    /// Posts normalized pointer coordinates within the chosen display bounds.
    /// macOS Accessibility approval is checked for every injection attempt.
    static func movePointer(x: Double, y: Double, in bounds: CGRect, draggingButton: CGMouseButton? = nil) -> Bool {
        guard AXIsProcessTrusted(), let point = point(x: x, y: y, in: bounds) else { return false }
        let mouseType: CGEventType
        switch draggingButton {
        case .some(.left): mouseType = .leftMouseDragged
        case .some(.right): mouseType = .rightMouseDragged
        case .some(.center): mouseType = .otherMouseDragged
        case .none: mouseType = .mouseMoved
        @unknown default: return false
        }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: mouseType,
                                  mouseCursorPosition: point,
                                  mouseButton: draggingButton ?? .left)
        else { return false }
        event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        event.post(tap: .cgSessionEventTap)
        return true
    }

    static func key(code: UInt16, down: Bool, modifiers: CGEventFlags = []) -> Bool {
        guard AXIsProcessTrusted(), let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) else { return false }
        event.flags = modifiers
        event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        event.post(tap: .cgSessionEventTap)
        return true
    }

    static func button(_ button: CGMouseButton, down: Bool, at point: CGPoint) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let type: CGEventType
        switch (button, down) {
        case (.left, true): type = .leftMouseDown
        case (.left, false): type = .leftMouseUp
        case (.right, true): type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        case (.center, true): type = .otherMouseDown
        case (.center, false): type = .otherMouseUp
        @unknown default: return false
        }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return false }
        event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        event.post(tap: .cgSessionEventTap)
        return true
    }

    static func scroll(deltaX: Double, deltaY: Double, at point: CGPoint? = nil) -> Bool {
        guard AXIsProcessTrusted(), deltaX.isFinite, deltaY.isFinite,
              abs(deltaX) <= 200, abs(deltaY) <= 200,
              let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(deltaY.rounded()),
                                  wheel2: Int32(deltaX.rounded()),
                                  wheel3: 0)
        else { return false }
        if let point { event.location = point }
        event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        event.post(tap: .cgSessionEventTap)
        return true
    }
}
