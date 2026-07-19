import XCTest
@testable import MacIslandCore

private typealias Notification = MacIslandCore.Notification

/// Tests for `IslandCore.countdown(for:)` — the sampled per-card countdown the panel
/// reads to render a transient's thin depleting bar as ONE Core-Animation animation
/// (unified spec R2). The bar starts at `fractionRemaining` and animates linearly to
/// empty over `remaining`, unless `isPaused` (island-hover), when it holds. This is
/// the headless seam behind the "Full stacking interaction" ticket's frozen-bar
/// behaviour; the SwiftUI rendering itself is verified by build + run.
@MainActor
final class CountdownTests: XCTestCase {

    private func id(_ value: String) -> NotificationID {
        NotificationID(source: SourceID(raw: "dev"), value: value)
    }

    func test_stickyCard_hasNoCountdown() {
        let core = IslandCore(clock: TestClock())
        let handle = core.register(SpySource("dev"))!
        handle.post(Content(title: "pinned"), value: "s", presence: .sticky)

        XCTAssertNil(core.countdown(for: id("s")), "a sticky card arms no timer, so it has no countdown")
    }

    func test_unknownId_hasNoCountdown() {
        let core = IslandCore(clock: TestClock())
        core.register(SpySource("dev"))
        XCTAssertNil(core.countdown(for: id("nope")))
    }

    func test_transientCountdown_reflectsElapsedTime() async {
        let clock = TestClock()
        let core = IslandCore(clock: clock)
        let handle = core.register(SpySource("dev"))!
        handle.post(Content(title: "toast"), value: "t", presence: .transient(after: .seconds(10)))

        // On arrival: full bar, running.
        let start = core.countdown(for: id("t"))
        XCTAssertEqual(start?.total.timeInterval ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(start?.remaining.timeInterval ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(start?.fractionRemaining ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(start?.isPaused, false)

        // After 4s of a 10s life: 6s / 0.6 of the bar left, still running.
        await clock.advance(by: .seconds(4))
        let mid = core.countdown(for: id("t"))
        XCTAssertEqual(mid?.remaining.timeInterval ?? -1, 6, accuracy: 0.001)
        XCTAssertEqual(mid?.fractionRemaining ?? -1, 0.6, accuracy: 0.001)
        XCTAssertEqual(mid?.isPaused, false)
    }

    func test_hover_freezesCountdown_thenResumesWithTimeRemaining() async {
        let clock = TestClock()
        let core = IslandCore(clock: clock)
        let handle = core.register(SpySource("dev"))!
        handle.post(Content(title: "toast"), value: "t", presence: .transient(after: .seconds(10)))
        await clock.advance(by: .seconds(4))            // 6s remaining

        core.setHovering(true)
        let paused = core.countdown(for: id("t"))
        XCTAssertEqual(paused?.isPaused, true, "hover freezes the bar")
        XCTAssertEqual(paused?.remaining.timeInterval ?? -1, 6, accuracy: 0.001)

        // A long hover consumes no countdown time — the frozen bar holds.
        await clock.advance(by: .seconds(1000))
        let stillPaused = core.countdown(for: id("t"))
        XCTAssertEqual(stillPaused?.isPaused, true)
        XCTAssertEqual(stillPaused?.remaining.timeInterval ?? -1, 6, accuracy: 0.001,
                       "no time is lost while the pointer is over the island")

        // Resume: the bar restarts from exactly what was left.
        core.setHovering(false)
        let resumed = core.countdown(for: id("t"))
        XCTAssertEqual(resumed?.isPaused, false)
        XCTAssertEqual(resumed?.remaining.timeInterval ?? -1, 6, accuracy: 0.001)
    }

    func test_cardArrivingWhileHovered_startsFrozenAtFullBar() {
        let core = IslandCore(clock: TestClock())
        let handle = core.register(SpySource("dev"))!

        core.setHovering(true)
        handle.post(Content(title: "toast"), value: "t", presence: .transient(after: .seconds(5)))

        let cd = core.countdown(for: id("t"))
        XCTAssertEqual(cd?.isPaused, true, "a card that arrives while hovered starts frozen")
        XCTAssertEqual(cd?.fractionRemaining ?? -1, 1, accuracy: 0.001, "…at a full bar")
    }

    func test_upsert_refreshesCountdownTotalAndRemaining() async {
        let clock = TestClock()
        let core = IslandCore(clock: clock)
        let handle = core.register(SpySource("dev"))!
        handle.post(Content(title: "v1"), value: "t", presence: .transient(after: .seconds(5)))

        await clock.advance(by: .seconds(4))            // 1s left under the old timer
        handle.post(Content(title: "v2"), value: "t", presence: .transient(after: .seconds(8)))  // re-arm, new interval

        let cd = core.countdown(for: id("t"))
        XCTAssertEqual(cd?.total.timeInterval ?? -1, 8, accuracy: 0.001, "upsert adopts the new interval")
        XCTAssertEqual(cd?.remaining.timeInterval ?? -1, 8, accuracy: 0.001, "and refreshes the countdown to full")
    }
}
