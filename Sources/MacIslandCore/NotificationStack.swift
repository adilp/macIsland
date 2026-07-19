import Foundation

/// A `Notification` paired with its core-owned `receivedAt` stamp — the unit the
/// stack orders and renders. `receivedAt` is stamped once on first receipt and
/// held across updates; it drives intra-tier ordering and is never source-supplied.
public struct PlacedNotification: Equatable, Sendable, Identifiable {
    public var notification: Notification
    public let receivedAt: Date

    public init(notification: Notification, receivedAt: Date) {
        self.notification = notification
        self.receivedAt = receivedAt
    }

    /// Composite identity, forwarded from the notification.
    public var id: NotificationID { notification.id }
    /// The tier this card renders in — computed from its current presence.
    public var tier: Tier { notification.presence.tier }
}

/// The pure stack-ordering logic: the live set of notifications and the derived
/// two-tier render order. No actor, no clock, no timers, no I/O — the caller (the
/// core, a later ticket) supplies each card's `receivedAt`. See the domain-model
/// spec §Behavior contract.
///
/// Order is **derived, not stored**: two tiers (sticky above transient),
/// newest-first (`receivedAt` descending) within each. Updates hold position
/// because a re-post keeps the original `receivedAt`; there is no re-sort on a
/// countdown tick.
public struct NotificationStack: Equatable, Sendable {
    /// Live cards in receipt order; the render order is computed in `ordered`.
    private var entries: [PlacedNotification] = []

    public init() {}

    /// Post a notification: insert it stamped with `receivedAt`, or — if its id is
    /// already live — **update in place**. An update is a *full replace* of
    /// content/actions/presence/alerting that holds the original `receivedAt` (so
    /// the card keeps its stack position) and its slot in the entry list. A
    /// presence change thus relocates the card's tier while keeping its intra-tier
    /// position by `receivedAt`.
    public mutating func post(_ notification: Notification, receivedAt: Date) {
        if let i = entries.firstIndex(where: { $0.id == notification.id }) {
            entries[i] = PlacedNotification(
                notification: notification,
                receivedAt: entries[i].receivedAt  // hold the original stamp
            )
        } else {
            entries.append(PlacedNotification(notification: notification, receivedAt: receivedAt))
        }
    }

    /// Remove a card because its **source revoked** it. Distinct from a user
    /// `dismiss`; both remove by id, but the distinction drives the reported
    /// `CloseReason` (a later ticket). Returns the removed notification, if any.
    @discardableResult
    public mutating func revoke(_ id: NotificationID) -> Notification? {
        remove(id)
    }

    /// Remove a card because the **user dismissed** it. Distinct from a source
    /// `revoke`. Returns the removed notification, if any.
    @discardableResult
    public mutating func dismiss(_ id: NotificationID) -> Notification? {
        remove(id)
    }

    /// The live placement for an id, if present — exposes the held `receivedAt`.
    public func placed(for id: NotificationID) -> PlacedNotification? {
        entries.first { $0.id == id }
    }

    private mutating func remove(_ id: NotificationID) -> Notification? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: i).notification
    }

    /// The render order: sticky tier above transient tier, newest-first within
    /// each. `entries` is kept in receipt order (new cards append; an in-place
    /// update holds its slot), so the entry index is a deterministic tie-break —
    /// among identical `receivedAt` stamps the later-posted card sits nearer the
    /// notch. This is a total order, so it does not rely on `sorted(by:)` being
    /// a stable sort.
    public var ordered: [PlacedNotification] {
        entries.enumerated().sorted { a, b in
            if a.element.tier != b.element.tier {
                return a.element.tier < b.element.tier            // sticky before transient
            }
            if a.element.receivedAt != b.element.receivedAt {
                return a.element.receivedAt > b.element.receivedAt // newer nearest the notch
            }
            return a.offset > b.offset                            // tie: later receipt wins
        }.map(\.element)
    }
}
