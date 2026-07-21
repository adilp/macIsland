import XCTest
@testable import MacIslandCore

@MainActor
final class ModuleRegistryTests: XCTestCase {

    private func makeCore() -> IslandCore { IslandCore(clock: TestClock()) }

    func test_start_registersEnabledModules_byDefault() {
        let core = makeCore()
        let reg = ModuleRegistry(core: core, store: InMemoryModuleStore())
        reg.add(Module(id: SourceID(raw: "a"), displayName: "A", icon: .symbol("gear"),
                       makeSource: { SpySource("a") }))
        reg.start()
        XCTAssertTrue(core.liveSourceIDs.contains(SourceID(raw: "a")))
        XCTAssertTrue(reg.isEnabled(SourceID(raw: "a")))
    }

    func test_start_skipsDisabledModules() {
        let core = makeCore()
        let reg = ModuleRegistry(core: core, store: InMemoryModuleStore([SourceID(raw: "a")]))
        reg.add(Module(id: SourceID(raw: "a"), displayName: "A", icon: .symbol("gear"),
                       makeSource: { SpySource("a") }))
        reg.start()
        XCTAssertFalse(core.liveSourceIDs.contains(SourceID(raw: "a")))
        XCTAssertFalse(reg.isEnabled(SourceID(raw: "a")))
    }

    func test_disable_unregistersAndPersists() async {
        let core = makeCore()
        let store = InMemoryModuleStore()
        let reg = ModuleRegistry(core: core, store: store)
        reg.add(Module(id: SourceID(raw: "a"), displayName: "A", icon: .symbol("gear"),
                       makeSource: { SpySource("a") }))
        reg.start()

        await reg.setEnabled(SourceID(raw: "a"), false)

        XCTAssertFalse(core.liveSourceIDs.contains(SourceID(raw: "a")))
        XCTAssertEqual(store.disabledIDs(), [SourceID(raw: "a")], "off is persisted")
    }

    func test_reEnable_buildsFreshSource() async {
        let core = makeCore()
        var builds = 0
        let reg = ModuleRegistry(core: core, store: InMemoryModuleStore())
        reg.add(Module(id: SourceID(raw: "a"), displayName: "A", icon: .symbol("gear"),
                       makeSource: { builds += 1; return SpySource("a") }))
        reg.start()                                    // builds == 1
        await reg.setEnabled(SourceID(raw: "a"), false)
        await reg.setEnabled(SourceID(raw: "a"), true) // builds == 2 (fresh, not resumed)

        XCTAssertEqual(builds, 2)
        XCTAssertTrue(core.liveSourceIDs.contains(SourceID(raw: "a")))
    }

    func test_persistedOff_survivesANewRegistry() {
        let core = makeCore()
        let store = InMemoryModuleStore([SourceID(raw: "a")])   // previously disabled
        let reg = ModuleRegistry(core: core, store: store)      // fresh registry, same store
        reg.add(Module(id: SourceID(raw: "a"), displayName: "A", icon: .symbol("gear"),
                       makeSource: { SpySource("a") }))
        reg.start()
        XCTAssertFalse(core.liveSourceIDs.contains(SourceID(raw: "a")))
    }

    func test_status_reflectsLiveHealth_andDisabled() async {
        let core = makeCore()
        var health: ModuleStatus = .ok
        let reg = ModuleRegistry(core: core, store: InMemoryModuleStore())
        reg.add(Module(id: SourceID(raw: "a"), displayName: "A", icon: .symbol("gear")) {
            ActiveModule(source: SpySource("a"), status: { health })
        })
        reg.start()
        XCTAssertEqual(reg.status(of: SourceID(raw: "a")), .live(.ok))

        health = .needsAttention("Not signed in")
        XCTAssertEqual(reg.status(of: SourceID(raw: "a")), .live(.needsAttention("Not signed in")))

        await reg.setEnabled(SourceID(raw: "a"), false)
        XCTAssertEqual(reg.status(of: SourceID(raw: "a")), .disabled)
    }

    func test_registryArmsNoTimers_atIdle() {
        let clock = TestClock()
        let core = IslandCore(clock: clock)
        let reg = ModuleRegistry(core: core, store: InMemoryModuleStore())
        reg.add(Module(id: SourceID(raw: "a"), displayName: "A", icon: .symbol("gear"),
                       makeSource: { SpySource("a") }))
        reg.start()
        XCTAssertEqual(clock.armedCount, 0, "the registry itself schedules nothing (quiescent)")
    }
}
