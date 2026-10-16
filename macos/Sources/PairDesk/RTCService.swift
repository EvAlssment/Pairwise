import AVFoundation
import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit
@preconcurrency import LiveKit

struct CallParticipant: Identifiable, Equatable {
    let identity: String
    let name: String
    let isLocal: Bool
    var isSpeaking: Bool = false
    var id: String { identity }
}

private enum LocalControlIntent {
    case pointer(Double, Double)
    case key(UInt16, Bool, UInt64)
    case button(Int, Bool, Double, Double)
    case scroll(Double, Double, Double?, Double?)
}

private struct ViewerQualityFeedback {
    let sequence: UInt64
    let packetLossPercent: Double?
    let roundTripMilliseconds: Int?
    let receivedAtUptime: TimeInterval
}

/// Owns one LiveKit room, local media and the consented remote-control lease.
@MainActor
final class RTCService: NSObject, ObservableObject, RoomDelegate, VideoCapturerDelegate {
    @Published private(set) var connected = false
    @Published private(set) var isMicrophoneEnabled = false
    @Published private(set) var isSharing = false {
        didSet { if !isSharing { sharingIndicator.hide() } }
    }
    @Published private(set) var participants: [CallParticipant] = []
    @Published private(set) var screenTrack: VideoTrack?
    @Published private(set) var status = "Disconnected"
    @Published private(set) var error: String?
    @Published private(set) var controlState: RemoteControlState = .unavailable
    @Published private(set) var pendingControlRequests: [CallParticipant] = []
    @Published private(set) var activeSharerIdentity: String?
    @Published private(set) var remoteControlAvailable = false
    /// Viewer side: why the sharer will not accept input, when it won't.
    @Published private(set) var remoteControlUnavailableReason: RemoteControlUnavailableReason?
    @Published private(set) var automaticControlEnabled = false
    @Published private(set) var remotePointers: [RemotePointer] = []
    @Published private(set) var cursorSessionID: String?
    @Published private(set) var localCursorPosition: CGPoint?
    var usesIndependentCursors: Bool { !isSharing && cursorSessionID != nil }
    var canPointAtRemoteScreen: Bool { connected && !isSharing && screenTrack != nil && activeSharerIdentity != nil }
    @Published private(set) var localIdentity: String?
    @Published private(set) var audioInputDevices: [AudioDeviceChoice] = []
    @Published private(set) var audioOutputDevices: [AudioDeviceChoice] = []
    @Published private(set) var selectedAudioInputID = ""
    @Published private(set) var selectedAudioOutputID = ""
    @Published private(set) var savedAudioInputUnavailable = false
    @Published private(set) var savedAudioOutputUnavailable = false
    @Published private(set) var localMicrophoneLevel = 0.0
    @Published private(set) var screenNetworkQuality: ScreenNetworkQuality = .measuring
    @Published private(set) var screenStreamMetrics = ScreenStreamMetrics()
    @Published private(set) var screenShareQuality = ScreenShareQuality.load()
    @Published private(set) var adaptiveQualityEnabled = (UserDefaults.standard.object(forKey: "adaptiveShareQualityEnabled") as? Bool) ?? true
    @Published private(set) var adaptiveShareStatus: String?
    @Published private(set) var isReconnecting = false
    @Published private(set) var incomingClipboardTransfer: (senderName: String, message: ClipboardTransferMessage)?
    @Published private(set) var clipboardSyncEnabled = false
    @Published private(set) var clipboardSyncNotice: String?

    /// Called for captured local microphone and subscribed remote audio tracks.
    /// Buffers are copied to normalized Float samples before delivery. It remains
    /// silent unless a consumer installs this callback (for example, after consent).
    var onAudioBuffer: ((String, String, [Float], Double) -> Void)?
    private var audioForwardingConsented = false

    private var room: Room?
    private var localAudioRenderer: PCMForwarder?
    private var lastMicrophoneMeterUpdate: TimeInterval = 0
    private var remoteAudioRenderers: [String: (identity: String, track: RemoteAudioTrack, renderer: PCMForwarder)] = [:]
    private var shareTrack: LocalVideoTrack?
    private var adaptiveShareController: AdaptiveShareController?
    private var adaptiveQualityTask: Task<Void, Never>?
    private var isStartingShare = false
    private var isStoppingShare = false
    private let sharingIndicator = ScreenShareIndicator()
    private var accessibilityMonitorTask: Task<Void, Never>?
    private var remoteControlManuallyPaused = false
    private var resumeControlAfterReconnect = false
    private var shareBounds: CGRect?
    private var shareIsWindow = false
    private var controlGate = RemoteControlGate()
    private var controlArbiter = RemoteControlArbiter()
    private var localControllerEpoch: String?
    private var localSequence: UInt64 = 0
    private var queuedLocalIntents: [LocalControlIntent] = []
    private var localHeldKeys = Set<UInt16>()
    private var localHeldButtons = Set<Int>()
    private var controllerIdleTask: Task<Void, Never>?
    private var requestTimeoutTask: Task<Void, Never>?
    /// Availability can arrive before the screen track is subscribed.
    private var controlAvailabilityBySender: [String: (available: Bool, reason: RemoteControlUnavailableReason?, cursorSession: String?)] = [:]
    private var leaseTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var heldKeys = Set<UInt16>()
    private var heldButtons = Set<Int>()
    private enum LossySlot { case pointer, cursor }
    /// Pointer motion and cursor presence: the newest sample per slot, sent on
    /// the lossy channel by one loop at up to 60 Hz. A stale sample is replaced,
    /// never queued behind the reliable key/click/scroll messages.
    private var pendingLossy: [LossySlot: (message: RemoteControlMessage, destination: String?)] = [:]
    private var lossySendTask: Task<Void, Never>?
    /// Scroll deltas arriving within 16 ms of a scroll send are summed into one
    /// reliable message instead of one message per trackpad event.
    private var pendingScroll: (epoch: String, dx: Double, dy: Double, x: Double?, y: Double?)?
    private var scrollFlushTask: Task<Void, Never>?
    private var lastQualityFeedbackSentAt: TimeInterval = 0
    private var qualityFeedbackSequence: UInt64 = 0
    private var viewerQualityFeedback: [String: ViewerQualityFeedback] = [:]
    private var cursorExpiryTask: Task<Void, Never>?
    private var cursorSequenceBySender: [String: UInt64] = [:]
    private var independentCursorParticipants = Set<String>()
    private var ownerPointerPosition: CGPoint?
    private var pointerRestoreTask: Task<Void, Never>?
    private var ownerBusyUntil: TimeInterval = 0
    private var ownerActivityTask: Task<Void, Never>?
    private var lastControlRequestAt: TimeInterval = -.infinity
    private var inputMonitor: Any?
    private var localInputMonitor: Any?
    private var notificationTokens: [NSObjectProtocol] = []
    private var controlSendTail: Task<Void, Never>?
    private var clipboardReplayWindow = ClipboardTransferReplayWindow()
    private var clipboardAssembler = ClipboardTransferAssembler()
    private var clipboardSyncTask: Task<Void, Never>?
    private var clipboardObservedChangeCount = 0
    private var lastSharedClipboardText: String?
    private var queuedControlSends = 0
    private var controlTransportFailed = false
    private let maxQueuedControlSends = 256

    var activeControllerIdentity: String? { isSharing ? controlArbiter.driverIdentity : nil }
    var isSharingWindow: Bool { isSharing && shareIsWindow }

    func participantName(for identity: String) -> String {
        participants.first(where: { $0.identity == identity })?.name ?? identity
    }

    override init() {
        super.init()
        AudioManager.shared.onDeviceUpdate = { [weak self] manager in
            Task { @MainActor [weak self] in self?.refreshAudioDevices(using: manager) }
        }
        refreshAudioDevices()
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]) { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != RemoteInputInjector.eventMarker else { return }
            Task { @MainActor [weak self] in self?.handleLocalInput(event) }
        }
        localInputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]) { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != RemoteInputInjector.eventMarker else { return event }
            Task { @MainActor [weak self] in self?.handleLocalInput(event) }
            return event
        }
        let appCenter = NotificationCenter.default
        notificationTokens.append(appCenter.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isSharing else { return }
                self.releaseHeldInputs()
            }
        })
        notificationTokens.append(appCenter.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isSharing else { return }
                self.emergencyStop()
                await self.stopScreenShare()
            }
        })
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationTokens.append(workspaceCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.emergencyStop() }
        })
        notificationTokens.append(workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.emergencyStop() }
        })
    }

    deinit {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        if let localInputMonitor { NSEvent.removeMonitor(localInputMonitor) }
        notificationTokens.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
    }

    func connect(url: String, token: String, identity: String, name: String) async throws {
        guard room == nil else { throw LiveKitError(.invalidState, message: "Already connected") }
        error = nil
        status = "Connecting…"
        controlTransportFailed = false
        let newRoom = Room(delegate: self)
        room = newRoom
        do {
            try await newRoom.connect(url: url, token: token)
            guard newRoom.participantCount <= 4 else {
                await newRoom.disconnect()
                throw LiveKitError(.invalidState, message: "This room is limited to four participants.")
            }
            localIdentity = newRoom.localParticipant.identity?.stringValue ?? identity
            connected = true
            refreshAudioDevices()
            status = "Connected as \(name)"
            refreshParticipants()
            refreshSharer()
            controlState = .viewer
            // No media is enabled on connect. In particular, there is no camera path.
        } catch {
            self.error = error.localizedDescription
            status = "Connection failed"
            room = nil
            throw error
        }
    }

    func disconnect() async {
        heartbeatTask?.cancel()
        leaseTask?.cancel()
        heartbeatTask = nil
        leaseTask = nil
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil
        controlAvailabilityBySender.removeAll()
        remoteControlUnavailableReason = nil
        incomingClipboardTransfer = nil
        clipboardReplayWindow = ClipboardTransferReplayWindow()
        clipboardAssembler = ClipboardTransferAssembler()
        setClipboardSyncEnabled(false)
        emergencyStop()
        resetIndependentCursors()
        controlTransportFailed = true
        if let room {
            detachAudioRenderers()
            // Room teardown stops every local track, including the microphone.
            await room.disconnect()
        }
        self.room = nil
        room = nil
        isReconnecting = false
        resumeControlAfterReconnect = false
        screenTrack = nil
        shareTrack = nil
        isSharing = false
        isMicrophoneEnabled = false
        connected = false
        participants = []
        activeSharerIdentity = nil
        remotePointers = []
        pendingControlRequests = []
        controlState = .unavailable
        localIdentity = nil
        audioForwardingConsented = false
        shareBounds = nil
        shareIsWindow = false
        remoteControlAvailable = false
        automaticControlEnabled = false
        controlArbiter.disable()
        queuedLocalIntents.removeAll()
        localHeldKeys.removeAll()
        localHeldButtons.removeAll()
        status = "Disconnected"
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard let room else { throw LiveKitError(.invalidState, message: "Not connected") }
        do {
            try await room.localParticipant.setMicrophone(enabled: enabled)
            isMicrophoneEnabled = enabled
            if enabled { attachLocalAudioRenderer() }
            else { detachLocalAudioRenderer(); localMicrophoneLevel = 0 }
        } catch {
            self.error = "Microphone could not be \(enabled ? "enabled" : "disabled"): \(error.localizedDescription)"
            throw error
        }
    }

    func selectAudioInput(_ deviceID: String) {
        guard let device = AudioManager.shared.inputDevices.first(where: { $0.deviceId == deviceID }) else { return }
        AudioManager.shared.inputDevice = device
        selectedAudioInputID = device.deviceId
        UserDefaults.standard.set(device.deviceId, forKey: "audioInputDeviceID")
        savedAudioInputUnavailable = false
        audioInputDevices = Self.audioDeviceChoices(AudioManager.shared.inputDevices)
    }

    func selectAudioOutput(_ deviceID: String) {
        guard let device = AudioManager.shared.outputDevices.first(where: { $0.deviceId == deviceID }) else { return }
        AudioManager.shared.outputDevice = device
        selectedAudioOutputID = device.deviceId
        UserDefaults.standard.set(device.deviceId, forKey: "audioOutputDeviceID")
        savedAudioOutputUnavailable = false
        audioOutputDevices = Self.audioDeviceChoices(AudioManager.shared.outputDevices)
    }

    private func refreshAudioDevices(using manager: AudioManager = .shared) {
        let inputs = manager.inputDevices
        let outputs = manager.outputDevices
        if let savedID = UserDefaults.standard.string(forKey: "audioInputDeviceID") {
            if let savedDevice = inputs.first(where: { $0.deviceId == savedID }) {
                if manager.inputDevice.deviceId != savedID { manager.inputDevice = savedDevice }
                savedAudioInputUnavailable = false
            } else {
                savedAudioInputUnavailable = true
            }
        }
        if let savedID = UserDefaults.standard.string(forKey: "audioOutputDeviceID") {
            if let savedDevice = outputs.first(where: { $0.deviceId == savedID }) {
                if manager.outputDevice.deviceId != savedID { manager.outputDevice = savedDevice }
                savedAudioOutputUnavailable = false
            } else {
                savedAudioOutputUnavailable = true
            }
        }
        audioInputDevices = Self.audioDeviceChoices(inputs)
        audioOutputDevices = Self.audioDeviceChoices(outputs)
        selectedAudioInputID = manager.inputDevice.deviceId
        selectedAudioOutputID = manager.outputDevice.deviceId
    }

    private static func audioDeviceChoices(_ devices: [AudioDevice]) -> [AudioDeviceChoice] {
        AudioDeviceChoice.unique(devices.map {
            AudioDeviceChoice(id: $0.deviceId, name: $0.name, isDefault: $0.isDefault)
        })
    }

    func refreshScreenNetworkQuality() {
        guard let statistics = screenTrack?.statistics else {
            screenNetworkQuality = .measuring
            screenStreamMetrics = ScreenStreamMetrics()
            return
        }
        let pairs = statistics.iceCandidatePair.map {
            CandidatePairRTT(id: $0.id, roundTripTimeSeconds: $0.currentRoundTripTime)
        }
        let roundTripTime = ScreenNetworkQuality.selectedRoundTripTimeSeconds(
            selectedPairID: statistics.transportStats?.selectedCandidatePairId,
            pairs: pairs
        )
        screenNetworkQuality = .from(roundTripTimeSeconds: roundTripTime)
        let video = statistics.inboundRtpStream.first(where: { $0.kind == "video" })
            ?? statistics.inboundRtpStream.first
        screenStreamMetrics = ScreenStreamMetrics(width: video?.frameWidth,
                                                  height: video?.frameHeight,
                                                  framesPerSecond: video?.framesPerSecond,
                                                  packetsReceived: video?.packetsReceived,
                                                  packetsLost: video?.packetsLost)
        sendViewerQualityFeedback()
    }

    private func sendViewerQualityFeedback() {
        guard !isSharing, connected, let room, let sharer = activeSharerIdentity,
              let session = cursorSessionID else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastQualityFeedbackSentAt >= 3 else { return }
        let rtt: Int?
        switch screenNetworkQuality {
        case .measuring: rtt = nil
        case let .good(milliseconds), let .fair(milliseconds), let .highLatency(milliseconds): rtt = milliseconds
        }
        guard screenStreamMetrics.packetLossPercent != nil || rtt != nil else { return }
        lastQualityFeedbackSentAt = now
        qualityFeedbackSequence &+= 1
        let feedback = RemoteControlMessage(epoch: session,
                                            sequence: qualityFeedbackSequence,
                                            kind: .qualityFeedback,
                                            packetLossPercent: screenStreamMetrics.packetLossPercent,
                                            roundTripMilliseconds: rtt)
        guard let data = try? JSONEncoder().encode(feedback) else { return }
        let options = DataPublishOptions(name: "PairDesk screen quality feedback",
                                         destinationIdentities: [Participant.Identity(from: sharer)],
                                         topic: Self.controlTopic,
                                         reliable: false)
        Task { try? await room.localParticipant.publish(data: data, options: options) }
    }

    /// Saves the host's quality ceiling and applies it to an active share.
    func setScreenShareQuality(_ quality: ScreenShareQuality) {
        screenShareQuality = quality
        quality.persist()
        guard isSharing,
              let capturer = shareTrack?.capturer as? MacOSScreenCapturer else { return }
        let tier: AdaptiveShareTier
        if adaptiveQualityEnabled {
            let controller = AdaptiveShareController(maximum: quality)
            adaptiveShareController = controller
            tier = controller.current
            adaptiveShareStatus = "Auto · \(tier.title)"
        } else {
            Task {
                do {
                    try await capturer.updateScreenShareSettings(dimensions: quality.dimensions,
                                                                  fps: quality.framesPerSecond)
                } catch {
                    adaptiveShareStatus = nil
                }
            }
            return
        }
        Task {
            do {
                try await capturer.updateScreenShareSettings(dimensions: tier.dimensions, fps: tier.fps)
            } catch {
                adaptiveShareStatus = adaptiveQualityEnabled ? "Auto · holding current quality" : nil
            }
        }
    }

    func setAdaptiveQualityEnabled(_ enabled: Bool) {
        guard adaptiveQualityEnabled != enabled else { return }
        adaptiveQualityEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "adaptiveShareQualityEnabled")
        if enabled {
            let controller = AdaptiveShareController(maximum: screenShareQuality)
            adaptiveShareController = controller
            if isSharing, let capturer = shareTrack?.capturer as? MacOSScreenCapturer {
                let tier = controller.current
                adaptiveShareStatus = "Auto · \(tier.title)"
                Task {
                    do {
                        try await capturer.updateScreenShareSettings(dimensions: tier.dimensions, fps: tier.fps)
                    } catch {
                        adaptiveShareStatus = "Auto · holding current quality"
                    }
                }
            }
            startAdaptiveQualityMonitoring()
        } else {
            adaptiveQualityTask?.cancel()
            adaptiveQualityTask = nil
            adaptiveShareStatus = nil
            if let track = shareTrack, let capturer = track.capturer as? MacOSScreenCapturer {
                let quality = screenShareQuality
                Task { try? await capturer.updateScreenShareSettings(dimensions: quality.dimensions,
                                                                      fps: quality.framesPerSecond) }
            }
        }
    }

    private func startAdaptiveQualityMonitoring() {
        adaptiveQualityTask?.cancel()
        guard adaptiveQualityEnabled, isSharing else { return }
        adaptiveQualityTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.isSharing, self.adaptiveQualityEnabled else { return }
                await self.evaluateAdaptiveQuality()
            }
        }
    }

    private func evaluateAdaptiveQuality() async {
        guard adaptiveQualityEnabled,
              let track = shareTrack,
              let statistics = track.statistics,
              var controller = adaptiveShareController else { return }
        let selectedPairID = statistics.transportStats?.selectedCandidatePairId
        let availableBitrate = statistics.iceCandidatePair
            .first(where: { $0.id == selectedPairID })?.availableOutgoingBitrate
        let outbound = statistics.outboundRtpStream.first
        let now = ProcessInfo.processInfo.systemUptime
        let recentFeedback = viewerQualityFeedback.values.filter { now - $0.receivedAtUptime <= 10 }
        let receiverLimited = recentFeedback.contains { feedback in
            (feedback.packetLossPercent ?? 0) >= 3 || (feedback.roundTripMilliseconds ?? 0) > 350
        }
        let receiversHealthy = !recentFeedback.isEmpty && recentFeedback.allSatisfy { feedback in
            (feedback.packetLossPercent ?? 0) <= 1 && (feedback.roundTripMilliseconds ?? 0) <= 250
        }
        let signal = AdaptiveShareSignal(
            availableOutgoingBitrate: availableBitrate,
            bandwidthLimited: outbound?.qualityLimitationReason == .bandwidth,
            cpuLimited: outbound?.qualityLimitationReason == .cpu,
            receiverLimited: receiverLimited,
            receiversHealthy: receiversHealthy
        )
        guard let next = controller.observe(signal) else {
            adaptiveShareController = controller
            let constrained = signal.bandwidthLimited || signal.cpuLimited || signal.receiverLimited ||
                (signal.availableOutgoingBitrate.map { $0 < controller.current.bitrateBudget * 1.15 } ?? false)
            if controller.current == .q1080, constrained {
                adaptiveShareStatus = "Auto · 1080p30 floor · constrained"
            }
            return
        }
        adaptiveShareController = controller
        guard let capturer = track.capturer as? MacOSScreenCapturer else { return }
        do {
            try await capturer.updateScreenShareSettings(dimensions: next.dimensions, fps: next.fps)
            adaptiveShareStatus = "Auto · \(next.title)"
        } catch {
            adaptiveShareController = AdaptiveShareController(maximum: screenShareQuality)
            adaptiveShareStatus = "Auto · holding current quality"
        }
    }

    /// Audio leaves the SDK renderer only after an explicit local transcription opt-in.
    func setAudioForwardingConsented(_ enabled: Bool) {
        audioForwardingConsented = enabled
    }

    func startScreenShare(contentFilter: SCContentFilter, sourceRect: CGRect = .zero) async throws {
        guard !isSharing, !isStartingShare else { throw LiveKitError(.invalidState, message: "Screen sharing is already active or starting.") }
        isStartingShare = true
        defer { isStartingShare = false }
        guard let room, connected else { throw LiveKitError(.invalidState, message: "Not connected") }
        guard room.participantCount <= 4 else { throw LiveKitError(.invalidState, message: "This room is limited to four participants.") }
        refreshSharer()
        guard activeSharerIdentity == nil || activeSharerIdentity == localIdentity else {
            throw LiveKitError(.invalidState, message: "Someone else is already sharing their screen.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !room.localParticipant.permissions.canPublishSources.contains(Track.Source.screenShareVideo.rawValue) {
            guard connected, self.room === room, ProcessInfo.processInfo.systemUptime < deadline else {
                throw LiveKitError(.invalidState, message: "Screen sharing permission was not received. Try sharing again.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        var pendingTrack: LocalVideoTrack?
        do {
            let selectedWindow = contentFilter.style == .window
            let displayBounds: CGRect?
            if #available(macOS 15.2, *), !selectedWindow, let display = contentFilter.includedDisplays.first {
                displayBounds = CGDisplayBounds(display.displayID)
            } else { displayBounds = nil }
            let selectedFrame: CGRect?
            if let displayBounds {
                selectedFrame = sourceRect.isEmpty
                    ? displayBounds
                    : CGRect(x: displayBounds.minX + sourceRect.minX,
                             y: displayBounds.minY + sourceRect.minY,
                             width: sourceRect.width,
                             height: sourceRect.height)
            } else if !selectedWindow, NSScreen.screens.count == 1 {
                selectedFrame = sourceRect.isEmpty ? contentFilter.contentRect : sourceRect
            } else { selectedFrame = nil }
            let canControlDisplay = selectedFrame != nil && AXIsProcessTrusted()
            // Older viewers infer view-only from the ".window" suffix; newer
            // ones also receive explicit availability messages.
            let trackName = selectedWindow ? "pairdesk.screen.window" : "pairdesk.screen.display"
            let quality = screenShareQuality
            let captureOptions = ScreenShareCaptureOptions(dimensions: quality.dimensions,
                                                           fps: quality.framesPerSecond,
                                                           showCursor: true,
                                                           appAudio: false,
                                                           includeCurrentApplication: true,
                                                           sourceRect: sourceRect)
            let track = await LocalVideoTrack.createMacOSScreenShareTrack(name: trackName,
                                                                          contentFilter: contentFilter,
                                                                          options: captureOptions,
                                                                          reportStatistics: true)
            pendingTrack = track
            let publishOptions = VideoPublishOptions(name: trackName,
                                                     screenShareEncoding: VideoEncoding(maxBitrate: quality.maxBitrate,
                                                                                         maxFps: quality.framesPerSecond),
                                                     simulcast: false)
            _ = try await room.localParticipant.publish(videoTrack: track, options: publishOptions)
            guard self.room === room, connected else {
                _ = try? await track.capturer.stopCapture()
                throw LiveKitError(.invalidState, message: "The call ended while screen sharing was starting.")
            }
            shareTrack = track
            track.capturer.add(delegate: self)
            shareBounds = selectedWindow ? nil : selectedFrame
            cursorSessionID = selectedFrame == nil ? nil : UUID().uuidString
            shareIsWindow = selectedWindow
            remoteControlAvailable = !shareIsWindow && canControlDisplay
            remoteControlManuallyPaused = false
            automaticControlEnabled = remoteControlAvailable
            if automaticControlEnabled { controlArbiter.enable() }
            adaptiveShareController = AdaptiveShareController(maximum: quality)
            adaptiveShareStatus = adaptiveQualityEnabled ? "Auto · \(adaptiveShareController?.current.title ?? quality.title)" : nil
            screenTrack = track
            isSharing = true
            if #available(macOS 15.2, *), selectedWindow, let window = contentFilter.includedWindows.first {
                sharingIndicator.show(.window(window.windowID))
            } else if !selectedWindow {
                let displayID: CGDirectDisplayID?
                if #available(macOS 15.2, *) {
                    displayID = contentFilter.includedDisplays.first?.displayID
                } else if NSScreen.screens.count == 1 {
                    displayID = (NSScreen.screens.first?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                } else { displayID = nil }
                if let displayID { sharingIndicator.show(.display(displayID, crop: sourceRect)) }
            }
            activeSharerIdentity = localIdentity
            controlState = .host
            status = selectedWindow
                ? "Sharing window · remote control unavailable"
                : (automaticControlEnabled ? "Sharing display · teammates can control when they interact" : "Sharing display · remote control unavailable")
            sendControl(.init(epoch: UUID().uuidString, sequence: nextSequence(), kind: .releaseAll))
            startAccessibilityMonitor()
            sendControlAvailability()
            startAdaptiveQualityMonitoring()
            pendingTrack = nil
        } catch {
            if let pendingTrack { _ = try? await pendingTrack.capturer.stopCapture() }
            self.error = "Screen sharing failed: \(error.localizedDescription)"
            throw error
        }
    }

    func stopScreenShare() async {
        guard !isStoppingShare, let room, let track = shareTrack else { return }
        isStoppingShare = true
        defer { isStoppingShare = false }
        adaptiveQualityTask?.cancel()
        adaptiveQualityTask = nil
        adaptiveShareController = nil
        adaptiveShareStatus = nil
        accessibilityMonitorTask?.cancel()
        accessibilityMonitorTask = nil
        revokeControl()
        resetIndependentCursors()
        guard let publication = room.localParticipant.localVideoTracks.first(where: { $0.track === track }) else {
            do { _ = try await track.capturer.stopCapture() }
            catch { self.error = error.localizedDescription; return }
            shareTrack = nil
            screenTrack = nil
            shareBounds = nil
            remoteControlAvailable = false
            automaticControlEnabled = false
            controlArbiter.disable()
            isSharing = false
            if activeSharerIdentity == localIdentity { activeSharerIdentity = nil }
            controlState = .viewer
            return
        }
        do { try await room.localParticipant.unpublish(publication: publication) }
        catch {
            self.error = "Could not stop screen sharing cleanly: \(error.localizedDescription)"
            remoteControlAvailable = false
            do { _ = try await track.capturer.stopCapture() }
            catch { return }
        }
        shareTrack = nil
        screenTrack = nil
        shareBounds = nil
        remoteControlAvailable = false
        automaticControlEnabled = false
        controlArbiter.disable()
        isSharing = false
        if activeSharerIdentity == localIdentity { activeSharerIdentity = nil }
        controlState = .viewer
        status = "Screen sharing stopped"
    }

    nonisolated func capturer(_ capturer: VideoCapturer, didUpdate state: VideoCapturer.CapturerState) {
        guard state == .stopped else { return }
        Task { @MainActor [weak self] in
            guard let self, self.shareTrack?.capturer === capturer else { return }
            // Includes the macOS Stop Sharing control and capture failures.
            self.sharingIndicator.hide()
            self.revokeControl()
            // LiveKit already unpublishes stopped screen capturers. Finish
            // local cleanup in didUnpublishTrack instead of racing that request.
        }
    }

    nonisolated func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room,
                  let track = self.shareTrack, publication.track === track else { return }
            await self.stopScreenShare()
        }
    }

    func requestControl() {
        guard canRequestRemoteControl,
              controlState == .viewer || controlState == .hostPermissionRequired,
              ProcessInfo.processInfo.systemUptime - lastControlRequestAt >= 1 else { return }
        lastControlRequestAt = ProcessInfo.processInfo.systemUptime
        controlState = .requesting
        sendControl(.init(epoch: "", sequence: nextSequence(), kind: .request,
                          cursorSession: usesIndependentCursors ? cursorSessionID : nil))
        // An older host ignores requests it cannot grant; don't show
        // "Connecting remote control…" forever.
        requestTimeoutTask?.cancel()
        requestTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, case .requesting = self.controlState else { return }
            self.controlState = .viewer
            self.queuedLocalIntents.removeAll()
            self.localHeldKeys.removeAll()
            self.localHeldButtons.removeAll()
        }
    }

    func grantControl(identity: String) {
        guard !controlTransportFailed, controlArbiter.driverIdentity == identity else { return }
        sendGrant(to: identity)
    }

    private func sendGrant(to identity: String) {
        guard isSharing, automaticControlEnabled, !shareIsWindow else { return }
        guard AXIsProcessTrusted() else {
            error = "Enable PairDesk in System Settings → Privacy & Security → Accessibility to continue remote control."
            pauseRemoteControl(userInitiated: false)
            return
        }
        guard room?.remoteParticipants.values.contains(where: { $0.identity?.stringValue == identity }) == true else {
            if let next = controlArbiter.release(identity: identity) { sendGrant(to: next) }
            return
        }
        if controlGate.driverIdentity == identity { releaseInjectedInputs() }
        let epoch = UUID().uuidString
        controlGate.grant(identity: identity, epoch: epoch)
        controlState = .granted(identity: identity, expiresAt: .now.addingTimeInterval(2))
        pendingControlRequests.removeAll { $0.identity == identity }
        sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .grant, leaseMilliseconds: 2_000), to: identity)
        startLeaseWatch()
    }

    /// Pauses automatic control for the rest of this share until explicitly resumed.
    func pauseRemoteControl(userInitiated: Bool = true) {
        guard isSharing else { return }
        if userInitiated { remoteControlManuallyPaused = true }
        let waiting = pendingControlRequests.map(\.identity)
        automaticControlEnabled = false
        controlArbiter.disable()
        revokeActiveLease(notifyDriver: true)
        for identity in waiting {
            sendControl(.init(epoch: "", sequence: nextSequence(), kind: .revoke), to: identity)
        }
        pendingControlRequests.removeAll()
        controlState = .host
        sendControlAvailability()
    }

    func resumeRemoteControl() {
        guard isSharing, remoteControlAvailable, !controlTransportFailed, AXIsProcessTrusted() else { return }
        remoteControlManuallyPaused = false
        automaticControlEnabled = true
        controlArbiter.enable()
        controlState = .host
        sendControlAvailability()
    }

    /// Host: tells one viewer, or everyone, whether input would be accepted now.
    private func sendControlAvailability(to identity: String? = nil) {
        guard isSharing else { return }
        let state = RemoteControlAvailability.evaluate(sharingWindow: shareIsWindow,
                                                       accessibilityTrusted: AXIsProcessTrusted(),
                                                       automaticControlEnabled: automaticControlEnabled,
                                                       ownerActive: ProcessInfo.processInfo.systemUptime < ownerBusyUntil,
                                                       displayGeometryKnown: shareBounds != nil)
        sendControl(.init(epoch: "", sequence: nextSequence(), kind: .availability,
                          available: state.available, reason: state.reason?.rawValue,
                          cursorSession: shareIsWindow ? nil : cursorSessionID), to: identity)
    }

    /// Viewer: prefer what the host said; fall back to the track name for older hosts.
    private func applyRemoteControlAvailability(from sender: String, trackName: String) {
        if let known = controlAvailabilityBySender[sender] {
            cursorSessionID = known.cursorSession
            applyRemoteControlAvailability(known.available, reason: known.reason)
        } else {
            cursorSessionID = nil
            let isWindow = trackName.hasSuffix(".window")
            applyRemoteControlAvailability(!isWindow, reason: isWindow ? .windowShare : nil)
        }
    }

    private func applyRemoteControlAvailability(_ available: Bool, reason: RemoteControlUnavailableReason?) {
        remoteControlAvailable = available
        remoteControlUnavailableReason = available ? nil : reason
        if available { lastControlRequestAt = -.infinity }
        guard !available else { return }
        requestTimeoutTask?.cancel()
        queuedLocalIntents.removeAll()
        localHeldKeys.removeAll()
        localHeldButtons.removeAll()
        if localControllerEpoch != nil { emergencyStop() }
        if case .requesting = controlState { controlState = .viewer }
    }

    /// Accessibility consent can change while the share is active in System Settings.
    /// Re-check it on the sharing Mac so a newly granted permission takes effect
    /// without forcing the user to stop and restart screen sharing.
    private func startAccessibilityMonitor() {
        accessibilityMonitorTask?.cancel()
        accessibilityMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isSharing, !self.shareIsWindow else { return }
                self.refreshRemoteControlPermission()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func refreshRemoteControlPermission() {
        guard isSharing, !shareIsWindow, shareBounds != nil, !controlTransportFailed else { return }
        let trusted = AXIsProcessTrusted()
        if trusted && !remoteControlAvailable {
            remoteControlAvailable = true
            if !remoteControlManuallyPaused {
                automaticControlEnabled = true
                controlArbiter.enable()
            }
            status = remoteControlManuallyPaused
                ? "Sharing display · remote control is paused"
                : "Sharing display · remote control is ready"
            error = nil
            sendControlAvailability()
        } else if !trusted && remoteControlAvailable {
            remoteControlAvailable = false
            pauseRemoteControl(userInitiated: false)
            status = "Sharing display · enable PairDesk in Accessibility to allow control"
        }
    }

    /// Kept for existing callers; revoking means pausing automatic control.
    func revokeControl() { pauseRemoteControl() }

    private func revokeActiveLease(notifyDriver: Bool) {
        if notifyDriver, let driver = controlGate.driverIdentity, let epoch = controlGate.epoch {
            sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .revoke), to: driver)
        }
        releaseInjectedInputs()
        controlGate.revoke()
        leaseTask?.cancel()
        leaseTask = nil
    }

    /// Bind this to a local emergency shortcut in the app window (e.g. Escape).
    /// It immediately revokes the lease and releases any held remote keys/buttons.
    func emergencyStop() {
        if isSharing { pauseRemoteControl(); return }
        let wasLocalController = localControllerEpoch != nil
        if let epoch = localControllerEpoch {
            sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .release))
        }
        localControllerEpoch = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        controllerIdleTask?.cancel()
        controllerIdleTask = nil
        queuedLocalIntents.removeAll()
        localHeldKeys.removeAll()
        localHeldButtons.removeAll()
        if wasLocalController, connected { controlState = .viewer }
    }

    /// Call when a local owner uses the in-app shared-screen controls.
    func localOwnerInputDetected(restorePointer: Bool = true) {
        guard isSharing else { return }
        ownerBusyUntil = ProcessInfo.processInfo.systemUptime + 0.4
        // A physical owner action takes over immediately; do not warp over it.
        pointerRestoreTask?.cancel()
        if !restorePointer { ownerPointerPosition = nil }
        let waiting = pendingControlRequests.map(\.identity)
        revokeActiveLease(notifyDriver: true)
        controlArbiter.disable()
        if automaticControlEnabled { controlArbiter.enable() }
        for identity in waiting { sendControl(.init(epoch: "", sequence: nextSequence(), kind: .revoke), to: identity) }
        pendingControlRequests.removeAll()
        controlState = .host
        sendControlAvailability()
        ownerActivityTask?.cancel()
        ownerActivityTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(420)) } catch { return }
            guard let self, self.isSharing else { return }
            self.sendControlAvailability()
        }
    }

    /// Clears held keys/buttons on the host while keeping the lease alive.
    func releaseHeldInputs() {
        if let epoch = localControllerEpoch {
            sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .releaseAll))
        }
        queuedLocalIntents.removeAll()
        localHeldKeys.removeAll()
        localHeldButtons.removeAll()
    }

    func sendPointer(x: Double, y: Double) {
        guard !controlTransportFailed, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return }
        if usesIndependentCursors {
            sendCursor(x: x, y: y)
            guard IndependentCursorPolicy.movesSystemCursor(independent: true, heldButtonCount: localHeldButtons.count) else { return }
        }
        guard let epoch = localControllerEpoch else { queueIntent(.pointer(x, y)); return }
        beginActiveInput(epoch: epoch)
        // Motion is lossy and coalesced: a dropped or overtaken sample is
        // replaced by the next one. Clicks carry their own position reliably.
        enqueueLossy(.pointer, .init(epoch: epoch, sequence: nextSequence(), kind: .pointer, x: x, y: y))
    }

    func sendKey(code: UInt16, down: Bool, modifiers: UInt64 = 0) {
        guard !controlTransportFailed, code < 128 else { return }
        guard canRequestRemoteControl else { return }
        if down { localHeldKeys.insert(code) } else { localHeldKeys.remove(code) }
        guard let epoch = localControllerEpoch else { queueIntent(.key(code, down, modifiers)); return }
        beginActiveInput(epoch: epoch)
        let deviceIndependentFlags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
            .intersection(.deviceIndependentFlagsMask).rawValue
        let sanitizedModifiers = UInt64(deviceIndependentFlags) & Self.allowedModifierMask
        sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .key,
                          code: code, down: down, modifiers: sanitizedModifiers))
    }

    func sendButton(button: Int, down: Bool, x: Double, y: Double) {
        guard !controlTransportFailed, [0, 1, 2].contains(button), x.isFinite, y.isFinite,
              (0...1).contains(x), (0...1).contains(y)
        else { return }
        guard canRequestRemoteControl else { return }
        if down { localHeldButtons.insert(button) } else { localHeldButtons.remove(button) }
        guard let epoch = localControllerEpoch else { queueIntent(.button(button, down, x, y)); return }
        beginActiveInput(epoch: epoch)
        sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .button, x: x, y: y,
                          code: UInt16(button), down: down))
    }

    func sendScroll(dx: Double, dy: Double, x: Double? = nil, y: Double? = nil) {
        guard !controlTransportFailed, dx.isFinite, dy.isFinite, abs(dx) <= 200, abs(dy) <= 200
        else { return }
        guard let epoch = localControllerEpoch else { queueIntent(.scroll(dx, dy, x, y)); return }
        beginActiveInput(epoch: epoch)
        if pendingScroll?.epoch != epoch { pendingScroll = nil }
        if var pending = pendingScroll {
            if abs(pending.dx + dx) <= 200, abs(pending.dy + dy) <= 200 {
                pending.dx += dx
                pending.dy += dy
                pending.x = x ?? pending.x
                pending.y = y ?? pending.y
                pendingScroll = pending
                return
            }
            flushPendingScroll()
        }
        if scrollFlushTask == nil {
            sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .scroll, x: x, y: y, deltaX: dx, deltaY: dy))
            scheduleScrollFlush()
        } else {
            pendingScroll = (epoch, dx, dy, x, y)
        }
    }

    private func scheduleScrollFlush() {
        scrollFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, let self else { return }
            self.scrollFlushTask = nil
            self.flushPendingScroll()
        }
    }

    /// Sends the summed deltas and keeps the 16 ms window open while the
    /// scroll continues, so a long trackpad scroll is at most 60 messages/s.
    private func flushPendingScroll() {
        guard let pending = pendingScroll else { return }
        pendingScroll = nil
        guard pending.epoch == localControllerEpoch else { return }
        sendControl(.init(epoch: pending.epoch, sequence: nextSequence(), kind: .scroll,
                          x: pending.x, y: pending.y, deltaX: pending.dx, deltaY: pending.dy))
        scrollFlushTask?.cancel()
        scheduleScrollFlush()
    }

    // MARK: RoomDelegate

    nonisolated func roomDidConnect(_ room: Room) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.connected = true
            self.setReconnecting(false)
            self.refreshParticipants()
            self.refreshSharer()
        }
    }

    nonisolated func roomIsReconnecting(_ room: Room) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.setReconnecting(true)
        }
    }

    nonisolated func room(_ room: Room, didStartReconnectWithMode reconnectMode: ReconnectMode) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.setReconnecting(true)
        }
    }

    nonisolated func roomDidReconnect(_ room: Room) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.setReconnecting(false)
            self.refreshParticipants()
            self.refreshSharer()
        }
    }

    nonisolated func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.setReconnecting(false)
            self.refreshParticipants()
            self.refreshSharer()
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.emergencyStop()
            self.detachAudioRenderers()
            self.connected = false
            self.isReconnecting = false
            self.resumeControlAfterReconnect = false
            self.error = error?.localizedDescription
            self.status = "Disconnected"
            self.isSharing = false
            self.isMicrophoneEnabled = false
            self.shareTrack = nil
            self.shareBounds = nil
            self.shareIsWindow = false
            self.remoteControlAvailable = false
            self.automaticControlEnabled = false
            self.controlArbiter.disable()
            self.screenTrack = nil
            self.activeSharerIdentity = nil
            self.remotePointers = []
            self.pendingControlRequests = []
            self.requestTimeoutTask?.cancel()
            self.requestTimeoutTask = nil
            self.controlAvailabilityBySender.removeAll()
            self.remoteControlUnavailableReason = nil
            self.resetIndependentCursors()
            self.room = nil
            self.controlState = .unavailable
            self.audioForwardingConsented = false
            self.controlTransportFailed = true
            self.incomingClipboardTransfer = nil
            self.clipboardReplayWindow = ClipboardTransferReplayWindow()
            self.setClipboardSyncEnabled(false)
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.refreshParticipants()
            if let identity { self.sendControlAvailability(to: identity) }
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue ?? ""
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            let matches = self.remoteAudioRenderers.filter { $0.value.identity == identity }
            for (sid, attachment) in matches {
                attachment.track.remove(audioRenderer: attachment.renderer)
                self.remoteAudioRenderers.removeValue(forKey: sid)
            }
            self.refreshParticipants()
            self.refreshSharer()
            self.removeRemotePointer(identity)
            self.cursorSequenceBySender.removeValue(forKey: identity)
            self.independentCursorParticipants.remove(identity)
            self.controlAvailabilityBySender.removeValue(forKey: identity)
            self.viewerQualityFeedback.removeValue(forKey: identity)
            self.pendingControlRequests.removeAll { $0.identity == identity }
            if self.controlGateIdentity == identity { self.releaseDriver(sender: identity, notifyDriver: false) }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        let identity = participant.identity?.stringValue ?? ""
        let name = participant.name ?? identity
        if let video = publication.track as? VideoTrack, video.source == .screenShareVideo {
            Task { @MainActor [weak self] in
                guard let self, self.room === room else { return }
                self.screenTrack = video
                self.activeSharerIdentity = identity
                self.applyRemoteControlAvailability(from: identity, trackName: video.name)
                self.refreshSharer()
            }
        }
        if let audio = publication.track as? RemoteAudioTrack {
            Task { @MainActor [weak self] in
                guard let self, self.room === room else { return }
                let renderer = self.makeAudioRenderer(room: room, identity: identity, name: name)
                audio.add(audioRenderer: renderer)
                self.remoteAudioRenderers[publication.sid.stringValue] = (identity, audio, renderer)
            }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        if publication.kind == .video {
            Task { @MainActor [weak self] in
                guard let self, self.room === room else { return }
                if let video = publication.track as? VideoTrack, self.screenTrack === video {
                    self.screenTrack = nil
                    if self.localControllerEpoch != nil { self.emergencyStop() }
                }
                self.refreshSharer()
            }
        }
        if let audio = publication.track as? RemoteAudioTrack {
            Task { @MainActor [weak self] in
                guard let self, self.room === room,
                      let attachment = self.remoteAudioRenderers.removeValue(forKey: publication.sid.stringValue)
                else { return }
                audio.remove(audioRenderer: attachment.renderer)
            }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        guard publication.source == .screenShareVideo else { return }
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.screenTrack = nil
            if self.localControllerEpoch != nil { self.emergencyStop() }
            self.refreshSharer()
        }
    }

    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.refreshParticipants()
        }
    }

    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        guard participant is LocalParticipant, trackPublication.kind == .audio else { return }
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.isMicrophoneEnabled = !isMuted
            if isMuted { self.detachLocalAudioRenderer() }
            else { self.attachLocalAudioRenderer() }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        if topic == Self.clipboardTopic, data.count <= ClipboardTransferMessage.maximumWireBytes,
           let sender = participant?.identity?.stringValue {
            Task { @MainActor [weak self] in
                guard let self, self.room === room, let localIdentity = self.localIdentity,
                      room.remoteParticipants.values.contains(where: { $0.identity?.stringValue == sender }),
                      let part = try? ClipboardTransferMessage.decode(data, authenticatedSender: sender, localIdentity: localIdentity),
                      let message = self.clipboardAssembler.add(part, from: sender),
                      self.clipboardReplayWindow.insert(message.id) else { return }
                if self.clipboardSyncEnabled {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                    self.clipboardObservedChangeCount = NSPasteboard.general.changeCount
                    self.lastSharedClipboardText = message.text
                    self.clipboardSyncNotice = "Clipboard synced from \(self.participantName(for: sender))"
                    return
                }
                self.incomingClipboardTransfer = (self.participantName(for: sender), message)
            }
            return
        }
        guard topic == Self.controlTopic, data.count <= 2_048,
              let message = try? JSONDecoder().decode(RemoteControlMessage.self, from: data),
              let sender = participant?.identity?.stringValue
        else { return }
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.receive(message, sender: sender)
        }
    }

    // MARK: Data protocol

    nonisolated private static let controlTopic = "pairdesk.control.v1"
    nonisolated private static let clipboardTopic = "pairdesk.clipboard.v1"

    /// Sends text only after the user explicitly presses Send clipboard.
    func sendClipboard(text: String, to identity: String) async throws {
        guard let room, connected, identity != localIdentity,
              room.remoteParticipants.values.contains(where: { $0.identity?.stringValue == identity }) else {
            throw LiveKitError(.invalidState, message: "That teammate is no longer in this call.")
        }
        // Every part is encoded before any is sent, so an oversized clip fails whole.
        let packets = try ClipboardTransferMessage.parts(recipientIdentity: identity, text: text).map { try $0.encoded() }
        let options = DataPublishOptions(name: "PairDesk clipboard", destinationIdentities: [Participant.Identity(from: identity)], topic: Self.clipboardTopic, reliable: true)
        for data in packets {
            try await room.localParticipant.publish(data: data, options: options)
        }
    }

    func pasteIncomingClipboardTransfer() {
        guard let transfer = incomingClipboardTransfer else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transfer.message.text, forType: .string)
        incomingClipboardTransfer = nil
    }

    func dismissIncomingClipboardTransfer() { incomingClipboardTransfer = nil }

    /// Clipboard sync is opt-in on each Mac, applies only to plain text during
    /// this call, and is disabled again when the room disconnects.
    func setClipboardSyncEnabled(_ enabled: Bool) {
        clipboardSyncTask?.cancel()
        clipboardSyncTask = nil
        clipboardSyncEnabled = enabled && connected
        clipboardSyncNotice = clipboardSyncEnabled ? "Text clipboard sync is on for this call" : nil
        lastSharedClipboardText = nil
        clipboardObservedChangeCount = NSPasteboard.general.changeCount
        guard clipboardSyncEnabled else { return }
        clipboardSyncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.connected, self.clipboardSyncEnabled else { return }
                self.checkClipboardForChanges()
            }
        }
    }

    private func checkClipboardForChanges() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != clipboardObservedChangeCount else { return }
        clipboardObservedChangeCount = changeCount
        let types = ((pasteboard.pasteboardItems ?? []).flatMap(\.types) + (pasteboard.types ?? [])).map(\.rawValue)
        guard ClipboardSyncPolicy.mayShare(pasteboardTypes: types) else {
            clipboardSyncNotice = "Private text from a password manager wasn't shared"
            return
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty, text != lastSharedClipboardText else { return }
        guard text.utf8.count <= ClipboardTransferMessage.maximumTextBytes else {
            clipboardSyncNotice = "Copied text is over the 64 KB limit and wasn't shared"
            return
        }
        lastSharedClipboardText = text
        for person in participants where !person.isLocal {
            Task { @MainActor [weak self] in
                do { try await self?.sendClipboard(text: text, to: person.identity) }
                catch { self?.clipboardSyncNotice = "Couldn't share copied text: \(error.localizedDescription)" }
            }
        }
        clipboardSyncNotice = "Copied text shared with teammates on this call"
    }
    private static let allowedModifierMask = CGEventFlags.maskShift.rawValue |
        CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue |
        CGEventFlags.maskCommand.rawValue | CGEventFlags.maskSecondaryFn.rawValue

    private var controlGateIdentity: String? { controlGate.driverIdentity }
    var canRequestRemoteControl: Bool {
        connected && remoteControlAvailable && activeSharerIdentity != nil && activeSharerIdentity != localIdentity
    }

    private func receive(_ message: RemoteControlMessage, sender: String) {
        guard let localIdentity else { return }
        if message.kind == .pointer, !isSharing {
            guard let sharer = activeSharerIdentity, sender != localIdentity, sender != sharer,
                  room?.remoteParticipants.values.contains(where: { $0.identity?.stringValue == sender }) == true,
                  let x = message.x, let y = message.y,
                  x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y)
            else { return }
            recordRemotePointer(identity: sender, x: x, y: y)
            return
        }
        switch message.kind {
        case .qualityFeedback:
            guard isSharing, sender != localIdentity,
                  room?.remoteParticipants.values.contains(where: { $0.identity?.stringValue == sender }) == true,
                  message.epoch == cursorSessionID,
                  message.sequence > (viewerQualityFeedback[sender]?.sequence ?? 0),
                  (message.packetLossPercent.map { $0.isFinite && (0...100).contains($0) } ?? false)
                    || (message.roundTripMilliseconds.map { (0...60_000).contains($0) } ?? false)
            else { return }
            viewerQualityFeedback[sender] = ViewerQualityFeedback(
                sequence: message.sequence,
                packetLossPercent: message.packetLossPercent,
                roundTripMilliseconds: message.roundTripMilliseconds,
                receivedAtUptime: ProcessInfo.processInfo.systemUptime
            )
            return
        case .request:
            guard isSharing, sender != localIdentity else { return }
            // The request is reliable and may arrive before the lossy cursor
            // presence packet. Remember the negotiated mode before the first
            // queued click is replayed after a grant.
            if !shareIsWindow, message.cursorSession == cursorSessionID,
               cursorSessionID != nil {
                independentCursorParticipants.insert(sender)
            }
            guard !shareIsWindow, automaticControlEnabled,
                  ProcessInfo.processInfo.systemUptime >= ownerBusyUntil else {
                // End legacy viewers' pending requests and tell newer viewers why.
                let kind: RemoteControlMessage.Kind = !shareIsWindow && !AXIsProcessTrusted() ? .hostPermissionRequired : .revoke
                sendControl(.init(epoch: "", sequence: nextSequence(), kind: kind), to: sender)
                sendControlAvailability(to: sender)
                return
            }
            let name = room?.remoteParticipants.values.first(where: { $0.identity?.stringValue == sender })?.name ?? sender
            if controlArbiter.driverIdentity == sender, controlGate.isActive {
                sendGrant(to: sender)
                return
            }
            if controlArbiter.driverIdentity == sender, !controlGate.isActive {
                releaseDriver(sender: sender, notifyDriver: false)
            }
            switch controlArbiter.request(identity: sender) {
            case .grant: sendGrant(to: sender)
            case .queued:
                if !pendingControlRequests.contains(where: { $0.identity == sender }) {
                    pendingControlRequests.append(CallParticipant(identity: sender, name: name, isLocal: false))
                }
            case .ignored: break
            }
        case .availability:
            guard !isSharing, sender != localIdentity, let available = message.available else { return }
            let reason = message.reason.flatMap(RemoteControlUnavailableReason.init(rawValue:))
            let session = message.cursorSession.flatMap { $0.isEmpty ? nil : $0 }
            controlAvailabilityBySender[sender] = (available, reason, session)
            if sender == activeSharerIdentity {
                cursorSessionID = session
                applyRemoteControlAvailability(available, reason: reason)
            }
        case .cursor:
            guard isSharing, !shareIsWindow,
                  IndependentCursorPolicy.accepts(message, session: cursorSessionID,
                    isParticipant: sender != localIdentity && room?.remoteParticipants.values.contains(where: { $0.identity?.stringValue == sender }) == true,
                    lastSequence: cursorSequenceBySender[sender]) else { return }
            cursorSequenceBySender[sender] = message.sequence
            independentCursorParticipants.insert(sender)
            if message.visible == false { removeRemotePointer(sender) }
            else if let x = message.x, let y = message.y { recordRemotePointer(identity: sender, x: x, y: y) }
            relayCursor(message, identity: sender)
        case .cursorBroadcast:
            guard !isSharing,
                  let pointerIdentity = message.pointerIdentity,
                  IndependentCursorPolicy.acceptsBroadcast(message, session: cursorSessionID,
                    senderIsSharer: sender == activeSharerIdentity,
                    pointerIsParticipant: room?.remoteParticipants.values.contains(where: { $0.identity?.stringValue == pointerIdentity }) == true,
                    viewerIdentity: localIdentity,
                    lastSequence: cursorSequenceBySender[pointerIdentity]) else { return }
            cursorSequenceBySender[pointerIdentity] = message.sequence
            if message.visible == false { removeRemotePointer(pointerIdentity) }
            else if let x = message.x, let y = message.y { recordRemotePointer(identity: pointerIdentity, x: x, y: y) }
        case .grant:
            guard sender == activeSharerIdentity, !message.epoch.isEmpty,
                  case .requesting = controlState else { return }
            requestTimeoutTask?.cancel()
            localControllerEpoch = message.epoch
            controlState = .granted(identity: sender, expiresAt: .now.addingTimeInterval(2))
            let queued = queuedLocalIntents
            queuedLocalIntents.removeAll()
            if !queued.isEmpty {
                beginActiveInput(epoch: message.epoch)
                queued.forEach { sendIntent($0) }
            } else { scheduleLocalIdleExpiry(epoch: message.epoch) }
        case .revoke:
            guard sender == activeSharerIdentity else { return }
            requestTimeoutTask?.cancel()
            localControllerEpoch = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
            controllerIdleTask?.cancel()
            controllerIdleTask = nil
            queuedLocalIntents.removeAll()
            localHeldKeys.removeAll()
            localHeldButtons.removeAll()
            controlState = .viewer
        case .hostPermissionRequired:
            guard sender == activeSharerIdentity, case .requesting = controlState else { return }
            requestTimeoutTask?.cancel()
            localControllerEpoch = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
            controllerIdleTask?.cancel()
            controllerIdleTask = nil
            queuedLocalIntents.removeAll()
            localHeldKeys.removeAll()
            localHeldButtons.removeAll()
            controlState = .hostPermissionRequired
        case .heartbeat, .pointer, .key, .button, .scroll, .releaseAll, .release:
            guard isSharing,
                  controlGate.accept(message, sender: sender),
                  let expiryUptime = controlGate.expiresAtUptime
            else { return }
            if message.kind == .release {
                releaseDriver(sender: sender, notifyDriver: false)
                return
            }
            let expiry = Date().addingTimeInterval(max(0, expiryUptime - ProcessInfo.processInfo.systemUptime))
            controlState = .granted(identity: sender, expiresAt: expiry)
            if message.kind == .pointer, let x = message.x, let y = message.y,
               x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) {
                recordRemotePointer(identity: sender, x: x, y: y)
                if !shareIsWindow, let bounds = shareBounds,
                   IndependentCursorPolicy.movesSystemCursor(independent: independentCursorParticipants.contains(sender), heldButtonCount: heldButtons.count) {
                    let activeButton = [0, 1, 2].first(where: heldButtons.contains)
                        .flatMap { CGMouseButton(rawValue: UInt32($0)) }
                    if !RemoteInputInjector.movePointer(x: x, y: y, in: bounds, draggingButton: activeButton) {
                        reportRemoteInputFailure()
                        return
                    }
                }
            } else if message.kind == .key, let code = message.code, let down = message.down {
                guard code < 128, (message.modifiers ?? 0) & ~Self.allowedModifierMask == 0 else { return }
                let flags = CGEventFlags(rawValue: message.modifiers ?? 0)
                if RemoteInputInjector.key(code: code, down: down, modifiers: flags) {
                    if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
                } else { reportRemoteInputFailure(); return }
            } else if message.kind == .button, let code = message.code, code <= 2, let down = message.down,
                      let x = message.x, let y = message.y, x.isFinite, y.isFinite,
                      (0...1).contains(x), (0...1).contains(y), !shareIsWindow,
                      let bounds = shareBounds, let button = CGMouseButton(rawValue: UInt32(code)) {
                guard let point = RemoteInputInjector.point(x: x, y: y, in: bounds) else { return }
                if down, independentCursorParticipants.contains(sender), ownerPointerPosition == nil {
                    pointerRestoreTask?.cancel()
                    ownerPointerPosition = RemoteInputInjector.currentPointerPosition
                }
                if RemoteInputInjector.button(button, down: down, at: point) {
                    if down { heldButtons.insert(Int(code)) } else { heldButtons.remove(Int(code)) }
                    if !down && heldButtons.isEmpty { scheduleOwnerPointerRestore() }
                } else { reportRemoteInputFailure(); return }
            } else if message.kind == .scroll,
                      let dx = message.deltaX, let dy = message.deltaY,
                      dx.isFinite, dy.isFinite, abs(dx) <= 200, abs(dy) <= 200,
                      !shareIsWindow {
                let point = message.x.flatMap { x in message.y.flatMap { y in shareBounds.flatMap { RemoteInputInjector.point(x: x, y: y, in: $0) } } }
                if !RemoteInputInjector.scroll(deltaX: dx, deltaY: dy, at: point) {
                    reportRemoteInputFailure()
                    return
                }
            }
            else if message.kind == .releaseAll { releaseInjectedInputs() }
            startLeaseWatch()
        }
    }

    private func recordRemotePointer(identity: String, x: Double, y: Double) {
        remotePointers.removeAll { $0.id == identity }
        remotePointers.append(RemotePointer(id: identity, x: x, y: y, updatedAt: Date()))
        guard cursorExpiryTask == nil else { return }
        cursorExpiryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                self.remotePointers.removeAll { Date().timeIntervalSince($0.updatedAt) > 3 }
                if self.remotePointers.isEmpty { self.cursorExpiryTask = nil; return }
            }
        }
    }

    private func removeRemotePointer(_ identity: String) {
        remotePointers.removeAll { $0.id == identity }
    }

    /// Cursor presence is lossy, coalesced and separate from the ordered action
    /// queue. Moving a pointer can never acquire a control lease or flood clicks.
    func sendCursor(x: Double? = nil, y: Double? = nil, visible: Bool = true) {
        guard connected, usesIndependentCursors, let session = cursorSessionID,
              let sharer = activeSharerIdentity else { return }
        if visible, let x, let y, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) {
            localCursorPosition = CGPoint(x: x, y: y)
        } else if !visible {
            localCursorPosition = nil
        }
        enqueueLossy(.cursor, .init(epoch: session, sequence: nextSequence(), kind: .cursor, x: x, y: y, visible: visible), to: sharer)
    }

    /// One loop publishes the newest sample of each slot on the lossy channel,
    /// then waits 16 ms, and exits once nothing is pending. A sample whose
    /// control epoch or cursor session has ended is dropped before publishing.
    private func enqueueLossy(_ slot: LossySlot, _ message: RemoteControlMessage, to destination: String? = nil) {
        pendingLossy[slot] = (message, destination)
        guard lossySendTask == nil, let room else { return }
        lossySendTask = Task { @MainActor [weak self] in
            while true {
                guard let self, self.room === room, !self.pendingLossy.isEmpty else { break }
                let batch = self.pendingLossy
                self.pendingLossy.removeAll()
                for (slot, item) in batch {
                    switch slot {
                    case .pointer:
                        guard item.message.epoch == self.localControllerEpoch, !self.controlTransportFailed else { continue }
                    case .cursor:
                        guard item.message.epoch == self.cursorSessionID else { continue }
                    }
                    guard let data = try? JSONEncoder().encode(item.message) else { continue }
                    let destinations = item.destination.map { [Participant.Identity(from: $0)] } ?? []
                    let options = DataPublishOptions(destinationIdentities: destinations, topic: Self.controlTopic, reliable: false)
                    try? await room.localParticipant.publish(data: data, options: options)
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
            self?.lossySendTask = nil
        }
    }

    private func relayCursor(_ cursor: RemoteControlMessage, identity: String) {
        guard isSharing, !shareIsWindow, let room,
              let session = cursorSessionID else { return }
        let destinations = room.remoteParticipants.values.compactMap { participant -> Participant.Identity? in
            guard participant.identity?.stringValue != identity else { return nil }
            return participant.identity
        }
        guard !destinations.isEmpty else { return }
        var relay = cursor
        relay.kind = .cursorBroadcast
        relay.sequence = nextSequence()
        relay.pointerIdentity = identity
        relay.epoch = session
        guard let data = try? JSONEncoder().encode(relay) else { return }
        Task {
            let options = DataPublishOptions(destinationIdentities: destinations, topic: Self.controlTopic, reliable: false)
            try? await room.localParticipant.publish(data: data, options: options)
        }
    }

    private func scheduleOwnerPointerRestore() {
        guard ownerPointerPosition != nil else { return }
        pointerRestoreTask?.cancel()
        pointerRestoreTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            guard let self, self.heldButtons.isEmpty, let point = self.ownerPointerPosition else { return }
            RemoteInputInjector.restorePointer(to: point)
            self.ownerPointerPosition = nil
            self.pointerRestoreTask = nil
        }
    }

    private func resetIndependentCursors() {
        cursorSessionID = nil
        localCursorPosition = nil
        pendingLossy[.cursor] = nil
        cursorExpiryTask?.cancel(); cursorExpiryTask = nil
        remotePointers.removeAll()
        viewerQualityFeedback.removeAll()
        cursorSequenceBySender.removeAll()
        independentCursorParticipants.removeAll()
        ownerActivityTask?.cancel(); ownerActivityTask = nil
        ownerBusyUntil = 0
        scheduleOwnerPointerRestore()
    }

    private func reportRemoteInputFailure() {
        error = AXIsProcessTrusted()
            ? "PairDesk couldn't send remote input. Check that Accessibility is enabled for the PairDesk copy in Applications, then restart PairDesk."
            : "Accessibility access is off for PairDesk. Enable it in System Settings to let teammates control this Mac."
        pauseRemoteControl()
    }

    private func sendControl(_ message: RemoteControlMessage, to identity: String? = nil) {
        guard let room, !controlTransportFailed,
              let data = try? JSONEncoder().encode(message)
        else { return }
        guard queuedControlSends < maxQueuedControlSends else {
            failControlTransport("Remote-control message queue is full; the control lease was closed.")
            return
        }
        let destinations = identity.map { [Participant.Identity(from: $0)] } ?? []
        let options = DataPublishOptions(name: "PairDesk control",
                                         destinationIdentities: destinations,
                                         topic: Self.controlTopic,
                                         reliable: true)
        let previous = controlSendTail
        queuedControlSends += 1
        controlSendTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            guard self.room === room, !self.controlTransportFailed else {
                self.queuedControlSends = max(0, self.queuedControlSends - 1)
                return
            }
            do {
                try await room.localParticipant.publish(data: data, options: options)
                self.queuedControlSends = max(0, self.queuedControlSends - 1)
            } catch {
                self.queuedControlSends = max(0, self.queuedControlSends - 1)
                self.failControlTransport("Control message failed: \(error.localizedDescription)")
            }
        }
    }

    private func failControlTransport(_ message: String) {
        guard !controlTransportFailed else { return }
        controlTransportFailed = true
        error = message
        heartbeatTask?.cancel()
        heartbeatTask = nil
        controllerIdleTask?.cancel()
        controllerIdleTask = nil
        automaticControlEnabled = false
        controlArbiter.disable()
        localControllerEpoch = nil
        queuedLocalIntents.removeAll()
        localHeldKeys.removeAll()
        localHeldButtons.removeAll()
        releaseInjectedInputs()
        controlGate.revoke()
        if connected { controlState = isSharing ? .host : .viewer }
    }

    private func nextSequence() -> UInt64 { localSequence &+= 1; return localSequence }

    private func startHeartbeat(epoch: String) {
        heartbeatTask?.cancel()
        sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .heartbeat, leaseMilliseconds: 2_000))
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self, self.localControllerEpoch == epoch else { return }
                self.sendControl(.init(epoch: epoch, sequence: self.nextSequence(), kind: .heartbeat, leaseMilliseconds: 2_000))
            }
        }
        scheduleLocalIdleExpiry(epoch: epoch)
    }

    private func scheduleLocalIdleExpiry(epoch: String) {
        controllerIdleTask?.cancel()
        controllerIdleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, self.localControllerEpoch == epoch else { return }
            guard RemoteControlLeasePolicy.canExpireIdleLease(heldKeyCount: self.localHeldKeys.count,
                                                              heldButtonCount: self.localHeldButtons.count) else {
                self.controllerIdleTask = nil
                self.scheduleLocalIdleExpiry(epoch: epoch)
                return
            }
            self.heartbeatTask?.cancel()
            self.heartbeatTask = nil
            self.localControllerEpoch = nil
            self.controlState = .viewer
            self.queuedLocalIntents.removeAll()
            self.controllerIdleTask = nil
        }
    }

    private func startLeaseWatch() {
        leaseTask?.cancel()
        leaseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2_100))
            guard !Task.isCancelled, let self, !self.controlGate.isActive else { return }
            if let driver = self.controlGate.driverIdentity {
                self.releaseDriver(sender: driver, notifyDriver: true)
            }
        }
    }

    private func releaseDriver(sender: String, notifyDriver: Bool) {
        if notifyDriver, let epoch = controlGate.epoch {
            sendControl(.init(epoch: epoch, sequence: nextSequence(), kind: .revoke), to: sender)
        }
        releaseInjectedInputs()
        controlGate.revoke()
        leaseTask?.cancel()
        leaseTask = nil
        guard let next = controlArbiter.release(identity: sender) else {
            controlState = .host
            return
        }
        sendGrant(to: next)
    }

    private func queueIntent(_ intent: LocalControlIntent) {
        guard canRequestRemoteControl else { return }
        guard localControllerEpoch == nil else { sendIntent(intent); return }
        if case .pointer(let x, let y) = intent,
           let lastIndex = queuedLocalIntents.indices.last,
           case .pointer(_, _) = queuedLocalIntents[lastIndex] {
            queuedLocalIntents[lastIndex] = .pointer(x, y)
        } else if queuedLocalIntents.count < 16 {
            queuedLocalIntents.append(intent)
        } else {
            queuedLocalIntents.removeAll()
            error = "Input queue cleared while waiting for control. Try the action again."
        }
        requestControl()
    }

    private func beginActiveInput(epoch: String) {
        guard localControllerEpoch == epoch else { return }
        if heartbeatTask == nil { startHeartbeat(epoch: epoch) }
        else { scheduleLocalIdleExpiry(epoch: epoch) }
    }

    private func sendIntent(_ intent: LocalControlIntent) {
        switch intent {
        case .pointer(let x, let y): sendPointer(x: x, y: y)
        case .key(let code, let down, let modifiers): sendKey(code: code, down: down, modifiers: modifiers)
        case .button(let button, let down, let x, let y): sendButton(button: button, down: down, x: x, y: y)
        case .scroll(let dx, let dy, let x, let y): sendScroll(dx: dx, dy: dy, x: x, y: y)
        }
    }

    private func releaseInjectedInputs() {
        for code in heldKeys { _ = RemoteInputInjector.key(code: code, down: false) }
        for raw in heldButtons {
            guard let button = CGMouseButton(rawValue: UInt32(raw)) else { continue }
            let point = CGEvent(source: nil)?.location ?? .zero
            _ = RemoteInputInjector.button(button, down: false, at: point)
        }
        heldKeys.removeAll()
        heldButtons.removeAll()
        scheduleOwnerPointerRestore()
    }

    // MARK: State and audio

    private func setReconnecting(_ reconnecting: Bool) {
        guard isReconnecting != reconnecting else { return }
        isReconnecting = reconnecting
        if reconnecting {
            status = "Reconnecting…"
            if isSharing {
                resumeControlAfterReconnect = automaticControlEnabled
                if automaticControlEnabled { pauseRemoteControl() }
                else { releaseInjectedInputs() }
            } else {
                emergencyStop()
            }
            return
        }

        status = connected ? "Connected" : "Disconnected"
        if resumeControlAfterReconnect, isSharing { resumeRemoteControl() }
        resumeControlAfterReconnect = false
    }

    private func refreshParticipants() {
        guard let room else { return }
        let localID = room.localParticipant.identity?.stringValue ?? localIdentity ?? "local"
        let local = CallParticipant(identity: localID, name: room.localParticipant.name ?? localID,
                                    isLocal: true, isSpeaking: room.localParticipant.isSpeaking)
        let remotes = room.remoteParticipants.values.compactMap { participant -> CallParticipant? in
            guard let id = participant.identity?.stringValue else { return nil }
            return CallParticipant(identity: id, name: participant.name ?? id,
                                   isLocal: false, isSpeaking: participant.isSpeaking)
        }.sorted { $0.identity < $1.identity }
        participants = Array(([local] + remotes).prefix(4))
    }

    private func refreshSharer() {
        guard let room else { return }
        if isSharing { activeSharerIdentity = localIdentity; return }
        for participant in room.remoteParticipants.values {
            if let publication = participant.videoTracks.first(where: { $0.source == .screenShareVideo }),
               let sharer = participant.identity?.stringValue {
                if activeSharerIdentity != sharer {
                    emergencyStop()
                    resetIndependentCursors()
                    activeSharerIdentity = sharer
                    controlState = .viewer
                }
                applyRemoteControlAvailability(from: sharer, trackName: publication.name)
                return
            }
        }
        if activeSharerIdentity != nil { emergencyStop(); resetIndependentCursors() }
        activeSharerIdentity = nil
        remoteControlAvailable = false
        remoteControlUnavailableReason = nil
        if connected { controlState = .viewer }
    }

    private func attachLocalAudioRenderer() {
        guard localAudioRenderer == nil, let room else { return }
        let identity = localIdentity ?? "local"
        let renderer = makeAudioRenderer(room: room, identity: identity, name: room.localParticipant.name ?? identity)
        if let track = room.localParticipant.localAudioTracks.compactMap({ $0.track as? LocalAudioTrack }).first {
            track.add(audioRenderer: renderer)
            localAudioRenderer = renderer
        }
    }

    private func detachLocalAudioRenderer() {
        guard let renderer = localAudioRenderer else { return }
        room?.localParticipant.localAudioTracks.compactMap { $0.track as? LocalAudioTrack }.forEach { $0.remove(audioRenderer: renderer) }
        localAudioRenderer = nil
    }

    private func detachAudioRenderers() {
        detachLocalAudioRenderer()
        for attachment in remoteAudioRenderers.values {
            attachment.track.remove(audioRenderer: attachment.renderer)
        }
        remoteAudioRenderers.removeAll()
    }

    private func makeAudioRenderer(room: Room, identity: String, name: String) -> PCMForwarder {
        PCMForwarder { [weak self] samples, sampleRate in
            Task { @MainActor [weak self] in
                guard let self, self.room === room else { return }
                if identity == self.localIdentity {
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - self.lastMicrophoneMeterUpdate >= 0.1 {
                        self.lastMicrophoneMeterUpdate = now
                        self.localMicrophoneLevel = AudioMeter.level(samples: samples)
                    }
                }
                if self.audioForwardingConsented { self.onAudioBuffer?(identity, name, samples, sampleRate) }
            }
        }
    }

    #if DEBUG
    /// UI snapshot fixtures only: stand in for a connected room.
    func debugSetCall(participants: [CallParticipant], microphoneEnabled: Bool, clipboardSync: Bool = false) {
        connected = true
        self.participants = participants
        isMicrophoneEnabled = microphoneEnabled
        localMicrophoneLevel = microphoneEnabled ? 0.45 : 0
        clipboardSyncEnabled = clipboardSync
        clipboardSyncNotice = clipboardSync ? "Copied text shared with teammates on this call" : nil
    }
    #endif

    private func handleLocalInput(_ event: NSEvent) {
        if pointerRestoreTask != nil, event.type != .keyDown {
            pointerRestoreTask?.cancel(); pointerRestoreTask = nil
            ownerPointerPosition = nil
        }
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.contains([.control, .option]) {
            emergencyStop()
            return
        }
        if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type) {
            guard !heldButtons.isEmpty else { return }
        }
        localOwnerInputDetected(restorePointer: event.type == .keyDown)
    }

}

private final class PCMForwarder: AudioRenderer, @unchecked Sendable {
    private let onSamples: @Sendable ([Float], Double) -> Void

    init(onSamples: @escaping @Sendable ([Float], Double) -> Void) { self.onSamples = onSamples }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let count = Int(pcmBuffer.frameLength)
        let samples: [Float]
        if let channel = pcmBuffer.floatChannelData?.pointee {
            samples = Array(UnsafeBufferPointer(start: channel, count: count))
        } else if let channel = pcmBuffer.int16ChannelData?.pointee {
            samples = (0..<count).map { Float(channel[$0]) / 32_768 }
        } else if let channel = pcmBuffer.int32ChannelData?.pointee {
            samples = (0..<count).map { Float(channel[$0]) / 2_147_483_648 }
        } else { return }
        let rate = pcmBuffer.format.sampleRate
        onSamples(samples, rate)
    }
}
