import XCTest
@testable import MacIslandCore

/// The headlessly-testable half of the active-budget instrumentation: the
/// `TransitionSignposter`'s in-flight gauge (the snap-back invariant I‑2 — "no
/// animation left running once a transition ends"). The *frame-level* smoothness this
/// same signpost enables — no hitches across an expand/collapse via
/// `XCTOSSignpostMetric` — needs a window server and is the documented windowed check
/// (PERFORMANCE.md); here we prove the gauge the app reads is balanced and idle-clean.
@MainActor
final class TransitionSignposterTests: XCTestCase {

    func test_idle_isNotTransitioning() {
        let sp = TransitionSignposter()
        XCTAssertEqual(sp.inFlightCount, 0)
        XCTAssertFalse(sp.isTransitioning, "a fresh signposter is quiescent — nothing animating")
    }

    func test_begin_opensOneInterval_end_snapsBackToIdle() {
        let sp = TransitionSignposter()

        let token = sp.begin()
        XCTAssertEqual(sp.inFlightCount, 1)
        XCTAssertTrue(sp.isTransitioning, "a transition is animating between begin and end")

        sp.end(token)
        XCTAssertEqual(sp.inFlightCount, 0)
        XCTAssertFalse(sp.isTransitioning, "once the transition ends the gauge snaps back to idle (I‑2)")
    }

    func test_end_isIdempotent_doubleEndDoesNotUnbalanceTheGauge() {
        let sp = TransitionSignposter()
        let token = sp.begin()
        sp.end(token)
        sp.end(token)   // a double completion must not underflow or re-close
        XCTAssertEqual(sp.inFlightCount, 0)
        XCTAssertFalse(sp.isTransitioning)
    }

    func test_overlappingTransitions_countIndependently_thenReturnToZero() {
        let sp = TransitionSignposter()

        let a = sp.begin()
        let b = sp.begin()
        XCTAssertEqual(sp.inFlightCount, 2, "two overlapping transitions are tracked separately")

        sp.end(a)
        XCTAssertEqual(sp.inFlightCount, 1, "closing one leaves the other open")

        sp.end(b)
        XCTAssertEqual(sp.inFlightCount, 0, "closing the last snaps back to the idle floor")
        XCTAssertFalse(sp.isTransitioning)
    }
}
