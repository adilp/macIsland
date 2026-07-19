import Foundation

/// The two-object contract that unifies **every** way a notification enters the
/// system — the built-in Calendar source, the local JSON ingress, and anything a
/// forker adds — so the core treats them all identically (source-API spec §1).
///
/// `SourceHandle` is what the core hands a source (source → core is *push*);
/// `NotificationSource` is what a source provides (core → source is *method
/// dispatch*). The core is a dumb display + router that cannot tell a socket-backed
/// source from an EventKit-backed one.

// MARK: - SourceHandle (core → source: the push surface)

/// What the core gives a source so it can speak. The object mirror of the ingress
/// wire's `notify`/`revoke` lines (spec §1). **Stamps the source id**: a source
/// supplies only `value`, and every call is re-stamped with *this* source's id, so
/// touching another source's cards is structurally impossible, not a convention
/// (domain-model §Identity, spec §1 "isolation is structural").
///
/// A reference type so a source can retain it and post later (spec §1: "retain
/// handle to post later"); holds the core weakly so a straggling call after the
/// core is gone is a no-op rather than a crash.
@MainActor
public final class SourceHandle {
    private let sourceID: SourceID
    private weak var target: (any SourceHandleTarget)?

    init(sourceID: SourceID, target: any SourceHandleTarget) {
        self.sourceID = sourceID
        self.target = target
    }

    /// Full form. The notification's `id.source` is **overwritten** with this
    /// source's id — a source cannot post under another's namespace.
    public func post(_ notification: Notification) {
        target?.post(notification.stamped(under: sourceID), from: sourceID)
    }

    /// Convenience — the ergonomic floor. `value == nil` → the core assigns a UUID
    /// (fire-and-forget stays trivial; domain-model §Identity).
    public func post(
        _ content: Content,
        value: String? = nil,
        actions: [Action] = [],
        presence: Presence = .transient(after: Notification.defaultTransientDuration),
        alerting: Alerting = .silent
    ) {
        let n = Notification(
            id: NotificationID(source: sourceID, value: value ?? UUID().uuidString),
            content: content,
            actions: actions,
            presence: presence,
            alerting: alerting
        )
        target?.post(n, from: sourceID)
    }

    /// Remove one of **my** cards (idempotent — revoking an unknown value is a no-op).
    public func revoke(_ value: String) {
        target?.revoke(value: value, from: sourceID)
    }

    /// Remove **all** of my cards.
    public func revokeAll() {
        target?.revokeAll(from: sourceID)
    }

    /// Whether one of **my** cards with this `value` is currently live. The core is the
    /// single source of truth here — a source that outlived and re-adopted an earlier
    /// instance's cards (spec §3) still sees them — so an ingress `revoke` can report an
    /// accurate `revoked:true/false` ack (wire §7) without keeping its own shadow copy.
    public func hasCard(_ value: String) -> Bool {
        target?.hasCard(value: value, from: sourceID) ?? false
    }
}

extension Notification {
    /// Re-stamp identity under a new source, holding `value` and all content. Used
    /// by `SourceHandle` so a source can only ever post under its own id — the
    /// structural half of the isolation guarantee (spec §1).
    func stamped(under source: SourceID) -> Notification {
        Notification(
            id: NotificationID(source: source, value: id.value),
            content: content,
            actions: actions,
            presence: presence,
            alerting: alerting
        )
    }
}

/// The core surface a `SourceHandle` forwards to, narrowed to exactly the three
/// push verbs. An internal seam: keeps the handle independent of the core's full
/// API and every call carries the stamped `SourceID`, so the core can enforce
/// ownership without trusting the caller.
@MainActor
protocol SourceHandleTarget: AnyObject {
    func post(_ notification: Notification, from source: SourceID)
    func revoke(value: String, from source: SourceID)
    func revokeAll(from source: SourceID)
    func hasCard(value: String, from source: SourceID) -> Bool
}

// MARK: - NotificationSource (source → core: the conformance surface)

/// What a source provides so the core can drive its lifecycle. Non-`AnyObject` so a
/// trivial `struct` source is allowed; stateful sources are `final class`/`actor`
/// (spec §1). The **floor is `id` + `start`** — every other method defaults to a
/// no-op (§6, the ~5-line hello-world).
///
/// Lifecycle methods are `async throws`: `async` because a source does its own work
/// on its own task (spec §8), and `throws` because the core wraps **every** source
/// callback in try/catch so a faulting source is logged + torn down but never
/// crashes the core (unified spec §8.3, the containment boundary).
public protocol NotificationSource: Sendable {
    /// Source-chosen id, unique among registered sources.
    var id: SourceID { get }
    /// Opt-in: auto-revoke this source's cards when it goes away (spec §5). Default
    /// `false` — the dominant fire-and-forget case leaves cards in place.
    var revokeOnDisconnect: Bool { get }
    /// Called once on register. Retain the handle to post later; a long-lived source
    /// (a socket read loop) may not return until it goes away (spec §5: start
    /// returning/throwing *is* the source going away).
    func start(_ handle: SourceHandle) async throws
    /// The user tapped a `callback` action on one of this source's cards.
    func onAction(_ value: String, _ actionID: String) async throws
    /// One of this source's cards is gone, with the reason it left.
    func onClosed(_ value: String, reason: CloseReason) async throws
    /// Teardown. Called once as the source is unregistered.
    func stop() async throws
}

public extension NotificationSource {
    var revokeOnDisconnect: Bool { false }
    func onAction(_ value: String, _ actionID: String) async throws {}
    func onClosed(_ value: String, reason: CloseReason) async throws {}
    func stop() async throws {}
}

/// Why a card left — reported through the single `onClosed` callback (spec §5).
/// Dismiss (user) and revoke (source) stay the domain model's distinct operations
/// even though both remove the card; the reason is how a source tells them apart.
public enum CloseReason: Equatable, Sendable {
    /// The user tapped an action (an `onAction` for a `callback` precedes this).
    case acted
    /// The user dismissed the card via the always-present ✕.
    case dismissed
    /// A transient card's timer elapsed.
    case expired
    /// The source revoked the card (`handle.revoke`/`revokeAll`) — a self-echo the
    /// initiator may ignore.
    case revoked
}
