import XCTest
@testable import MacIslandCore

private typealias Notification = MacIslandCore.Notification

/// Tests for `IslandCore.onChange` — the single core→panel render signal the SwiftUI
/// island observes (the `stack → panel` edge of the unified spec's data-flow
/// diagram). Fired after any mutation that changes `ordered`; a no-op (revoking an
/// unknown id) must not fire it, so the panel doesn't re-render for nothing.
@MainActor
final class IslandCoreObservationTests: XCTestCase {

    func test_onChange_firesOnPost_andOnDismiss() async {
        let core = IslandCore(clock: TestClock())
        var ticks = 0
        core.onChange = { ticks += 1 }

        let handle = core.register(SpySource("dev"))
        handle?.post(Content(title: "Hello"), value: "1", presence: .sticky)
        XCTAssertEqual(ticks, 1, "posting a card is a render-relevant change")

        await core.dismiss(NotificationID(source: SourceID(raw: "dev"), value: "1"))
        XCTAssertEqual(ticks, 2, "dismissing a card is a render-relevant change")
    }

    func test_onChange_doesNotFireForNoOpRevoke() async {
        let core = IslandCore(clock: TestClock())
        core.register(SpySource("dev"))

        var ticks = 0
        core.onChange = { ticks += 1 }

        // Revoking an id that was never posted changes nothing on screen.
        core.ordered.forEach { _ in }                 // (no cards)
        let handle = core.register(SpySource("other"))
        handle?.revoke("does-not-exist")
        XCTAssertEqual(ticks, 0, "a no-op revoke must not trigger a re-render")
    }
}
