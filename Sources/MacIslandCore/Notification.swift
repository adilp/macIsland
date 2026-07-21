/// The canonical value every source emits and the rendering stack consumes — the
/// root abstraction the rest of macIsland is expressed in terms of.
///
/// Orthogonal shape: **Content × Actions × Presence × Alerting + identity.** Fully
/// serializable — **no closures, no live objects** — so the same value maps onto
/// the ingress wire format (ticket 04) and the Swift source API (ticket 05).
///
/// `receivedAt` is deliberately *not* here: it is core-owned state stamped once on
/// first receipt and held across updates (see `PlacedNotification` /
/// `NotificationStack`), never a source-supplied field. See the domain-model spec.
public struct Notification: Equatable, Codable, Sendable, Identifiable {
    /// Stable, source-owned composite identity `(source, value)`.
    public let id: NotificationID
    /// The visible content.
    public var content: Content
    /// 0…2 explicit actions, display order; first is primary. The cap is a
    /// post-time invariant the core enforces (unified spec §8.3), not a structural
    /// one — the small notch card sizes it.
    public var actions: [Action]
    /// Card lifetime.
    public var presence: Presence
    /// Sound level.
    public var alerting: Alerting
    /// Optional ambient (in-pill) presentation. When non-nil the card is
    /// *pill-resident* — it shows compactly beside the notch and expands into its
    /// stack row on hover (usually `.sticky` while running; a success flash is a brief
    /// `.transient` one). `nil` (the default) → an ordinary downward card. See
    /// `ActivityStyle` / `derivePillState`.
    public var activity: ActivityStyle?

    /// Core default transient lifetime when a source doesn't specify one (≈5s):
    /// most notifications are ephemeral; sticky is the deliberate opt-in.
    public static let defaultTransientDuration: Duration = .seconds(5)

    public init(
        id: NotificationID,
        content: Content,
        actions: [Action] = [],
        presence: Presence = .transient(after: Notification.defaultTransientDuration),
        alerting: Alerting = .silent,
        activity: ActivityStyle? = nil
    ) {
        self.id = id
        self.content = content
        self.actions = actions
        self.presence = presence
        self.alerting = alerting
        self.activity = activity
    }
}
