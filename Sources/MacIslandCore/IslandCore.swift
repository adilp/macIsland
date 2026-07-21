import Foundation
import AppKit

/// The headless heart — the `@MainActor` core that owns the live set of
/// notifications and drives every registered `NotificationSource` uniformly. It
/// applies post/upsert/revoke, exposes the computed render order, arms per-card
/// transient auto-dismiss timers through the injected `Clock` (with a hover-pause
/// hook), routes actions, and reports every termination through `onClosed`. It is a
/// **dumb display + router**: it cannot tell a socket-backed source from an
/// EventKit-backed one, and a faulting source is logged + torn down but never
/// crashes it (unified spec §8.3). No panel — verified entirely at the
/// `SourceHandle` seam.
@MainActor
public final class IslandCore: SourceHandleTarget {

    // MARK: State

    /// The pure two-tier ordering logic (sticky > transient, newest-nearest-notch).
    private var stack = NotificationStack()
    /// `SourceID → registration`. A live card *is* a `Notification` whose
    /// `id.source` names its owner, so routing is a lookup here — no side table.
    private var registry: [SourceID: Registration] = [:]
    /// Per-card transient auto-dismiss timers, keyed by card id. Sticky cards have none.
    private var timers: [NotificationID: TransientTimer] = [:]
    /// While hovering, every transient countdown is frozen (spec 03; ticket
    /// "hover-pause signal freezes and resumes those timers").
    private var isHovering = false

    private let clock: Clock
    /// The core sound layer, driven from the card lifecycle (spec §8.1). Defaults to
    /// real system sounds; tests inject one over a spy-audio seam. Sources never touch
    /// it — the core alone decides what plays from a card's `Alerting` level.
    private let alerter: Alerter
    /// How an `openURL` action is run — core-run via `NSWorkspace` in production,
    /// injected as a spy at the seam. `openURL` needs no source round-trip and keeps
    /// working even after the owning source is gone (spec §4).
    private let openURL: @MainActor (URL) -> Void

    /// - Parameters:
    ///   - clock: the injected time source. Tests pass a hand-advanced fake.
    ///   - alerter: the sound layer; defaults to real system sounds on the same clock
    ///     (so the ring timeout shares the core's timeline). Tests inject a spy-audio one.
    ///   - openURL: runs an `openURL` action; defaults to `NSWorkspace`.
    public init(
        clock: Clock,
        alerter: Alerter? = nil,
        openURL: @escaping @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    ) {
        self.clock = clock
        self.alerter = alerter ?? Alerter(audio: SystemAudioOutput(), clock: clock)
        self.openURL = openURL
    }

    /// The render order the panel consumes: sticky above transient, newest nearest
    /// the notch. Derived, never stored.
    public var ordered: [PlacedNotification] { stack.ordered }

    /// The ids of every currently-registered (live) source. The panel reads this to
    /// enforce the orphan policy visually: a `callback` button on a card whose source
    /// is **not** in this set is disabled (it would fire into nothing), while `openURL`
    /// buttons — core-run — stay live regardless (spec §5). A card's `id.source` in
    /// this set means its callbacks still route.
    ///
    /// This is **advisory**, not load-bearing for safety: it is a snapshot the panel
    /// samples at render time, so a source can be torn down between render and tap.
    /// The authoritative check is at fire time — `fireAction` re-resolves
    /// `id.source → registry` and a callback into a vanished source is a logged no-op.
    /// So the disabled state is purely to avoid offering a dead button, never the thing
    /// that prevents a bad route.
    public var liveSourceIDs: Set<SourceID> { Set(registry.keys) }

    /// The transient countdown for a card, sampled now — or `nil` for a sticky card
    /// (no timer) or an unknown id. The panel reads this per visible card to render
    /// the thin depleting bar as one Core-Animation animation that freezes on hover
    /// (unified spec R2). Pure read: never mutates or re-arms anything.
    public func countdown(for id: NotificationID) -> Countdown? {
        guard let t = timers[id] else { return nil }
        // Running: remaining is computed live from the deadline. Paused: the frozen
        // leftover recorded when hover started (or the full interval for a card that
        // arrived while hovered). `scheduled == nil` is precisely "paused".
        let remaining = t.scheduled != nil ? t.liveRemaining(now: clock.now()) : t.remaining
        return Countdown(total: t.total, remaining: remaining, isPaused: t.scheduled == nil)
    }

    /// The single core→panel render signal — the `stack → panel` edge of the unified
    /// spec's data-flow diagram. Invoked synchronously after any mutation that changes
    /// `ordered` (post/upsert, revoke, revokeAll, dismiss, expire, act), so the panel
    /// re-reads `ordered` and re-sizes. A no-op mutation (revoking an unknown id) does
    /// not fire it. `nil` in the headless suite — set by the app at boot.
    public var onChange: (@MainActor () -> Void)?

    private func notifyChange() { onChange?() }

    // MARK: Registration

    /// Register a source: validate its id, hand it a `SourceHandle`, and drive its
    /// `start`. Returns the handle, or **`nil` if the id is already live** (no silent
    /// hijack — spec §3). A vacated id is re-adopted (its still-visible cards remain,
    /// and the new instance now owns their routing).
    @discardableResult
    public func register(_ source: any NotificationSource) -> SourceHandle? {
        let id = source.id
        guard registry[id] == nil else {
            Log.registry.error("register rejected: source id '\(id.raw, privacy: .public)' already live")
            return nil
        }
        let handle = SourceHandle(sourceID: id, target: self)
        let reg = Registration(source: source, handle: handle)
        registry[id] = reg
        Log.registry.info("registered source '\(id.raw, privacy: .public)'")
        // A source does its own long-lived work on its own task (spec §8.6), so
        // `start` returns promptly. We spawn it so a slow/blocking start can't stall
        // registration, and a THROW funnels into the same teardown as an explicit
        // unregister — the containment boundary (spec §8.3).
        reg.startTask = Task { [weak self] in
            do { try await source.start(handle) }
            catch { await self?.faultTeardown(id, error: error) }
        }
        return handle
    }

    /// Tear a source down uniformly — the one path for "a source goes away", whether
    /// the host saw its connection drop, the app is quitting, or a duplicate id was
    /// cleaned up (spec §5: a stopped source ≡ a dropped connection). Idempotent.
    public func unregister(_ id: SourceID, revokingCards: Bool = false) async {
        guard let reg = registry[id] else { return }
        registry[id] = nil                       // remove first: routing + re-entrancy see it gone
        reg.startTask?.cancel()
        // Orphan policy (spec §5): default is LEAVE the cards (fire-and-forget posts
        // and exits; auto-revoking would delete the card the instant it appeared).
        // Opt-in `revokeOnDisconnect` auto-revokes instead — for live-state cards
        // meaningless once the source is gone. `revokingCards` is the *caller* forcing
        // it regardless — the module toggle's "off means gone", so a disabled module
        // never strands a sticky pill behind it.
        if revokingCards || reg.source.revokeOnDisconnect {
            let mine = stack.ordered.filter { $0.id.source == id }
            for card in mine { removeCard(card.id) }
            if !mine.isEmpty {                   // a card left the screen → reconcile + re-render
                alerter.reconcile(stack.ordered)
                notifyChange()
            }
        }
        await safely(id) { try await reg.source.stop() }
        Log.registry.info("unregistered source '\(id.raw, privacy: .public)'")
    }

    // MARK: SourceHandleTarget (source → core push; every call carries the stamped id)

    func post(_ notification: Notification, from source: SourceID) {
        // A stale handle whose source was already torn down cannot post new cards.
        guard registry[source] != nil else {
            Log.stack.info("dropped post from unregistered source '\(source.raw, privacy: .public)'")
            return
        }
        // Reject-at-post + log a malformed value: the 0…2 action cap is a post-time
        // invariant the core enforces (unified §8.3, domain model §Actions).
        guard notification.actions.count <= 2 else {
            Log.stack.error("rejected post '\(notification.id.value, privacy: .public)': \(notification.actions.count) actions exceeds the 0…2 cap")
            return
        }
        stack.post(notification, receivedAt: clock.now())
        armTimer(for: notification)             // refreshes the countdown on upsert
        alerter.reconcile(stack.ordered)        // arrival chime / ring channel (spec §8.1)
        notifyChange()
    }

    func revoke(value: String, from source: SourceID) {
        guard registry[source] != nil else { return }
        let id = NotificationID(source: source, value: value)
        guard removeCard(id) != nil else { return }   // idempotent — no-op doesn't re-render
        alerter.reconcile(stack.ordered)
        notifyChange()
        reportClosed(source: source, value: value, reason: .revoked)
    }

    /// Whether a live card `(source, value)` exists — the truth an ingress `revoke`
    /// ack reads (spec §7), correct even for a re-adopted source's inherited cards.
    func hasCard(value: String, from source: SourceID) -> Bool {
        stack.placed(for: NotificationID(source: source, value: value)) != nil
    }

    func revokeAll(from source: SourceID) {
        guard registry[source] != nil else { return }
        let mine = stack.ordered.filter { $0.id.source == source }
        guard !mine.isEmpty else { return }
        for card in mine { removeCard(card.id) }
        alerter.reconcile(stack.ordered)
        notifyChange()
        for card in mine { reportClosed(source: source, value: card.id.value, reason: .revoked) }
    }

    // MARK: User-driven operations (panel → core)

    /// The user dismissed a card via the always-present ✕. Distinct from a source
    /// revoke; both remove by id, but the reported reason differs (spec §5).
    public func dismiss(_ id: NotificationID) async {
        guard removeCard(id) != nil else { return }
        alerter.reconcile(stack.ordered)
        notifyChange()
        await reportClosedAwaiting(source: id.source, value: id.value, reason: .dismissed)
    }

    /// The user tapped the action at `index` on a card (0 = primary). `openURL` is
    /// core-run; `callback` routes to the owning source's `onAction`. Firing dismisses
    /// by default (`dismissOnTap`), reporting `.acted`.
    public func fireAction(_ id: NotificationID, at index: Int) async {
        guard let placed = stack.placed(for: id),
              placed.notification.actions.indices.contains(index) else { return }
        let action = placed.notification.actions[index]

        // Firing any action is a ring-ending trigger (spec §8.1: "any action fired"),
        // whether or not the card is then dismissed.
        alerter.actionFired(on: id)

        switch action.behavior {
        case .openURL(let url):
            openURL(url)                                   // survives a dead source
        case .callback(let actionID):
            if let reg = registry[id.source] {
                await safely(id.source) { try await reg.source.onAction(id.value, actionID) }
            } else {
                Log.registry.info("callback on orphaned card '\(id.value, privacy: .public)' ignored (source gone)")
            }
        }

        if action.dismissOnTap {
            guard removeCard(id) != nil else { return }
            alerter.reconcile(stack.ordered)
            notifyChange()
            await reportClosedAwaiting(source: id.source, value: id.value, reason: .acted)
        }
        // dismissOnTap == false → the card stays for the source's in-place update.
    }

    /// Island-hover pause: freeze every transient countdown, or resume them. Freezing
    /// records each timer's *remaining* time and cancels the scheduled fire; resuming
    /// re-arms from `now + remaining`, so no time is lost while hovered — and no
    /// wall-clock sleep is involved (ticket criterion 2).
    public func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering {
            for (_, t) in timers where t.scheduled != nil {
                t.remaining = t.liveRemaining(now: clock.now())   // freeze at what's left
                t.scheduled?.cancel()
                t.scheduled = nil
            }
        } else {
            for (id, t) in timers where t.scheduled == nil {
                t.deadline = clock.now().addingTimeInterval(t.remaining.timeInterval)
                t.scheduled = clock.schedule(after: t.remaining) { [weak self] in
                    await self?.expire(id)
                }
            }
        }
    }

    // MARK: Transient timers

    private func armTimer(for n: Notification) {
        // An upsert refreshes the countdown: cancel any prior timer for this id.
        timers[n.id]?.scheduled?.cancel()
        timers[n.id] = nil
        guard case .transient(let interval) = n.presence else { return }   // sticky → no timer
        let timer = TransientTimer(
            total: interval,
            remaining: interval,
            deadline: clock.now().addingTimeInterval(interval.timeInterval)
        )
        timers[n.id] = timer
        // A card arriving while hovered starts frozen (full remaining, no schedule);
        // resume arms it. Otherwise arm the one-shot now.
        guard !isHovering else { return }
        timer.scheduled = clock.schedule(after: interval) { [weak self] in
            await self?.expire(n.id)
        }
    }

    /// A transient's timer elapsed. Remove the card and report `.expired`.
    private func expire(_ id: NotificationID) async {
        guard timers[id] != nil else { return }        // superseded/cancelled
        guard removeCard(id) != nil else { return }
        alerter.reconcile(stack.ordered)
        notifyChange()
        await reportClosedAwaiting(source: id.source, value: id.value, reason: .expired)
    }

    // MARK: Removal + reporting helpers

    /// Remove a card by id and cancel its timer. The *reason* is the caller's to
    /// report — the stack itself is reason-agnostic. Returns the removed value.
    @discardableResult
    private func removeCard(_ id: NotificationID) -> Notification? {
        timers[id]?.scheduled?.cancel()
        timers[id] = nil
        return stack.revoke(id)
    }

    /// Report `.acted`/`.dismissed`/`.expired` to a live owning source, awaited
    /// inline (the callers are `async`), so a test's `await` sees the report land.
    private func reportClosedAwaiting(source: SourceID, value: String, reason: CloseReason) async {
        guard let reg = registry[source] else { return }   // orphaned card: no one to tell
        await safely(source) { try await reg.source.onClosed(value, reason: reason) }
    }

    /// Report `.revoked` from the synchronous handle path — spawned, since the handle
    /// is fire-and-forget. Tests await the spy's recorded events.
    private func reportClosed(source: SourceID, value: String, reason: CloseReason) {
        guard let reg = registry[source] else { return }
        Task { [weak self] in
            await self?.safely(source) { try await reg.source.onClosed(value, reason: reason) }
        }
    }

    /// Run a source callback inside the containment boundary: a throw is logged and
    /// the source torn down, never propagated into the core (spec §8.3).
    private func safely(_ id: SourceID, _ body: () async throws -> Void) async {
        do { try await body() }
        catch { await faultTeardown(id, error: error) }
    }

    /// A source callback faulted: log it and tear the source down. Same teardown as
    /// an explicit `unregister`, so the core survives anything a source does.
    private func faultTeardown(_ id: SourceID, error: any Error) async {
        Log.registry.error("source '\(id.raw, privacy: .public)' faulted: \(String(describing: error), privacy: .public) — tearing down")
        await unregister(id)
    }

    // MARK: Nested support types

    /// A registered source plus its handle and start task. A class so the start task
    /// can be assigned after creation and identity comparison is cheap.
    private final class Registration {
        let source: any NotificationSource
        let handle: SourceHandle
        var startTask: Task<Void, Never>?
        init(source: any NotificationSource, handle: SourceHandle) {
            self.source = source
            self.handle = handle
        }
    }

    /// One transient card's auto-dismiss timer. Exactly one of the two live fields is
    /// authoritative: `deadline` while running (`scheduled != nil`), `remaining`
    /// while paused (`scheduled == nil`) — the split that lets hover freeze and
    /// resume without losing time. `total` is the immutable full interval, kept so
    /// `countdown(for:)` can report the bar's 100% width independently of how much
    /// has since elapsed.
    private final class TransientTimer {
        var scheduled: Scheduled?
        var remaining: Duration
        var deadline: Date
        let total: Duration
        init(total: Duration, remaining: Duration, deadline: Date) {
            self.total = total
            self.remaining = remaining
            self.deadline = deadline
        }

        /// Time left before the fire, computed live from `deadline` (clamped at 0).
        /// Authoritative only while running; a paused timer reads `remaining` instead.
        func liveRemaining(now: Date) -> Duration {
            .seconds(max(0, deadline.timeIntervalSince(now)))
        }
    }
}
