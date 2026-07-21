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
    /// How much this activity deserves the pill when several run at once — the notch
    /// analogue of an iOS Live Activity's `relevanceScore`. The highest-relevance
    /// activity *leads* the pill (its glyph + clock); the rest collapse to a minimal
    /// "+N". Ties break by render order (nearest the notch wins). Default `0`, so a
    /// source opts into priority only when it has a reason to (e.g. a meeting about to
    /// start outranking a background build).
    public var relevance: Double

    public init(glyph: Icon, since: Date? = nil, trailing: String? = nil, relevance: Double = 0) {
        self.glyph = glyph
        self.since = since
        self.trailing = trailing
        self.relevance = relevance
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
///
/// This mirrors the Dynamic Island's multi-activity model: never cram — one activity
/// *leads*, the rest collapse to a minimal "+N", and hovering expands everything into
/// the stack (our downward stack is the "expanded" presentation, so we have no cram
/// problem there). `tint` is the leading activity's `Content.tint` (`#RRGGBB`), passed
/// through as a string so Core stays free of any rendering type.
public enum PillState: Equatable, Sendable {
    /// No activities — the bare resident pill.
    case bare
    /// Exactly one activity leads the pill: its glyph, tint, and trailing.
    case single(glyph: Icon, tint: String?, trailing: PillTrailing)
    /// The most-relevant activity leads (glyph + tint + its own trailing); `extra`
    /// more run concurrently, shown as a minimal "+N" indicator.
    case leadingPlusMinimal(glyph: Icon, tint: String?, trailing: PillTrailing, extra: Int)
}

/// Derive the pill presentation from the render order. Considers only cards carrying
/// an `ActivityStyle` — everything else stays in the downward stack — so this is the
/// single source of truth for the ambient layer, shared by every module that emits
/// activities.
///
/// - 0 activities → `.bare`
/// - 1 → `.single` (its glyph, tint, and trailing — a live clock when it has a `since`)
/// - ≥2 → `.leadingPlusMinimal`: the **highest-`relevance`** activity leads (ties
///   broken by render order, so the one nearest the notch wins), and the remaining
///   `count − 1` collapse to a minimal "+N". The leader shows *its own* clock, which
///   sidesteps mixing a count-up (elapsed) and a future count-down (time-to-start)
///   into one impossible shared clock.
///
/// Pure and non-isolated: a total function of its input, callable from anywhere
/// (the view calls it on the main actor; tests call it directly).
public func derivePillState(from ordered: [PlacedNotification]) -> PillState {
    let activities = ordered.filter { $0.notification.activity != nil }
    guard !activities.isEmpty else { return .bare }

    // Leader = the top relevance; among equals, the first in render order (nearest
    // the notch). Relevance defaults are exactly 0.0 and sources set discrete values,
    // so the `==` tie test does no float arithmetic.
    let topRelevance = activities.map { $0.notification.activity!.relevance }.max()!
    let leader = activities.first { $0.notification.activity!.relevance == topRelevance }!

    let style = leader.notification.activity!
    let tint = leader.notification.content.tint
    let extra = activities.count - 1
    return extra == 0
        ? .single(glyph: style.glyph, tint: tint, trailing: style.pillTrailing)
        : .leadingPlusMinimal(glyph: style.glyph, tint: tint, trailing: style.pillTrailing, extra: extra)
}
