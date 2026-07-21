import XCTest
@testable import MacIslandCore

private typealias Notification = MacIslandCore.Notification

@MainActor
final class UnregisterCardSweepTests: XCTestCase {
    func test_unregister_revokingCards_sweepsEvenWhenSourceDidNotOptIn() async {
        let core = IslandCore(clock: TestClock())
        // SpySource defaults revokeOnDisconnect = false (the fire-and-forget default).
        let handle = core.register(SpySource("gh"))
        handle?.post(Content(title: "Deploy running"), value: "run-1", presence: .sticky)
        XCTAssertEqual(core.ordered.count, 1)

        await core.unregister(SourceID(raw: "gh"), revokingCards: true)

        XCTAssertTrue(core.ordered.isEmpty, "disable sweeps the module's cards")
        XCTAssertFalse(core.liveSourceIDs.contains(SourceID(raw: "gh")))
    }

    func test_unregister_default_stillHonorsFireAndForget() async {
        let core = IslandCore(clock: TestClock())
        let handle = core.register(SpySource("ci"))   // revokeOnDisconnect = false
        handle?.post(Content(title: "toast"), value: "t1", presence: .sticky)

        await core.unregister(SourceID(raw: "ci"))    // default: no sweep

        XCTAssertEqual(core.ordered.count, 1, "default unregister leaves cards (unchanged)")
    }

    func test_unregister_sweep_firesOnChange() async {
        let core = IslandCore(clock: TestClock())
        let handle = core.register(SpySource("gh"))
        handle?.post(Content(title: "x"), value: "1", presence: .sticky)
        var ticks = 0
        core.onChange = { ticks += 1 }
        await core.unregister(SourceID(raw: "gh"), revokingCards: true)
        XCTAssertEqual(ticks, 1, "sweeping a visible card re-renders the panel")
    }
}
