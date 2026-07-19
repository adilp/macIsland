import Foundation

/// Calendar access state, collapsed to the three cases macIsland acts on (min macOS
/// 14, so the legacy `.authorized` branch is dropped — spec §2/§8.2). The concrete
/// `EventKitStore` maps `EKAuthorizationStatus` onto this; the source stays inert
/// unless `.authorized`.
public enum CalendarAuthorization: Equatable, Sendable {
    /// Never asked — the source auto-requests on first launch (spec §2).
    case notDetermined
    /// Full access granted — the source monitors and posts.
    case authorized
    /// Denied / restricted / write-only — the source is inert (posts nothing).
    case denied
}

/// The EventKit seam — the injected dependency that makes the `CalendarEngine`
/// testable with a **fake store + injected `Clock`** (ticket criterion 1), exactly as
/// `Clock`, `AudioOutput`, and `Connection` are the seams the rest of the core is
/// tested around. Production is `EventKitStore` (the one EventKit-importing file);
/// tests inject `FakeMeetingStore`. The engine never touches `EventKit` directly — it
/// speaks only in plain `MeetingEvent` values.
///
/// `@MainActor` because the engine it serves is `@MainActor` and every fetch/observe
/// lands on the stack.
@MainActor
public protocol MeetingStore: AnyObject {
    /// Current calendar authorization (a live read — EventKit has no "auth changed"
    /// signal, so the engine re-reads it; spec §2).
    var authorization: CalendarAuthorization { get }

    /// Prompt for full calendar access (the single OS dialog). Returns whether it was
    /// granted; updates `authorization` as a side effect.
    func requestAccess() async -> Bool

    /// The meetings overlapping `[now, now + horizon]` — all-day events excluded,
    /// sorted by start. The 24h look-ahead (spec §3) is the horizon the engine passes.
    func upcomingMeetings(within horizon: Duration, now: Date) -> [MeetingEvent]

    /// Register a change observer (production: `EKEventStoreChanged`). The engine wires
    /// this to a re-fetch + reschedule; only one observer is active at a time.
    func observeChanges(_ onChange: @escaping @MainActor () -> Void)

    /// Remove the change observer — part of the engine's uniform teardown.
    func stopObserving()
}
