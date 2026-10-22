import Foundation
import XCTest
@testable import PairDesk

final class PairDeskInstanceLockTests: XCTestCase {
    func testOnlyOneLockHolderCanAcquireAndLockCanBeReleased() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairDeskInstanceLockTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = PairDeskInstanceLock(directoryURL: directory)
        let second = PairDeskInstanceLock(directoryURL: directory)

        guard case .acquired = first.acquire() else {
            return XCTFail("The first process should acquire the lock")
        }
        guard case .alreadyRunning = second.acquire() else {
            return XCTFail("A second process should be rejected while the lock is held")
        }

        first.release()
        guard case .acquired = second.acquire() else {
            return XCTFail("The lock should become available after the first holder exits")
        }
        second.release()
    }

    func testLockRejectsASeparateProcess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairDeskInstanceLockProcessTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let holder = PairDeskInstanceLock(directoryURL: directory)
        guard case .acquired = holder.acquire() else {
            return XCTFail("The parent process should acquire the lock")
        }

        let lockURL = directory.appendingPathComponent("instance.lock")
        let helperURL = directory.appendingPathComponent("lock-probe.swift")
        try """
        import Darwin
        import Foundation

        let descriptor = Darwin.open(CommandLine.arguments[1], O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { exit(2) }
        defer { Darwin.close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            exit(11) // An independent process unexpectedly acquired the held lock.
        }
        exit(errno == EWOULDBLOCK || errno == EAGAIN ? 0 : 12)
        """.write(to: helperURL, atomically: true, encoding: .utf8)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        child.arguments = [helperURL.path, lockURL.path]
        try child.run()
        child.waitUntilExit()

        XCTAssertEqual(child.terminationReason, .exit)
        XCTAssertEqual(child.terminationStatus, 0,
                       "A separate process must not acquire an instance lock already held by PairDesk")
    }
}
