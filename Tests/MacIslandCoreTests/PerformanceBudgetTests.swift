import XCTest
@testable import MacIslandCore

/// `Notification` collides with `Foundation.Notification` (via XCTest); pin the bare
/// name to our value type for readable type-position use.
private typealias Notification = MacIslandCore.Notification

/// The **automatable half** of the performance & idle-cost budget (perf spec §5.1),
/// pinned as headless CI gates that fail the build on regression. Everything here runs
/// at the `IslandCore` / `SourceHandle` seam with a hand-advanced `TestClock` — no
/// panel, no window server, no wall-clock sleeps — so it is deterministic and reliable
/// on shared CI runners (the budget CI *cannot* measure reliably — idle 0.0% CPU via
/// `powermetrics` — stays the documented manual pre-release check in PERFORMANCE.md,
/// spec §5.2/§5.3).
///
/// What each block gates, mapped to the ticket's acceptance criteria:
/// - **No-leak churn** — fire + dismiss many notifications and prove the core returns
///   to baseline: the stack empties, **zero** timers stay armed, and phys footprint
///   does not grow monotonically (a leak is exactly what would creep idle memory up
///   over a session — spec §1.3).
/// - **Idle memory ceiling** — settled phys footprint stays under the 100 MB hard
///   ceiling (spec §1.3).
/// - **Quiescent at idle (I‑1) + snap-back (I‑2)** — with nothing displayed, no timer
///   is armed; and after *every* transition (expire / dismiss / act) the armed-timer
///   count returns straight to the idle floor of zero. The `Clock` seam offers only
///   one-shots (`schedule(after:)`), so a *repeating* timer is structurally
///   impossible — the assertion is that the count returns to **0**, i.e. nothing is
///   left running.
@MainActor
final class PerformanceBudgetTests: XCTestCase {

    // MARK: - Fixtures

    /// A hermetic core: hand-advanced clock, spy audio (no real `NSSound`), no real
    /// `NSWorkspace` open. The clock's `armedCount` is the introspection the
    /// quiescence/snap-back assertions read.
    private func makeCore() -> (core: IslandCore, clock: TestClock) {
        let clock = TestClock()
        let core = IslandCore(clock: clock, alerter: Alerter(audio: SpyAudio(), clock: clock))
        return (core, clock)
    }

    // MARK: - No-leak churn (spec §5.1: "memory returns to the idle baseline")

    /// Fire + dismiss many notifications; the core must come back to *exactly* the
    /// empty baseline — no retained card, no leaked auto-dismiss timer. This is the
    /// deterministic, allocator-noise-free half of the no-leak check: a leaked card or
    /// timer shows up structurally, not just as bytes.
    func test_churn_returnsStackToBaseline_andArmsNoTimers() async {
        let (core, clock) = makeCore()
        let handle = core.register(SpySource("dev"))!

        for i in 0..<2_000 {
            handle.post(Content(title: "n\(i)"), value: "\(i)", presence: .transient(after: .seconds(5)))
            await core.dismiss(NotificationID(source: SourceID(raw: "dev"), value: "\(i)"))
        }

        XCTAssertTrue(core.ordered.isEmpty, "every posted card was dismissed — the stack must be empty")
        XCTAssertEqual(clock.armedCount, 0, "no auto-dismiss timer may outlive its dismissed card")
    }

    /// The same churn, but proving *phys footprint* returns to baseline (spec §1.3:
    /// "not growing as notifications come and go"). A genuine per-notification leak
    /// grows linearly with the churn count and would blow past the tolerance; ordinary
    /// allocator hysteresis stays well under it. The structural check above is the
    /// strong gate; this is the belt-and-suspenders byte-level regression gate.
    func test_churn_physFootprintReturnsToBaseline() async throws {
        let (core, _) = makeCore()
        let handle = core.register(SpySource("dev"))!

        // Warm up so first-touch allocations (dictionaries, small pools) are already
        // paid before we sample the baseline.
        await churn(handle: handle, core: core, count: 500, offset: 0)

        guard let baseline = MemoryFootprint.current() else {
            throw XCTSkip("phys footprint unavailable on this host")
        }

        // A leak of even ~1 KB per notification would be ~5 MB over this run.
        for batch in 0..<10 {
            await churn(handle: handle, core: core, count: 500, offset: (batch + 1) * 500)
        }

        guard let after = MemoryFootprint.current() else {
            throw XCTSkip("phys footprint unavailable on this host")
        }

        XCTAssertTrue(core.ordered.isEmpty, "churn must leave the stack empty")
        let grewBy = Int64(after) - Int64(baseline)
        XCTAssertLessThan(
            grewBy, 25 * 1_024 * 1_024,
            "phys footprint grew \(grewBy / (1_024 * 1_024)) MB across 5000 fire+dismiss cycles — a leak"
        )
    }

    /// Post + dismiss `count` transient cards (distinct values via `offset`), awaiting
    /// each dismiss so no work is left in flight when the loop returns.
    private func churn(handle: SourceHandle, core: IslandCore, count: Int, offset: Int) async {
        for i in offset..<(offset + count) {
            handle.post(Content(title: "n\(i)"), value: "\(i)", presence: .transient(after: .seconds(5)))
            await core.dismiss(NotificationID(source: SourceID(raw: "dev"), value: "\(i)"))
        }
    }

    // MARK: - Idle memory ceiling (spec §1.3: hard ceiling 100 MB phys footprint)

    /// A settled, idle core's phys footprint stays under the 100 MB hard ceiling.
    ///
    /// Honest scope: this runs in the headless test host, not the shipped SwiftUI-on-
    /// AppKit app process — so it verifies the **core target adds near-zero of its own**
    /// (spec §1.3's "light = adds near-zero on top") and catches a gross regression. The
    /// authoritative ≤100 MB reading against the *app* is the manual pre-release
    /// procedure in PERFORMANCE.md (spec §5.2), which measures the real resident process.
    func test_idleFootprint_underCeiling() throws {
        let (core, _) = makeCore()
        _ = core.register(SpySource("dev"))!   // registered but idle — nothing displayed

        guard let footprint = MemoryFootprint.current() else {
            throw XCTSkip("phys footprint unavailable on this host")
        }
        // Sanity floor: a live process always reports megabytes — guards against the
        // reading silently coming back as 0/garbage and passing the ceiling vacuously.
        XCTAssertGreaterThan(footprint, 1_024 * 1_024, "phys footprint reading looks bogus (< 1 MB)")
        XCTAssertLessThan(
            footprint, 100 * 1_024 * 1_024,
            "idle phys footprint \(footprint / (1_024 * 1_024)) MB exceeds the 100 MB ceiling"
        )
    }

    // MARK: - Quiescent at idle (I‑1) + snap-back after every transition (I‑2)

    /// The load-bearing idle invariant: with nothing displayed, **no** timer is armed.
    /// The `Clock` seam has no repeating-fire API at all, so "no display-link / repeating
    /// timer at idle" reduces to "the armed one-shot count is zero when idle".
    func test_idle_isQuiescent_noArmedTimers() {
        let (core, clock) = makeCore()
        _ = core.register(SpySource("dev"))!
        XCTAssertEqual(clock.armedCount, 0, "an idle core arms no timers — nothing drives the process")
    }

    /// Each armed transient is exactly one one-shot — never a periodic/repeating timer.
    /// Arming N transients arms N fires; letting them all elapse returns to zero.
    func test_transients_armExactlyOneOneShotEach_thenReturnToZero() async {
        let (core, clock) = makeCore()
        let handle = core.register(SpySource("dev"))!

        for i in 0..<8 {
            handle.post(Content(title: "n\(i)"), value: "\(i)", presence: .transient(after: .seconds(5)))
        }
        XCTAssertEqual(clock.armedCount, 8, "one one-shot per transient card — no periodic timers")

        await clock.advance(by: .seconds(5))     // all fire once and are consumed
        XCTAssertTrue(core.ordered.isEmpty)
        XCTAssertEqual(clock.armedCount, 0, "one-shots are consumed on fire — nothing re-arms")
    }

    /// Snap-back through **expiry**: a transient's timer fires, the card leaves, and the
    /// core is quiescent again — no animation/timer left running (I‑2).
    func test_snapBack_afterExpire_returnsToIdleFloor() async {
        let (core, clock) = makeCore()
        let handle = core.register(SpySource("dev"))!

        handle.post(Content(title: "toast"), value: "t", presence: .transient(after: .seconds(5)))
        XCTAssertEqual(clock.armedCount, 1)

        await clock.advance(by: .seconds(6))
        XCTAssertTrue(core.ordered.isEmpty)
        XCTAssertEqual(clock.armedCount, 0, "after the transition (expire) the timer count snaps back to the idle floor")
    }

    /// Snap-back through **dismiss** (the user path): dismissing the last card leaves the
    /// core idle with no armed timer.
    func test_snapBack_afterDismiss_returnsToIdleFloor() async {
        let (core, clock) = makeCore()
        let handle = core.register(SpySource("dev"))!

        handle.post(Content(title: "toast"), value: "t", presence: .transient(after: .seconds(5)))
        XCTAssertEqual(clock.armedCount, 1)

        await core.dismiss(NotificationID(source: SourceID(raw: "dev"), value: "t"))
        XCTAssertTrue(core.ordered.isEmpty)
        XCTAssertEqual(clock.armedCount, 0, "after the transition (dismiss) the timer count snaps back to the idle floor")
    }

    /// Snap-back through **act**: firing a dismiss-on-tap action removes the card and
    /// leaves nothing armed.
    func test_snapBack_afterAction_returnsToIdleFloor() async {
        let (core, clock) = makeCore()
        let handle = core.register(SpySource("dev"))!

        handle.post(
            Content(title: "toast"),
            value: "t",
            actions: [Action(label: "Open", behavior: .openURL(URL(string: "https://example.com")!))],
            presence: .transient(after: .seconds(5))
        )
        XCTAssertEqual(clock.armedCount, 1)

        await core.fireAction(NotificationID(source: SourceID(raw: "dev"), value: "t"), at: 0)
        XCTAssertTrue(core.ordered.isEmpty)
        XCTAssertEqual(clock.armedCount, 0, "after the transition (act) the timer count snaps back to the idle floor")
    }
}
