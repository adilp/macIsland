import Foundation

/// The core's single injected time dependency — the seam that makes every timer in
/// macIsland deterministic. The core never reads wall time directly: it stamps
/// `receivedAt` and arms transient auto-dismiss timers through this protocol, so a
/// test drives the fake clock by hand and no real time passes (unified spec's
/// Testing Decisions; ticket "verified … with a fake clock, no wall-clock sleeps").
///
/// Two responsibilities:
/// - **`now()`** — a monotonic-within-a-run timestamp. Stamps `receivedAt` (stack
///   ordering) and lets the core compute how much of a transient's life remains, so
///   hover-pause can freeze a countdown and re-arm it later without losing time.
/// - **`schedule(after:_:)`** — a **one-shot** fire after an interval (never a
///   repeating timer: a pending one-shot is not idle cost, per the perf budget §I-5),
///   cancellable through the returned handle.
///
/// Production uses `SystemClock`; tests inject a hand-advanced fake. `@MainActor`
/// because the core it serves is `@MainActor` and every fire lands on the stack.
@MainActor
public protocol Clock: AnyObject {
    /// The current instant on this clock's timeline.
    func now() -> Date
    /// Run `fire` once, after `interval` elapses on this clock. Cancel via the
    /// returned handle to prevent the fire. `fire` is `async` so a test's
    /// `advance(by:)` can run it to completion inline (deterministic); production
    /// hops it onto the main actor.
    @discardableResult
    func schedule(after interval: Duration, _ fire: @escaping @MainActor () async -> Void) -> Scheduled
}

/// A cancellable handle to one scheduled fire. Cancelling is idempotent and safe
/// after the fire has already run.
@MainActor
public protocol Scheduled: AnyObject {
    func cancel()
}

/// The production clock: wall time for `now()`, `DispatchQueue.main.asyncAfter` for
/// one-shot fires. The seam the core is tested *around* — injected, not exercised
/// in the headless suite (a real timer needs real time). Apple frameworks only.
@MainActor
public final class SystemClock: Clock {
    public init() {}

    public func now() -> Date { Date() }

    @discardableResult
    public func schedule(after interval: Duration, _ fire: @escaping @MainActor () async -> Void) -> Scheduled {
        let item = DispatchWorkItem { Task { @MainActor in await fire() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval.timeInterval, execute: item)
        return WorkItemScheduled(item)
    }

    /// One-shot fire backed by a cancellable `DispatchWorkItem`.
    private final class WorkItemScheduled: Scheduled {
        private let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }
}

public extension Duration {
    /// This duration as a `TimeInterval` (seconds). Bridges `Duration` (the model's
    /// time type) to Foundation's `Date`/dispatch deadlines.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
