import AppKit
@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import SwiftUI

@MainActor
final class MicrophoneTestController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var level = 0.0
    @Published var message: String?

    private var engine: AVAudioEngine?

    func start(deviceID: String) {
        guard !isRunning else { return }
        message = nil
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let audioUnit = input.audioUnit,
              let device = Self.coreAudioDeviceID(for: deviceID) else {
            message = "PairDesk couldn't find the selected microphone. Choose an available input and try again."
            return
        }
        var selectedDevice = device
        let status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &selectedDevice,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            message = "PairDesk couldn't test the selected microphone. Check the device connection and try again."
            return
        }

        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            message = "No microphone input is available. Choose another input device and try again."
            return
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?.pointee else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let value = AudioMeter.level(samples: samples)
            Task { @MainActor [weak self] in self?.level = value }
        }
        do {
            try engine.start()
            self.engine = engine
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            message = "Microphone test couldn't start: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        isRunning = false
        level = 0
    }

    private static func coreAudioDeviceID(for uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address,
                                             0, nil, &byteCount) == noErr,
              byteCount >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return nil }
        let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        var devices = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &byteCount, &devices) == noErr else { return nil }

        for device in devices {
            var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var valueSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &valueSize, &value) == noErr,
                  let value,
                  value.takeUnretainedValue() as String == uid else { continue }
            return device
        }
        return nil
    }
}

@MainActor
final class CameraPreviewTestController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var previewSession: AVCaptureSession?
    @Published var message: String?

    private let queue = DispatchQueue(label: "app.internal.pairdesk.camera-preview-test")

    func start(cameraID: String?) {
        guard !isRunning, previewSession == nil else { return }
        message = nil
        let session = AVCaptureSession()
        previewSession = session
        queue.async { [weak self] in
            do {
                let devices = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                    mediaType: .video,
                    position: .unspecified
                ).devices
                guard let device = devices.first(where: { $0.uniqueID == cameraID }) ?? devices.first else {
                    throw CameraTestError.noCamera
                }
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw CameraTestError.cannotAddInput }
                session.beginConfiguration()
                session.sessionPreset = .high
                session.addInput(input)
                session.commitConfiguration()
                session.startRunning()
                Task { @MainActor [weak self] in
                    guard let self, self.previewSession === session else { return }
                    self.isRunning = session.isRunning
                    if !self.isRunning { self.message = "Camera preview did not start. Check that another app isn't using the camera." }
                }
            } catch {
                session.stopRunning()
                Task { @MainActor [weak self] in
                    guard let self, self.previewSession === session else { return }
                    self.previewSession = nil
                    self.message = "Camera test couldn't start: \(error.localizedDescription)"
                }
            }
        }
    }

    func stop() {
        guard let session = previewSession else { return }
        previewSession = nil
        isRunning = false
        queue.async { if session.isRunning { session.stopRunning() } }
    }
}

private enum CameraTestError: LocalizedError {
    case noCamera
    case cannotAddInput

    var errorDescription: String? {
        switch self {
        case .noCamera: "No camera is available. Connect or select another camera and try again."
        case .cannotAddInput: "The selected camera couldn't be opened for preview."
        }
    }
}

struct CameraPreviewSurface: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView(session: session)
    }

    func updateNSView(_ view: CameraPreviewNSView, context: Context) {
        view.previewLayer.session = session
    }
}

final class CameraPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspect
        layer = previewLayer
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}
