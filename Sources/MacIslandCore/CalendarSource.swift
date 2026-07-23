import Foundation

/// The one built-in `NotificationSource` (Calendar spec 06, unified §5) — a thin
/// EventKit→`handle.post` adapter with **zero calendar-specific code in the core**. It
/// maps the `CalendarEngine`'s meeting facts onto domain `Notification`s: a **T-5**
/// transient warning for every timed meeting, and a **T-1** sticky ringing **Join**
/// card (same `eventIdentifier`, so it updates the T-5 in place) for video meetings.
///
/// The core cannot tell it from a socket-backed `SocketSource`: it only ever
/// `handle.post`/`handle.revoke`s, never touching the notch, rendering, or sound (the
/// core owns those). Join is a declarative `openURL` the core runs itself, so this
/// source implements no `onAction`.
///
/// `@MainActor` like `SocketSource`: it touches the `@MainActor` core through its handle
/// and its engine runs on the same actor, so its state stays race-free without locks.
@MainActor
public final class CalendarSource: NotificationSource {
    public let id = SourceID(raw: "calendar")

    private let engine: CalendarEngine
    /// Held so `emit` can stamp the static relative-time body at post time (spec §4).
    /// The same clock the engine schedules on, so the "now" a card reads is the fire
    /// instant.
    private let clock: any Clock
    private var handle: SourceHandle?

    /// - Parameters:
    ///   - store: the EventKit seam. Production passes `EventKitStore()`; tests inject a
    ///     fake (ticket criterion 1).
    ///   - clock: the injected time source, shared with the core so all timers — the
    ///     engine's T-5/T-1/end and the core's ring timeout — share one timeline.
    public init(store: any MeetingStore, clock: any Clock) {
        self.clock = clock
        self.engine = CalendarEngine(store: store, clock: clock)
    }

    // MARK: - NotificationSource

    public func start(_ handle: SourceHandle) async throws {
        self.handle = handle
        engine.onFire = { [weak self] meeting, moment in self?.emit(meeting, moment) }
        engine.onRevoke = { [weak self] eventId in self?.handle?.revoke(eventId) }
        await engine.bootstrap()   // permission check + (maybe) request + monitoring
    }

    public func onClosed(_ value: String, reason: CloseReason) async throws {
        // T-5 acknowledged early (dismissed / joined) → drop the pending ring (spec §6).
        // Ignored (`.expired`) leaves the schedule so the ring still fires.
        if reason == .dismissed || reason == .acted { engine.cancelPending(value) }
    }

    public func stop() async throws {
        engine.teardown()
    }

    // MARK: - Upgrade hooks (spec §2) — a future menu-bar "Connect Calendar…" affordance

    /// Current calendar authorization (a later menu item can deep-link to Settings).
    public var authorizationStatus: CalendarAuthorization { engine.authorizationStatus }

    /// User-initiated access request, driving the same grant→monitor path as first-run.
    @discardableResult
    public func requestAccess() async -> Bool { await engine.requestAccess() }

    // MARK: - Meeting → Notification mapping (spec §4)

    private func emit(_ meeting: MeetingEvent, _ moment: Moment) {
        switch moment {
        case .early:
            // T-5 — early warning, every meeting: a ~10s transient, one arrival sound,
            // no Join. Body uses the relative-time helper (spec §7: "keep the
            // relative-time string helpers (feed `Content.body`)"), computed once at
            // post time — so it reads "in 5 minutes · <cal>" at the canonical T-5 mark
            // and stays truthful (e.g. "in 3 minutes") for a meeting first seen <5min
            // out, without ever ticking (spec §4: static text, not a live countdown).
            handle?.post(Notification(
                id: NotificationID(source: id, value: meeting.id),
                content: Content(
                    title: meeting.title,
                    body: "\(meeting.relativeTimeDescription(now: clock.now())) · \(meeting.calendarName)",
                    icon: .symbol(meeting.hasVideoLink ? "video.fill" : "calendar"),
                    tint: meeting.tint),
                actions: [],
                presence: .transient(after: .seconds(10)),
                alerting: .soundOnce))

        case .imminent:
            // T-1 — imminent, video only: the same id upserts the T-5 into a persistent
            // ringing Join card the core opens itself.
            postJoinCard(meeting, body: "starting now", alerting: .ringing())

        case .inProgress:
            // Already underway (a start missed across sleep): the same sticky Join card,
            // but silent and honestly labelled — it appears so the meeting can be joined,
            // without an incoming-call ring for something that began minutes ago.
            postJoinCard(meeting, body: "in progress · \(meeting.calendarName)", alerting: .silent)
        }
    }

    /// The sticky Join card for a video meeting — shared by the T-1 ring and the underway
    /// silent variant, which differ only in body text and sound level. No-op for a meeting
    /// without a parseable link (nothing to join).
    private func postJoinCard(_ meeting: MeetingEvent, body: String, alerting: Alerting) {
        guard let link = meeting.videoLink else { return }
        handle?.post(Notification(
            id: NotificationID(source: id, value: meeting.id),
            content: Content(
                title: meeting.title,
                body: body,
                icon: .symbol("video.fill"),
                tint: meeting.tint),
            actions: [Action(
                label: "Join \(link.type.displayName)",
                behavior: .openURL(link.url),
                dismissOnTap: true)],
            presence: .sticky,
            alerting: alerting))
    }
}
