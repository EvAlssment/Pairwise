import XCTest
@testable import PairDesk

final class WhisperTranscriberTests: XCTestCase {
    func testTemporaryAudioDirectoryAndMarkerAreOwnerOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pairdesk-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = try WhisperTemporaryAudioStore.createJobDirectory(in: root)
        let marker = directory.appendingPathComponent(".pairdesk-whisper-owned")
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let markerAttributes = try FileManager.default.attributesOfItem(atPath: marker.path)
        XCTAssertEqual(((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o077, 0)
        XCTAssertEqual(((markerAttributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o077, 0)
    }

    func testStartupCleanupRemovesOnlyOldMarkedPairDeskDirectories() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("pairdesk-test-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: root) }

        let now = Date()
        let stale = try WhisperTemporaryAudioStore.createJobDirectory(in: root)
        try Data([1, 2, 3]).write(to: stale.appendingPathComponent("audio.wav"))
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-WhisperTemporaryAudioStore.retentionInterval - 60)], ofItemAtPath: stale.path)

        let recent = try WhisperTemporaryAudioStore.createJobDirectory(in: root)
        let unmarked = root.appendingPathComponent(WhisperTemporaryAudioStore.directoryPrefix + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: unmarked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data([4, 5, 6]).write(to: unmarked.appendingPathComponent("audio.wav"))
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-WhisperTemporaryAudioStore.retentionInterval - 60)], ofItemAtPath: unmarked.path)

        let removed = WhisperTemporaryAudioStore.cleanupStaleDirectories(in: root, now: now)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: stale.path))
        XCTAssertTrue(fileManager.fileExists(atPath: recent.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unmarked.path))
    }

    func testWAVHeaderIsMono16000HzPCMAndClipsSamples() throws {
        let wav = WhisperTranscriber.makeWAV(samples: [-2, -1, 0, 1, 2, .nan])
        XCTAssertEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(readUInt16(wav, at: 22), 1)
        XCTAssertEqual(readUInt32(wav, at: 24), 16_000)
        XCTAssertEqual(readUInt16(wav, at: 34), 16)
        XCTAssertEqual(readUInt32(wav, at: 40), 12)
        XCTAssertEqual(readInt16(wav, at: 44), -32_768)
        XCTAssertEqual(readInt16(wav, at: 46), -32_768)
        XCTAssertEqual(readInt16(wav, at: 50), 32_767)
        XCTAssertEqual(readInt16(wav, at: 54), 0)
    }

    @MainActor
    func testMissingWhisperResourcesAreExplicitAndCannotEnable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcriber = WhisperTranscriber(resourceDirectory: directory)
        transcriber.setEnabled(true)
        let enabled = transcriber.enabled
        let status = transcriber.status
        let segments = transcriber.segments
        XCTAssertFalse(enabled)
        XCTAssertTrue(status.contains("whisper-cli is missing"))
        XCTAssertTrue(segments.isEmpty)
    }

    @MainActor
    func testTenSecondChunkLimitAndTemporaryWAVCleanupWithLocalStub() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("ggml-tiny.bin")
        try Data([0]).write(to: model)
        let executable = directory.appendingPathComponent("whisper-cli")
        let script = #"""
#!/bin/sh
input=""
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -f) input="$2"; shift 2 ;;
    -of) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
wc -c < "$input" | tr -d ' ' > "$output.txt"
printf '\n%s' "$input" >> "$output.txt"
"""#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let transcriber = WhisperTranscriber(resourceDirectory: directory, executableURL: executable)
        transcriber.setEnabled(true)
        let enabled = transcriber.enabled
        XCTAssertTrue(enabled)
        transcriber.appendAudio(speakerID: "participant-1", name: "Alex", samples: Array(repeating: 0.1, count: 160_000), sampleRate: 16_000)

        let deadline = Date().addingTimeInterval(5)
        while transcriber.segments.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let completedSegments = transcriber.segments
        let transcript = completedSegments.first?.text ?? ""
        let speakerID = completedSegments.first?.speakerID
        let resultLines = transcript.split(separator: "\n")
        XCTAssertEqual(resultLines.first, "320044", "10 seconds at 16 kHz should produce a 320,044-byte WAV")
        XCTAssertEqual(speakerID, "participant-1")
        if let wavPath = resultLines.last {
            XCTAssertFalse(FileManager.default.fileExists(atPath: String(wavPath)), "temporary WAV chunk should be deleted")
            XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: String(wavPath)).deletingLastPathComponent().path), "temporary chunk directory should be deleted")
        } else {
            XCTFail("stub did not report its WAV path")
        }
    }

    @MainActor
    func testGeneratedSpeechWithBundledWhisperWhenAvailable() async throws {
        let runtime = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".cache/whisper/runtime")
        let executable = runtime.appendingPathComponent("whisper-cli")
        let model = runtime.appendingPathComponent("ggml-tiny.bin")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: model.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/say"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/afconvert") else {
            throw XCTSkip("whisper runtime or macOS speech fixture tools are unavailable")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let aiff = directory.appendingPathComponent("speech.aiff")
        let wav = directory.appendingPathComponent("speech.wav")
        try run("/usr/bin/say", ["-v", "Samantha", "-o", aiff.path, "This is a local transcription test."])
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
        let data = try Data(contentsOf: wav)
        let (dataOffset, dataSize) = try pcmDataRange(in: data)
        let pcm = stride(from: dataOffset, to: dataOffset + dataSize, by: 2).map { offset in
            Float(readInt16(data, at: offset)) / Float(Int16.max)
        }

        let transcriber = WhisperTranscriber(resourceDirectory: runtime, executableURL: executable)
        transcriber.setEnabled(true)
        transcriber.appendAudio(speakerID: "fixture", name: "Fixture", samples: pcm, sampleRate: 16_000)
        transcriber.appendAudio(speakerID: "fixture", name: "Fixture", samples: Array(repeating: 0, count: 16_000), sampleRate: 16_000)
        let deadline = Date().addingTimeInterval(30)
        while transcriber.segments.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let hasTranscript = !(transcriber.segments.first?.text.isEmpty ?? true)
        XCTAssertTrue(hasTranscript)
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable) failed")
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readInt16(_ data: Data, at offset: Int) -> Int16 {
        Int16(bitPattern: readUInt16(data, at: offset))
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private func pcmDataRange(in data: Data) throws -> (offset: Int, count: Int) {
        guard data.count >= 12, String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw NSError(domain: "WhisperTranscriberTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "say fixture is not a RIFF/WAVE file"])
        }
        var offset = 12
        while offset + 8 <= data.count {
            let chunk = String(data: data[offset..<(offset + 4)], encoding: .ascii)
            let size = Int(readUInt32(data, at: offset + 4))
            let payload = offset + 8
            guard size >= 0, payload + size <= data.count else { break }
            if chunk == "data" { return (payload, size - (size % 2)) }
            offset = payload + size + (size % 2)
        }
        throw NSError(domain: "WhisperTranscriberTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "say fixture has no PCM data chunk"])
    }
}
