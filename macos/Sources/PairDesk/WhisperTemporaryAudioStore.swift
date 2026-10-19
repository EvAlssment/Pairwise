import Darwin
import Foundation

/// Owns the short-lived files passed to the local Whisper process. The marker
/// makes startup cleanup specific to directories created by PairDesk rather
/// than relying on a broad filename-prefix sweep alone.
enum WhisperTemporaryAudioStore {
    static let directoryPrefix = "pairdesk-whisper-"
    static let retentionInterval: TimeInterval = 24 * 60 * 60
    private static let markerName = ".pairdesk-whisper-owned"
    private static let markerPrefix = Data("PairDesk Whisper temporary audio v1\n".utf8)

    @discardableResult
    static func cleanupStaleDirectories(
        in root: URL = FileManager.default.temporaryDirectory,
        now: Date = Date(),
        retentionInterval: TimeInterval = retentionInterval,
        fileManager: FileManager = .default
    ) -> Int {
        guard rootIsSafe(root, fileManager: fileManager),
              let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsPackageDescendants]
              ) else { return 0 }

        var removed = 0
        for directory in children where isPairDeskDirectoryName(directory.lastPathComponent) {
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let modifiedAt = values.contentModificationDate,
                  now.timeIntervalSince(modifiedAt) >= retentionInterval,
                  isOwnedDirectory(directory, fileManager: fileManager),
                  hasValidOwnershipMarker(in: directory, fileManager: fileManager) else { continue }

            do {
                try fileManager.removeItem(at: directory)
                removed += 1
            } catch {
                // Cleanup is best-effort. A later launch can retry; transcription
                // remains available even when the temporary volume is read-only.
            }
        }
        return removed
    }

    static func createJobDirectory(
        in root: URL = FileManager.default.temporaryDirectory,
        id: UUID = UUID(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = root.appendingPathComponent(directoryPrefix + id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            var marker = markerPrefix
            marker.append(Data((id.uuidString + "\n").utf8))
            let markerURL = directory.appendingPathComponent(markerName)
            try marker.write(to: markerURL, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
            return directory
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private static func isPairDeskDirectoryName(_ name: String) -> Bool {
        guard name.hasPrefix(directoryPrefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(directoryPrefix.count))) != nil
    }

    private static func rootIsSafe(_ root: URL, fileManager: FileManager) -> Bool {
        guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true,
              let attributes = try? fileManager.attributesOfItem(atPath: root.path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid() else { return false }
        return true
    }

    private static func isOwnedDirectory(_ directory: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: directory.path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber else { return false }
        return (permissions.intValue & 0o077) == 0
    }

    private static func hasValidOwnershipMarker(in directory: URL, fileManager: FileManager) -> Bool {
        let markerURL = directory.appendingPathComponent(markerName)
        guard let values = try? markerURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let attributes = try? fileManager.attributesOfItem(atPath: markerURL.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              (permissions.intValue & 0o077) == 0,
              let contents = try? Data(contentsOf: markerURL) else { return false }

        let suffix = String(directory.lastPathComponent.dropFirst(directoryPrefix.count))
        var expected = markerPrefix
        expected.append(Data((suffix.uppercased() + "\n").utf8))
        return contents == expected
    }
}
