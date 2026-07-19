import Foundation

/// Which moment fired for a meeting — the two the reference scheduled (`earlyWarning` /
/// `starting`), renamed to macIsland's language.
enum Moment: Equatable, Sendable {
    /// T-5: the early warning, for every timed meeting.
    case early
    /// T-1: imminent, for video-link meetings only.
    case imminent
}

/// The reshaped `CalendarService` (Calendar spec §7) — the pure timing engine behind
/// `CalendarSource`. It discovers meetings through the injected `MeetingStore`, arms
/// the per-meeting T-5 / T-1 / end-of-meeting one-shots on the injected `Clock`, and
/// signals the source through `onFire` (post a card) / `onRevoke` (remove a leftover
/// card). It holds **no EventKit and no domain-notification knowledge** — the source
/// maps a `MeetingEvent` + `Moment` onto a `Notification`.
///
/// Scheduling uses the core `Clock`'s one-shots rather than `Timer.scheduledTimer`, so
/// the whole engine is deterministic under a fake clock and consistent with the perf
/// posture (a pending one-shot is not idle cost — spec §3, unified §I-5).
@MainActor
final class CalendarEngine {
    private let store: any MeetingStore
    private let clock: any Clock

    /// Post a card for this meeting/moment.
    var onFire: (@MainActor (MeetingEvent, Moment) -> Void)?
    /// Revoke this meeting's (possibly-leftover) card — endDate reached, or the meeting
    /// was deleted/moved out of the look-ahead.
    var onRevoke: (@MainActor (String) -> Void)?

    /// The 24h look-ahead (spec §3).
    private static let lookAhead: Duration = .seconds(24 * 60 * 60)

    /// The warning one-shots (T-5 / T-1), keyed `"<eventId>-T5"` / `"<eventId>-T1"`.
    /// Recomputed wholesale on every refresh (event-scheduling, not geometry polling).
    private var warningTimers: [String: Scheduled] = [:]
    /// The end-of-meeting self-revoke one-shots, keyed by eventId. Re-armed on refresh
    /// for every present video meeting so an edited endDate is picked up, and a vanished
    /// meeting's timer simply isn't re-armed.
    private var endTimers: [String: Scheduled] = [:]
    /// The event ids seen in the last fetch — diffed against a fresh fetch to detect a
    /// vanished meeting (deleted, or moved out of the window) and revoke its card.
    private var knownEventIDs: Set<String> = []

    init(store: any MeetingStore, clock: any Clock) {
        self.store = store
        self.clock = clock
    }

    // MARK: - Lifecycle

    /// The authorization + monitoring boot (spec §2). Auto-requests access on first
    /// launch; begins monitoring once authorized; stays inert when denied.
    func bootstrap() async {
        switch store.authorization {
        case .authorized:
            startMonitoring()
        case .notDetermined:
            if await store.requestAccess() { startMonitoring() }
        case .denied:
            break   // inert — produce zero notifications, no retry loop (spec §2)
        }
    }

    /// The upgrade hook (spec §2): a future menu-bar "Connect Calendar…" affordance can
    /// drive the same grant→monitor path without a redesign.
    @discardableResult
    func requestAccess() async -> Bool {
        let granted = await store.requestAccess()
        if granted { startMonitoring() }
        return granted
    }

    /// Current authorization — re-read on demand (EventKit has no auth-changed signal).
    var authorizationStatus: CalendarAuthorization { store.authorization }

    private func startMonitoring() {
        store.observeChanges { [weak self] in self?.refresh() }
        refresh()
    }

    /// Cancel every pending fire and drop the observer — the uniform teardown.
    func teardown() {
        store.stopObserving()
        for t in warningTimers.values { t.cancel() }
        warningTimers.removeAll()
        for t in endTimers.values { t.cancel() }
        endTimers.removeAll()
        knownEventIDs.removeAll()
    }

    /// The user acknowledged a meeting's T-5 warning (dismiss/act) — cancel its pending
    /// T-1 ring so we don't nag (spec §6: "cancels the meeting's pending `-T1` timer").
    /// The end-revoke timer is deliberately left alone: it's harmless if no sticky card
    /// posts, and it still protects a card the next refresh might resurrect.
    func cancelPending(_ eventId: String) {
        for suffix in ["-T5", "-T1"] {
            let key = eventId + suffix
            warningTimers[key]?.cancel()
            warningTimers[key] = nil
        }
    }

    // MARK: - Discovery & scheduling

    /// Re-fetch the 24h look-ahead and reschedule (spec §3). Revokes any meeting that
    /// vanished since the last fetch, then rearms warnings + end-revokes for the
    /// current set. Called on the initial monitor start and on every `EKEventStoreChanged`.
    private func refresh() {
        let now = clock.now()
        let meetings = store.upcomingMeetings(within: Self.lookAhead, now: now)
        let currentIDs = Set(meetings.map(\.id))

        // A meeting present before but absent now (deleted, or moved past its end) →
        // revoke its (possibly-live) card. Idempotent for a card that already expired.
        for gone in knownEventIDs.subtracting(currentIDs) { revoke(gone) }
        knownEventIDs = currentIDs

        cancelAllWarningTimers()
        cancelAllEndTimers()
        for meeting in meetings {
            scheduleWarnings(meeting, now: now)
            scheduleEndRevoke(meeting, now: now)
        }
    }

    /// Arm T-5 (all meetings) and T-1 (video only), firing immediately if already inside
    /// the respective window — verbatim to the reference's timing (spec §3).
    private func scheduleWarnings(_ meeting: MeetingEvent, now: Date) {
        let untilStart = meeting.startDate.timeIntervalSince(now)
        guard untilStart > 0 else { return }   // already started — nothing to warn about

        // T-5, for every meeting.
        let t5 = untilStart - 300
        if t5 > 0 {
            arm(meeting.id + "-T5", after: .seconds(t5)) { [weak self] in self?.onFire?(meeting, .early) }
        } else {
            onFire?(meeting, .early)            // inside the 5-min window → fire now
        }

        // T-1, video-link meetings only.
        guard meeting.hasVideoLink else { return }
        let t1 = untilStart - 60
        if t1 > 0 {
            arm(meeting.id + "-T1", after: .seconds(t1)) { [weak self] in self?.onFire?(meeting, .imminent) }
        } else {
            onFire?(meeting, .imminent)         // inside the 1-min window → fire now
        }
    }

    /// Arm the leftover sticky card's self-revoke at `endDate` (video meetings only —
    /// non-video cards are transient and self-expire). The meeting's over, so joining is
    /// moot; the card clears even if never touched (spec §5).
    private func scheduleEndRevoke(_ meeting: MeetingEvent, now: Date) {
        guard meeting.hasVideoLink else { return }
        let untilEnd = meeting.endDate.timeIntervalSince(now)
        guard untilEnd > 0 else { return }
        let id = meeting.id
        endTimers[id] = clock.schedule(after: .seconds(untilEnd)) { [weak self] in
            self?.revoke(id)
        }
    }

    // MARK: - Timer bookkeeping

    private func arm(_ key: String, after interval: Duration, _ fire: @escaping @MainActor () -> Void) {
        warningTimers[key]?.cancel()
        warningTimers[key] = clock.schedule(after: interval) { [weak self] in
            self?.warningTimers[key] = nil
            fire()
        }
    }

    private func revoke(_ eventId: String) {
        endTimers[eventId]?.cancel()
        endTimers[eventId] = nil
        onRevoke?(eventId)
    }

    private func cancelAllWarningTimers() {
        for t in warningTimers.values { t.cancel() }
        warningTimers.removeAll()
    }

    private func cancelAllEndTimers() {
        for t in endTimers.values { t.cancel() }
        endTimers.removeAll()
    }
}
