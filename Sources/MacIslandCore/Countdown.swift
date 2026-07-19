import Foundation

/// A transient card's countdown, **sampled at snapshot time** — exactly what the
/// panel needs to render its thin depleting bar as ONE Core-Animation animation
/// (unified spec R2, reconciliation): the bar starts at `fractionRemaining` of its
/// width and animates linearly to empty over `remaining`, unless `isPaused`
/// (island-hover), when it holds in place. A sticky card has no countdown, so
/// `IslandCore.countdown(for:)` returns `nil` for it.
///
/// This is a plain value: the core samples it from the live timer, the panel renders
/// it, and no live time source crosses the boundary — so the bar is a render-server
/// animation, not a per-frame CPU loop (perf budget §I-5 / R2).
public struct Countdown: Equatable, Sendable {
    /// The card's full transient interval — its `.transient(after:)` duration. The
    /// bar's 100% width. Held across an in-place update only if the interval is
    /// unchanged; a re-post with a new interval adopts the new `total`.
    public let total: Duration
    /// Time left before auto-dismiss at the instant this was sampled. Frozen at the
    /// paused value while `isPaused`.
    public let remaining: Duration
    /// Whether the countdown is paused (frozen) because the island is hovered.
    public let isPaused: Bool

    public init(total: Duration, remaining: Duration, isPaused: Bool) {
        self.total = total
        self.remaining = remaining
        self.isPaused = isPaused
    }

    /// Fraction of the bar still to deplete, in `[0, 1]` (`remaining / total`,
    /// clamped). `0` when `total` is non-positive (degenerate) so the bar renders
    /// empty rather than `NaN`.
    public var fractionRemaining: Double {
        let t = total.timeInterval
        guard t > 0 else { return 0 }
        return min(1, max(0, remaining.timeInterval / t))
    }
}
