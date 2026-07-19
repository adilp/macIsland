import Foundation

/// An explicit action button on a card. A card renders 0…2 of these (display
/// order; first is primary), *plus* the always-implicit dismiss affordance, which
/// is never modelled here. The source owns behavior; the core is display + router,
/// never an executor. See the domain-model spec §Actions.
public struct Action: Equatable, Codable, Sendable {
    public let label: String
    public let behavior: ActionBehavior
    /// `true` → firing dismisses the card (the default); `false` → the card stays
    /// and is updated in place (e.g. "Snooze"), via a full-replace re-post.
    public var dismissOnTap: Bool

    public init(label: String, behavior: ActionBehavior, dismissOnTap: Bool = true) {
        self.label = label
        self.behavior = behavior
        self.dismissOnTap = dismissOnTap
    }
}

/// What an action does. Two behaviors only — no shell-exec. A `String` id (not a
/// closure) so the value serializes over the ingress; the ergonomic
/// closure-per-action is a source-API convenience layered on top (ticket 05).
public enum ActionBehavior: Equatable, Codable, Sendable {
    /// The one verb the core runs itself, via `NSWorkspace` — end-to-end, needs no
    /// round-trip, and keeps working even after the owning source is gone.
    case openURL(URL)
    /// Carries an `actionID`; tapping it emits `(notificationID, actionID)` to the
    /// owning source's `onAction`.
    case callback(String)
}
