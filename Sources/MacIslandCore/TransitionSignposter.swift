import os

/// Brackets each animated panel transition with an `os_signpost` **interval**, so the
/// active budget (perf spec §2) is measurable two ways:
///
/// 1. **Animation smoothness (spec §5.1 CI gate).** The interval carries a fixed
///    subsystem/category/name (`Signpost.*` below) that Instruments' *Animation
///    Hitches* instrument and an `XCTOSSignpostMetric(subsystem:category:name:)`
///    subscribe to — the "no dropped frames across an expand/collapse" check runs by
///    asserting no hitches inside these intervals on a windowed runner (procedure in
///    PERFORMANCE.md).
/// 2. **Snap-back (spec I‑2, headlessly testable).** The signposter counts intervals
///    in flight, so the app/core can assert it is **not** mid-transition at idle — the
///    load-bearing "no animation left running once a transition ends" invariant. When
///    the count is back to zero, no transition is animating.
///
/// One interval per transition: `begin()` returns a token the caller holds and passes
/// back to `end(_:)` when the animation completes. Intervals can genuinely **overlap** —
/// `PanelController.render()` fires on every stack, hover, and screen change, so a new
/// resize animation can start while a prior one is still running — so more than one may
/// be in flight at once. Each is tracked independently for two reasons: the in-flight
/// *count* is the snap-back gauge, and `OSSignposter.endInterval` requires the **exact
/// `OSSignpostIntervalState`** its `beginInterval` returned, so each open interval's
/// state must be held until its own completion closes it. `os` only — no third-party
/// dependency, in keeping with the core's zero-dep rule (spec §4). `@MainActor` because
/// every panel transition is driven on the main actor.
@MainActor
public final class TransitionSignposter {

    /// The stable identifiers a signpost-metric test / Instruments template subscribes
    /// to. Kept in one place so the measurement side and the emitting side can never
    /// drift apart.
    public enum Signpost {
        /// Shares the app's single unified-logging subsystem.
        public static let subsystem = Log.subsystem
        /// Its own category so the animation intervals are isolated from log messages.
        public static let category = "animation"
        /// The interval name bracketing one panel transition (expand / collapse / card
        /// enter / dismiss).
        public static let interval: StaticString = "PanelTransition"
    }

    private let signposter: OSSignposter
    /// Open intervals keyed by a private sequence number (`OSSignpostID` isn't
    /// `Hashable`), each holding the state `end` needs to close its `beginInterval`.
    /// The dictionary's `count` is the in-flight-transition gauge the snap-back
    /// assertion reads.
    private var active: [Int: OSSignpostIntervalState] = [:]
    private var nextKey = 0

    public init() {
        signposter = OSSignposter(subsystem: Signpost.subsystem, category: Signpost.category)
    }

    /// How many transitions are currently animating. `0` ⇒ quiescent (nothing to
    /// animate) — the snap-back invariant reads this after a transition completes.
    public var inFlightCount: Int { active.count }

    /// Whether any transition is mid-flight. The negation is the idle assertion: at
    /// rest this is `false`.
    public var isTransitioning: Bool { !active.isEmpty }

    /// Open an interval for a starting transition. Hold the returned token and hand it
    /// to `end(_:)` when the animation's completion handler fires.
    public func begin() -> Token {
        let key = nextKey
        nextKey += 1
        let state = signposter.beginInterval(Signpost.interval, id: signposter.makeSignpostID())
        active[key] = state
        return Token(key: key)
    }

    /// Close the interval opened by `begin()`. Idempotent — closing an already-closed
    /// (or unknown) token is a no-op, so a double completion can't unbalance the gauge
    /// or emit a dangling end.
    public func end(_ token: Token) {
        guard let state = active.removeValue(forKey: token.key) else { return }
        signposter.endInterval(Signpost.interval, state)
    }

    /// An opaque handle to one open interval — begin returns it, end consumes it.
    public struct Token: Sendable {
        fileprivate let key: Int
    }
}
