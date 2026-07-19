import Foundation

/// The core sound layer — a `@MainActor` policy object driven **purely by a card's
/// `Alerting` level and its lifecycle** (unified spec §8.1). Sources never call it:
/// the model forbids source-owned sounds, so the core invokes the `Alerter` from the
/// stack lifecycle (post/upsert/revoke/dismiss/expire/act) and it decides what to
/// play. It owns the **single global ring channel** — at most one ring, owned by the
/// top ringing card — and drives the ring timeout through the injected `Clock`.
///
/// Sound *identity* (which system file) lives below it in `AudioOutput`; the `Alerter`
/// only decides *when* to play once, start ringing, and stop.
@MainActor
public final class Alerter {
    private let audio: any AudioOutput
    private let clock: Clock

    /// Card ids present as of the last reconcile — lets `.soundOnce` fire exactly once
    /// on the absent→present transition (arrival), never again on an in-place update.
    private var present: Set<NotificationID> = []

    /// The single global ring channel. `ringOwner` is the card whose ring is playing
    /// (`nil` = channel free / silent); at most one ever plays. `ringTimeout` is its
    /// one-shot 120s cutoff, armed on the injected clock. `terminated` is the set of
    /// ringing cards whose ring has already ended via timeout-or-action *while the card
    /// is still present* — they must not restart; pruned when the card leaves so a
    /// fresh re-post can ring again. `lastOrdered` lets a timeout/action reassign the
    /// channel to the next eligible ringing card without a fresh reconcile.
    private var ringOwner: NotificationID?
    private var ringTimeout: Scheduled?
    private var terminated: Set<NotificationID> = []
    private var lastOrdered: [PlacedNotification] = []

    public init(audio: any AudioOutput, clock: Clock) {
        self.audio = audio
        self.clock = clock
    }

    // MARK: - Lifecycle hooks (called by the core, never by sources)

    /// Reconcile the sound layer against the current render order after any stack
    /// mutation (post/upsert/revoke/dismiss/expire/act). Idempotent: `.soundOnce`
    /// fires only for cards that just arrived, and the ring only re-evaluates its owner
    /// — nothing replays on an unrelated change.
    func reconcile(_ ordered: [PlacedNotification]) {
        let ids = Set(ordered.map(\.id))
        // Arrival chimes: a `.soundOnce` card plays once when it first appears.
        for card in ordered
        where card.notification.alerting == .soundOnce && !present.contains(card.id) {
            audio.playOnce()
        }
        present = ids
        terminated.formIntersection(ids)   // a card that left may ring afresh if it returns
        lastOrdered = ordered
        updateRing(ordered)
    }

    /// A user fired an action on a ringing card — a ring-ending trigger (the model's
    /// "any action fired"). The card itself may stay (a `dismissOnTap:false` action),
    /// so the ring is silenced explicitly and reassigned to the next ringing card.
    func actionFired(on id: NotificationID) {
        guard lastOrdered.contains(where: { $0.id == id && Self.isRinging($0) }) else { return }
        terminated.insert(id)                       // this card's ring is done
        if ringOwner == id { freeChannel() }        // stop it now; reassign below
        updateRing(lastOrdered)
    }

    // MARK: - The single ring channel

    /// Bring the ring channel in line with `ordered`: the **top** (nearest-notch)
    /// ringing card that hasn't already had its ring terminated owns the channel. A
    /// change of owner keeps the one continuous ring (no stop/restart flap) — the same
    /// sound, one sonic identity — and re-arms the timeout for the new owner. No
    /// eligible ringing card frees the channel.
    private func updateRing(_ ordered: [PlacedNotification]) {
        let top = ordered.first { Self.isRinging($0) && !terminated.contains($0.id) }
        guard let top else { freeChannel(); return }

        if ringOwner == top.id { return }           // already ringing for the right owner
        if ringOwner == nil { audio.startRinging() } // else the channel is already live — just hand it over
        ringOwner = top.id
        armRingTimeout(for: top)
    }

    /// Arm (or re-arm) the owning card's ring cutoff on the injected clock. A stale
    /// prior timeout is cancelled first, so only the current owner's fire is live.
    private func armRingTimeout(for card: PlacedNotification) {
        ringTimeout?.cancel()
        ringTimeout = nil
        guard case .ringing(let timeout) = card.notification.alerting else { return }
        let id = card.id
        ringTimeout = clock.schedule(after: timeout) { [weak self] in
            self?.ringTimedOut(id)
        }
    }

    /// The owning card's 120s cutoff elapsed: end its ring (it doesn't restart) and
    /// hand the channel to the next eligible ringing card, if any.
    private func ringTimedOut(_ id: NotificationID) {
        guard ringOwner == id else { return }       // superseded — a newer owner took over
        terminated.insert(id)
        freeChannel()
        updateRing(lastOrdered)
    }

    /// Stop the active ring and free the channel (idempotent when already silent).
    private func freeChannel() {
        guard ringOwner != nil else { return }
        audio.stopRinging()
        ringOwner = nil
        ringTimeout?.cancel()
        ringTimeout = nil
    }

    private static func isRinging(_ card: PlacedNotification) -> Bool {
        if case .ringing = card.notification.alerting { return true }
        return false
    }
}
