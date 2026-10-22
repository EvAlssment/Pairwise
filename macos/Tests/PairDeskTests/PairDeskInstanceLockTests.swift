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
}
