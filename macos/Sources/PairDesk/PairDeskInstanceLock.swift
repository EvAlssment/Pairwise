import Darwin
import Foundation

final class PairDeskInstanceLock {
    enum Acquisition {
        case acquired
        case alreadyRunning
        case failed(Error)
    }

    private let directoryURL: URL
    private var descriptor: Int32 = -1

    init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directoryURL = applicationSupport.appendingPathComponent("PairDesk/Runtime", isDirectory: true)
        }
    }

    func acquire() -> Acquisition {
        if descriptor >= 0 { return .acquired }

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .failed(error)
        }

        let lockURL = directoryURL.appendingPathComponent("instance.lock", isDirectory: false)
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { return .failed(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN { return .alreadyRunning }
            return .failed(POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO))
        }

        self.descriptor = descriptor
        return .acquired
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
