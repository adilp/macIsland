import XCTest
@testable import MacIslandCore

/// Tests for `AppDefaults.migrate(keys:from:to:)` — the legacy-domain migration helper.
/// Uses throwaway suites so nothing touches the real `UserDefaults.standard` or the app
/// suite; each test tears down its suites in `defer` to leave a clean slate.
final class AppDefaultsMigrationTests: XCTestCase {

    // MARK: - Helpers

    private func suite(_ name: String) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    // MARK: - Tests

    /// (a) A key present in a legacy domain but absent in the target is copied across.
    func test_migrate_copies_missingTargetValue() {
        let srcName = "com.macisland.tests.migrate-src-a"
        let dstName = "com.macisland.tests.migrate-dst-a"
        let src = suite(srcName)
        let dst = suite(dstName)
        defer {
            src.removePersistentDomain(forName: srcName)
            dst.removePersistentDomain(forName: dstName)
        }

        src.set("hello", forKey: "test.key")
        AppDefaults.migrate(keys: ["test.key"], from: [src], to: dst)

        XCTAssertEqual(dst.string(forKey: "test.key"), "hello")
    }

    /// (b) An existing value in the target is left intact — migrate never overwrites.
    func test_migrate_doesNotOverwriteExistingTargetValue() {
        let srcName = "com.macisland.tests.migrate-src-b"
        let dstName = "com.macisland.tests.migrate-dst-b"
        let src = suite(srcName)
        let dst = suite(dstName)
        defer {
            src.removePersistentDomain(forName: srcName)
            dst.removePersistentDomain(forName: dstName)
        }

        src.set("from-legacy", forKey: "test.key")
        dst.set("already-here", forKey: "test.key")
        AppDefaults.migrate(keys: ["test.key"], from: [src], to: dst)

        XCTAssertEqual(dst.string(forKey: "test.key"), "already-here")
    }

    /// (c) When several legacy domains contain the same key, the first one in the array wins.
    func test_migrate_firstLegacyDomainWins() {
        let src1Name = "com.macisland.tests.migrate-src-c1"
        let src2Name = "com.macisland.tests.migrate-src-c2"
        let dstName  = "com.macisland.tests.migrate-dst-c"
        let src1 = suite(src1Name)
        let src2 = suite(src2Name)
        let dst  = suite(dstName)
        defer {
            src1.removePersistentDomain(forName: src1Name)
            src2.removePersistentDomain(forName: src2Name)
            dst.removePersistentDomain(forName: dstName)
        }

        src1.set("first", forKey: "test.key")
        src2.set("second", forKey: "test.key")
        AppDefaults.migrate(keys: ["test.key"], from: [src1, src2], to: dst)

        XCTAssertEqual(dst.string(forKey: "test.key"), "first")
    }

    /// (d) A key absent from all legacy domains and the target is a no-op — target stays empty.
    func test_migrate_absentEverywhereIsNoOp() {
        let srcName = "com.macisland.tests.migrate-src-d"
        let dstName = "com.macisland.tests.migrate-dst-d"
        let src = suite(srcName)
        let dst = suite(dstName)
        defer {
            src.removePersistentDomain(forName: srcName)
            dst.removePersistentDomain(forName: dstName)
        }

        AppDefaults.migrate(keys: ["nonexistent.key"], from: [src], to: dst)

        XCTAssertNil(dst.object(forKey: "nonexistent.key"))
    }
}
