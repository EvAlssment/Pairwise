import Foundation
import AVFAudio
import AVFoundation
import LiveKit

struct CameraTile: Identifiable {
    let id: String
    let name: String
    let track: VideoTrack
}

@MainActor @Observable final class CallSession: NSObject, RoomDelegate {
    private(set) var room: Room?
    private(set) var microphoneOn = false
    private(set) var cameraOn = false
    var speakerOn = false
    @ObservationIgnored private var speakerOverrideActive = false
    private(set) var connected = false
    private(set) var videoTiles: [CameraTile] = []
    var onDisconnected: (() -> Void)?
    @ObservationIgnored private var hadRemoteParticipant = false

    override init() { super.init() }

    func join(url: String, token: String, startMicrophone: Bool = true) async throws {
        await leave()
        let room = Room(delegate: self,
                        roomOptions: RoomOptions(adaptiveStream: true, dynacast: true))
        self.room = room
        do {
            try await room.connect(url: url, token: token)
            guard self.room === room else { throw CancellationError() }
            connected = true
            hadRemoteParticipant = !room.remoteParticipants.isEmpty
            if startMicrophone {
                try await room.localParticipant.setMicrophone(enabled: true)
                guard self.room === room else { throw CancellationError() }
                microphoneOn = true
            }
            refreshVideoTiles()
        } catch {
            if self.room === room { await leave() }
            else { await room.disconnect() }
            throw error
        }
    }
    func toggleMicrophone() async throws {
        guard let room else { return }
        try await room.localParticipant.setMicrophone(enabled: !microphoneOn)
        microphoneOn.toggle()
    }
    func activateMicrophoneAfterCallKit() async throws {
        guard let room, !microphoneOn else { return }
        try await room.localParticipant.setMicrophone(enabled: true)
        microphoneOn = true
    }
    func deactivateMicrophoneForCallKit() async {
        guard let room, microphoneOn else { return }
        try? await room.localParticipant.setMicrophone(enabled: false)
        microphoneOn = false
    }
    func toggleCamera() async throws {
        guard let room else { return }
        if !cameraOn {
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard allowed else { throw APIError(message: "Camera access is off. Enable PairDesk in Settings > Privacy & Security > Camera.") }
        }
        _ = try await room.localParticipant.setCamera(enabled: !cameraOn, captureOptions: CameraCaptureOptions())
        cameraOn.toggle()
        refreshVideoTiles()
    }
    func refreshVideoTiles() {
        guard let room else { videoTiles = []; return }
        var tiles: [CameraTile] = []
        if let track = room.localParticipant.firstCameraVideoTrack {
            tiles.append(CameraTile(id: "local", name: "You", track: track))
        }
        for person in room.remoteParticipants.values {
            if let identity = person.identity?.stringValue, let track = person.firstCameraVideoTrack {
                tiles.append(CameraTile(id: identity, name: person.name ?? "Teammate", track: track))
            }
        }
        videoTiles = tiles
    }
    func setSpeaker(_ enabled: Bool) throws {
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
        speakerOverrideActive = enabled
        speakerOn = enabled
    }
    func leave() async {
        if speakerOverrideActive { try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none) }
        speakerOverrideActive = false
        let previous = room
        room = nil; connected = false; microphoneOn = false; cameraOn = false; speakerOn = false; videoTiles = []
        hadRemoteParticipant = false
        // Clear identity before awaiting disconnect so intentional teardown
        // cannot be mistaken for a remote hang-up by delayed delegate events.
        if let previous { await previous.disconnect() }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            await self.leave()
            guard self.room == nil else { return }
            self.onDisconnected?()
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.hadRemoteParticipant = true
            self.refreshVideoTiles()
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.refreshVideoTiles()
            if self.hadRemoteParticipant, room.remoteParticipants.isEmpty {
                await self.leave()
                guard self.room == nil else { return }
                self.onDisconnected?()
            }
        }
    }

    nonisolated func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        Task { @MainActor [weak self] in self?.refreshVideoTiles() }
    }
    nonisolated func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        Task { @MainActor [weak self] in self?.refreshVideoTiles() }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in self?.refreshVideoTiles() }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in self?.refreshVideoTiles() }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in self?.refreshVideoTiles() }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in self?.refreshVideoTiles() }
    }
}
