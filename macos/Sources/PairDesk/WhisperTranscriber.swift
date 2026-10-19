import Combine
import Foundation

private final class WhisperJobToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func start(_ process: Process) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        try process.run()
        self.process = process
        return true
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if process?.isRunning == true { process?.terminate() }
    }
}

struct TranscriptSegment: Identifiable, Equatable {
    let id: UUID
    let speakerID: String
    let speakerName: String
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), speakerID: String, speakerName: String, text: String, createdAt: Date = Date()) {
        self.id = id
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.text = text
        self.createdAt = createdAt
    }
}

/// Local-only transcription using the app-bundled whisper.cpp CLI and ggml tiny model.
/// Audio chunks are held in memory up to ten seconds and temporary WAV files are deleted
/// immediately after inference. This class has no network or persistence code.
@MainActor
final class WhisperTranscriber: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var status = "Transcription is off"
    @Published private(set) var segments: [TranscriptSegment] = []

    private struct PendingAudio: Sendable {
        var name: String
        var samples: [Float] = []
        var sampleRate: Double = 16_000
        var voiceSamples = 0
        var quietSamples = 0
    }

    private let resourceDirectory: URL
    private let executableURL: URL
    private let worker = DispatchQueue(label: "app.pairdesk.whisper", qos: .userInitiated)
    private let maxUtteranceSeconds = 10.0
    private let minUtteranceSeconds = 0.6
    private let silenceHysteresisSeconds = 0.6
    private let speechRMS: Float = 0.008
    private var pending: [String: PendingAudio] = [:]
    private var generation = 0
    private var pendingJobs = 0
    private var jobs: [UUID: WhisperJobToken] = [:]

    init(resourceDirectory: URL? = nil, executableURL: URL? = nil) {
        WhisperTemporaryAudioStore.cleanupStaleDirectories()
        let root = resourceDirectory ?? Bundle.main.resourceURL?.appendingPathComponent("whisper", isDirectory: true)
            ?? URL(fileURLWithPath: "/")
        self.resourceDirectory = root
        self.executableURL = executableURL ?? root.appendingPathComponent("whisper-cli")
        if !FileManager.default.isExecutableFile(atPath: self.executableURL.path) {
            status = "Whisper unavailable: bundled whisper-cli is missing"
        } else if !FileManager.default.fileExists(atPath: root.appendingPathComponent("ggml-tiny.bin").path) {
            status = "Whisper unavailable: bundled tiny model is missing"
        } else {
            status = "Transcription is off · audio stays on this Mac"
        }
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        if value {
            let readiness = readyStatus
            guard readiness.hasPrefix("Local transcription on") else {
                status = readiness
                return
            }
        }
        if !value { invalidateJobs() }
        enabled = value
        pending.removeAll(keepingCapacity: false)
        status = value ? readyStatus : "Transcription is off"
    }

    /// Feed PCM from the existing LiveKit microphone/remote-track hooks. The speaker ID
    /// must come from the RTC participant identity, not from transcript content.
    func appendAudio(speakerID: String, name: String, samples: [Float], sampleRate: Double) {
        guard enabled, !samples.isEmpty, !speakerID.isEmpty,
              sampleRate.isFinite, (1_000.0...192_000.0).contains(sampleRate) else { return }
        if var existing = pending[speakerID], abs(existing.sampleRate - sampleRate) > 0.5 {
            if Double(existing.voiceSamples) / existing.sampleRate >= minUtteranceSeconds {
                enqueue(existing, speakerID: speakerID)
            }
            pending.removeValue(forKey: speakerID)
            existing.samples.removeAll(keepingCapacity: false)
        }
        guard pending[speakerID] != nil || pending.count < 4 else {
            status = "Local transcription busy · audio buffer is full"
            return
        }
        var audio = pending[speakerID] ?? PendingAudio(name: name, sampleRate: sampleRate)
        audio.name = name
        let limit = max(1, Int(sampleRate * maxUtteranceSeconds))
        if Self.rms(samples) < speechRMS {
            let quietLimit = max(1, Int(sampleRate * silenceHysteresisSeconds))
            let amount = min(samples.count, quietLimit - audio.quietSamples, limit - audio.samples.count)
            if amount > 0 {
                audio.samples.append(contentsOf: samples.prefix(amount).map { $0.isFinite ? min(1, max(-1, $0)) : 0 })
                audio.quietSamples += amount
            }
            if audio.quietSamples >= quietLimit || audio.samples.count >= limit {
                if Double(audio.voiceSamples) / sampleRate >= minUtteranceSeconds {
                    enqueue(audio, speakerID: speakerID)
                }
                pending.removeValue(forKey: speakerID)
            } else if audio.voiceSamples > 0 {
                pending[speakerID] = audio
            }
            return
        }

        audio.quietSamples = 0
        var offset = 0
        while offset < samples.count {
            let count = min(limit - audio.samples.count, samples.count - offset)
            audio.samples.append(contentsOf: samples[offset..<(offset + count)].map { $0.isFinite ? min(1, max(-1, $0)) : 0 })
            audio.voiceSamples += count
            offset += count
            if audio.samples.count >= limit {
                enqueue(audio, speakerID: speakerID)
                audio = PendingAudio(name: name, sampleRate: sampleRate)
            }
        }
        if !audio.samples.isEmpty { pending[speakerID] = audio }
        else { pending.removeValue(forKey: speakerID) }
    }

    func clear() {
        invalidateJobs()
        pending.removeAll(keepingCapacity: false)
        segments.removeAll()
        status = enabled ? readyStatus : "Transcription is off"
    }

    func shutdown() {
        invalidateJobs()
        enabled = false
        pending.removeAll()
        segments.removeAll()
        status = "Transcription is off"
    }

    private var readyStatus: String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return "Whisper unavailable: bundled whisper-cli is missing"
        }
        guard FileManager.default.fileExists(atPath: resourceDirectory.appendingPathComponent("ggml-tiny.bin").path) else {
            return "Whisper unavailable: bundled tiny model is missing"
        }
        return "Local transcription on · audio stays on this Mac"
    }

    private func enqueue(_ audio: PendingAudio, speakerID: String) {
        guard enabled, !audio.samples.isEmpty else { return }
        guard pendingJobs < 8 else {
            status = "Local transcription busy · a speech chunk was dropped"
            return
        }
        let samples = Self.resample(audio.samples, from: audio.sampleRate, to: 16_000)
        guard !samples.isEmpty else { return }
        let jobID = UUID()
        let jobGeneration = generation
        let token = WhisperJobToken()
        jobs[jobID] = token
        pendingJobs += 1
        status = "Transcribing locally…"
        let executable = executableURL
        let model = resourceDirectory.appendingPathComponent("ggml-tiny.bin")
        worker.async { [weak self] in
            let text = token.isCancelled ? nil : Self.transcribe(samples: samples, executable: executable, model: model, token: token)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.jobs.removeValue(forKey: jobID)
                self.pendingJobs = max(0, self.pendingJobs - 1)
                guard self.enabled, self.generation == jobGeneration else { return }
                if let text, !text.isEmpty {
                    if self.segments.count >= 1_000 { self.segments.removeFirst(self.segments.count - 999) }
                    self.segments.append(TranscriptSegment(speakerID: speakerID, speakerName: audio.name, text: text))
                    self.status = self.pendingJobs > 0 ? "Transcribing locally…" : self.readyStatus
                } else if text == "" {
                    self.status = self.pendingJobs > 0 ? "Transcribing locally…" : self.readyStatus
                } else {
                    self.status = "Whisper unavailable: local inference failed"
                }
            }
        }
    }

    nonisolated private static func transcribe(samples: [Float], executable: URL, model: URL, token: WhisperJobToken) -> String? {
        do {
            let directory = try WhisperTemporaryAudioStore.createJobDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let wav = directory.appendingPathComponent("audio.wav")
            let outputBase = directory.appendingPathComponent("result")
            try makeWAV(samples: samples).write(to: wav, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wav.path)
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-m", model.path, "-f", wav.path, "-otxt", "-of", outputBase.path, "-nt", "-l", "auto", "-t", "2"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard try token.start(process) else { return nil }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { token.cancel() }
            process.waitUntilExit()
            guard !token.isCancelled, process.terminationStatus == 0 else { return nil }
            let output = outputBase.appendingPathExtension("txt")
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            guard let data = try? Data(contentsOf: output), let text = String(data: data, encoding: .utf8) else { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    nonisolated static func makeWAV(samples: [Float]) -> Data {
        let pcm = samples.map { sample -> Int16 in
            let clipped = min(1, max(-1, sample.isFinite ? sample : 0))
            if clipped <= -1 { return Int16.min }
            return Int16((clipped * Float(Int16.max)).rounded())
        }
        let dataSize = UInt32(pcm.count * MemoryLayout<Int16>.size)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8)); data.appendLE(dataSize + 36)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); data.appendLE(UInt32(16))
        data.appendLE(UInt16(1)); data.appendLE(UInt16(1)); data.appendLE(UInt32(16_000))
        data.appendLE(UInt32(32_000)); data.appendLE(UInt16(2)); data.appendLE(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); data.appendLE(dataSize)
        for value in pcm { data.appendLE(UInt16(bitPattern: value)) }
        return data
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { partial, value in
            let finite = value.isFinite ? Double(value) : 0
            return partial + finite * finite
        }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    private static func resample(_ input: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !input.isEmpty, sourceRate > 0 else { return [] }
        if abs(sourceRate - targetRate) < 1 { return input }
        let outputCount = max(1, Int((Double(input.count) * targetRate / sourceRate).rounded()))
        return (0..<outputCount).map { index in
            let position = Double(index) * sourceRate / targetRate
            let lower = min(input.count - 1, Int(position))
            let upper = min(input.count - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            return input[lower] * (1 - fraction) + input[upper] * fraction
        }
    }

    private func invalidateJobs() {
        generation &+= 1
        for token in jobs.values { token.cancel() }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
