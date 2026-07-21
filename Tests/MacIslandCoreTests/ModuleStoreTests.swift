import XCTest
@testable import MacIslandCore

@MainActor
final class ModuleStoreTests: XCTestCase {
    func test_inMemoryStore_roundTrips() {
        let store = InMemoryModuleStore()
        XCTAssertTrue(store.disabledIDs().isEmpty)
        store.setDisabled([SourceID(raw: "github")])
        XCTAssertEqual(store.disabledIDs(), [SourceID(raw: "github")])
    }

    func test_userDefaultsStore_persistsAcrossInstances() {
        let suite = "modules.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        UserDefaultsModuleStore(defaults: defaults).setDisabled([SourceID(raw: "calendar")])
        // A fresh store over the same defaults must see it — the persistence contract.
        XCTAssertEqual(UserDefaultsModuleStore(defaults: defaults).disabledIDs(),
                       [SourceID(raw: "calendar")])
    }
}
