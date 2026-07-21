import Foundation

/// A compact, ambient presentation for a card that should live *in the pill* rather
/// than only unroll as a downward card — the island's **activity** layer (the notch
/// analogue of an iOS Live Activity). Any card with a non-nil `activity` is
/// *pill-resident*: it shows compactly beside the notch (glyph + a live clock) and
/// expands into its ordinary stack row on hover. Normally `.sticky` (a running
/// activity persists), but a brief terminal beat — e.g. a success flash — is a
/// deliberate `.transient` activity that shows in the pill and then auto-collapses.
///
/// Deliberately source-agnostic: any source may emit activities, and they all merge
/// into a single pill (see `derivePillState`). The GitHub CI/CD source is the first
/// producer; the Calendar source (or a forker's module) can emit them too for free.
///
/// Orthogonal to `Presence`/`Alerting`/`Action`, exactly like `Content`: it is a
/// *rendering* hint, not a lifetime or sound. Fully serializable (no closures), so a
/// later ticket can carry it over the ingress wire — deferred for now (YAGNI: only
/// the in-process GitHub source needs it).
public struct ActivityStyle: Equatable, Codable, Sendable {
    /// The compact leading glyph shown in the pill.
    public var glyph: Icon
    /// When set, the pill trailing shows a **live elapsed clock** counting up from
    /// this instant. The *view* ticks it (via `TimelineView`); the model never
    /// re-posts to advance it, so a running activity stays quiescent on the core side.
    public var since: Date?
    /// Static trailing text, used only when `since == nil` (e.g. "queued").
    public var trailing: String?
    /// Singular noun for a multi-activity summary ("deploy" → "2 deploys"). When the
    /// live activities disagree on the noun, the summary falls back to a neutral word.
    public var noun: String?

    public init(glyph: Icon, since: Date? = nil, trailing: String? = nil, noun: String? = nil) {
        self.glyph = glyph
        self.since = since
        self.trailing = trailing
        self.noun = noun
    }

    /// This activity's trailing slot in the pill: a live clock if it has a `since`,
    /// else its static text, else nothing.
    var pillTrailing: PillTrailing {
        if let since { return .clock(since: since) }
        if let trailing { return .text(trailing) }
        return .none
    }
}

/// The trailing slot of a pill activity — either static text or a self-ticking clock.
public enum PillTrailing: Equatable, Sendable {
    case none
    case text(String)
    /// A live elapsed clock counting up from `since`. The view ticks it locally via
    /// `TimelineView`; the model never re-posts to advance it.
    case clock(since: Date)
}

/// What the pill should show, derived from the live *activity* set across **all**
/// sources. The pill and the downward stack are two planes; `PillState` describes the
/// ambient (pill) one. Pure value so the view just renders it.
public enum PillState: Equatable, Sendable {
    /// No activities — the bare resident pill.
    case bare
    /// Exactly one activity: its glyph and trailing.
    case single(glyph: Icon, trailing: PillTrailing)
    /// Two or more: a count, an optional shared singular noun (nil when they
    /// disagree), and the clock of the longest-running one.
    case many(count: Int, noun: String?, trailing: PillTrailing)
}

/// Derive the pill presentation from the render order. Considers only cards carrying
/// an `ActivityStyle` — everything else stays in the downward stack — so this is the
/// single source of truth for the ambient layer, shared by every module that emits
/// activities.
///
/// - 0 activities → `.bare`
/// - 1 → `.single` with its glyph and trailing (a live clock when it has a `since`)
/// - ≥2 → `.many(count:)`; `noun` is the activities' shared singular noun (or `nil`
///   when they disagree), and the trailing clock tracks the **longest-running**
///   activity — the *earliest* `since`, since that has the largest elapsed time.
///
/// Pure and non-isolated: a total function of its input, callable from anywhere
/// (the view calls it on the main actor; tests call it directly).
public func derivePillState(from ordered: [PlacedNotification]) -> PillState {
    let styles = ordered.compactMap(\.notification.activity)
    switch styles.count {
    case 0:
        return .bare
    case 1:
        return .single(glyph: styles[0].glyph, trailing: styles[0].pillTrailing)
    default:
        // A single shared noun summarizes cleanly ("2 deploys"); any disagreement
        // (incl. a mix of set/unset) falls back to the neutral word in the view.
        let sharedNoun = Set(styles.map(\.noun)).count == 1 ? styles[0].noun : nil
        // Longest-running = earliest start = the clock that reads highest.
        let earliest = styles.compactMap(\.since).min()
        let trailing: PillTrailing = earliest.map { .clock(since: $0) } ?? .none
        return .many(count: styles.count, noun: sharedNoun, trailing: trailing)
    }
}
