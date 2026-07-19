/// Sound level — the "how loud" axis, orthogonal to presence. The core owns the
/// actual sounds (one consistent sonic identity); a source picks only the level.
/// See the domain-model spec §Alerting and the unified spec §8.1 (the `Alerter`).
public enum Alerting: Equatable, Codable, Sendable {
    /// No sound.
    case silent
    /// One sound on arrival.
    case soundOnce
    /// Loop a sound until the earliest of {card removed, any action fired,
    /// `timeout`}. A ring never outlives its card, so the timeout only bites for
    /// sticky cards. Swift enum cases can't carry a default associated value, so
    /// use `Alerting.ringing()` for the spec's default 120s.
    case ringing(timeout: Duration)

    /// The core default ring timeout (reuses the reference's 2-minute ring).
    public static let defaultRingTimeout: Duration = .seconds(120)

    /// `.ringing` with the default 120s timeout — the value a source that asks to
    /// ring "without a timeout" receives.
    public static func ringing() -> Alerting {
        .ringing(timeout: defaultRingTimeout)
    }
}
