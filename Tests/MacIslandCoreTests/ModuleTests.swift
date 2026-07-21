import XCTest
@testable import MacIslandCore

@MainActor
final class ModuleTests: XCTestCase {

    // MARK: - ModuleStatus / ModuleDisplayStatus

    func test_moduleStatus_equatable() {
        XCTAssertEqual(ModuleStatus.ok, .ok)
        XCTAssertEqual(ModuleStatus.needsAttention("x"), .needsAttention("x"))
        XCTAssertNotEqual(ModuleStatus.needsAttention("x"), .needsAttention("y"))
    }

    func test_displayStatus_distinguishesDisabledFromLive() {
        XCTAssertEqual(ModuleDisplayStatus.disabled, .disabled)
        XCTAssertEqual(ModuleDisplayStatus.live(.ok), .live(.ok))
        XCTAssertNotEqual(ModuleDisplayStatus.disabled, .live(.ok))
    }

    // MARK: - ModuleAction

    func test_moduleAction_runsItsWork() async {
        var ran = false
        let action = ModuleAction("Connect") { ran = true }
        XCTAssertEqual(action.label, "Connect")
        await action.perform()
        XCTAssertTrue(ran, "perform() runs the action's work")
    }

    // MARK: - Module / ActiveModule

    func test_trivialModule_defaultsToOkAndNoActions() {
        let m = Module(id: SourceID(raw: "weather"), displayName: "Weather",
                       icon: .symbol("cloud.rain"), makeSource: { SpySource("weather") })
        let active = m.activate()
        XCTAssertEqual(active.status(), .ok, "trivial module is healthy by default")
        XCTAssertTrue(active.actions().isEmpty)
        XCTAssertEqual(active.source.id, SourceID(raw: "weather"))
    }

    func test_actions_reReadLiveState() {
        var connected = false
        let m = Module(id: SourceID(raw: "c"), displayName: "C", icon: .symbol("calendar")) {
            ActiveModule(source: SpySource("c"),
                         actions: { connected ? [] : [ModuleAction("Connect") {}] })
        }
        let active = m.activate()
        XCTAssertEqual(active.actions().count, 1, "shows Connect while not connected")
        connected = true
        XCTAssertTrue(active.actions().isEmpty, "action list re-reads live state, hides once connected")
    }

    func test_activate_buildsAFreshSourceEachTime() {
        var builds = 0
        let m = Module(id: SourceID(raw: "m"), displayName: "M", icon: .symbol("gear"),
                       makeSource: { builds += 1; return SpySource("m") })
        _ = m.activate(); _ = m.activate()
        XCTAssertEqual(builds, 2, "each activate() builds a fresh source (no resume)")
    }
}
