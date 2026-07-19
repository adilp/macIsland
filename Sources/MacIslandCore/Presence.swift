/// Card lifetime — the "how long it lives" axis, orthogonal to alerting.
///
/// The duration lives *inside* the `.transient` case so illegal states
/// (sticky-with-timer, transient-without-duration) simply cannot be represented.
/// Default when unspecified is `.transient` with a core default of ≈5s
/// (see `Notification.defaultTransientDuration`). See the domain-model spec §Presence.
public enum Presence: Equatable, Codable, Sendable {
    /// Auto-dismiss after the given interval.
    case transient(after: Duration)
    /// Persists until the user dismisses or the source revokes.
    case sticky

    /// The stack tier this presence renders in — computed, never stored, so there
    /// is no priority field to inflate. A presence change relocates the card's tier.
    public var tier: Tier {
        switch self {
        case .sticky: return .sticky
        case .transient: return .transient
        }
    }
}

/// The two stack tiers, ordered sticky-above-transient. Split by a hairline
/// divider in the UI; ringing meetings live in `.sticky` as the loudest sticky.
public enum Tier: Int, Comparable, Sendable {
    case sticky = 0
    case transient = 1

    public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
}
