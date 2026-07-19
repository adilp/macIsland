import XCTest
import Foundation
@testable import MacIslandCore

/// Tests for `SingleInstanceGuard` — the runtime "only one instance can run at a
/// time" mechanism (walking-skeleton ticket, criterion 5). Backed by an exclusive
/// `flock` on a lock file: a second holder of the same path is refused, and the lock
/// is released when the guard is dropped. `flock` is per-open-file-description, so
/// two independent guards in one process model two processes deterministically — no
/// second process needed to test the contention path.
final class SingleInstanceGuardTests: XCTestCase {

    private func tempLockPath() -> String {
        NSTemporaryDirectory() + "macisland-guard-test-\(UUID().uuidString).lock"
    }

    func test_firstGuardAcquires_secondOnSamePathIsRefused() {
        let path = tempLockPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = SingleInstanceGuard(path: path)
        XCTAssertNotNil(first, "the first instance must acquire the lock")

        let second = SingleInstanceGuard(path: path)
        XCTAssertNil(second, "a second instance on the same path must be refused")

        _ = first   // keep the lock held across the second attempt
    }

    func test_releasingGuardLetsAnotherAcquire() {
        let path = tempLockPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        var first: SingleInstanceGuard? = SingleInstanceGuard(path: path)
        XCTAssertNotNil(first)

        first = nil   // drop it → deinit closes the fd → lock released

        let second = SingleInstanceGuard(path: path)
        XCTAssertNotNil(second, "after the first instance exits, another may acquire")
        _ = second
    }

    func test_differentPathsDoNotContend() {
        let a = tempLockPath()
        let b = tempLockPath()
        defer {
            try? FileManager.default.removeItem(atPath: a)
            try? FileManager.default.removeItem(atPath: b)
        }
        let ga = SingleInstanceGuard(path: a)
        let gb = SingleInstanceGuard(path: b)
        XCTAssertNotNil(ga)
        XCTAssertNotNil(gb, "distinct lock paths are independent")
        _ = (ga, gb)
    }
}
