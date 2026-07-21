import SwiftUI
import MacIslandCore

/// The SwiftUI "island": the idle pill when empty, otherwise the **Calm sheet** — a
/// single downward-growing sheet of notification cards that reads as *one thing that
/// grew* out of the notch (stacking-interaction spec, variant A). This is the full
/// interaction over the walking skeleton's plain list:
///
/// - **One sheet, spring reflow** — new cards enter top-of-tier nearest the notch and
///   the column springs to make room; an in-place update holds its position (§1/§2).
/// - **Two tiers** — sticky above transient, split by a single hairline divider (§6).
/// - **Hover reveals every ✕ at once** and **freezes every transient countdown bar**
///   (the freeze is driven by the core's paused `Countdown`s) (§3/§5).
/// - **Overflow scrolls internally** with top/bottom fade edges past ~72% of screen
///   height, so the island never runs off-screen (§4) — engaged by the controller
///   handing a non-nil `maxCardAreaHeight`.
///
/// The controller pushes an immutable snapshot (`cards`, `countdowns`, sizing,
/// `isHovering`) into a fresh `IslandView` on every change, so sizing is synchronous
/// and the panel resizes deterministically — no observation-timing hazard. Hover is
/// reported back up through `onHoverChange` so the core can pause transient timers.
struct IslandView: View {
    let cards: [PlacedNotification]
    /// Per-transient-card countdown, sampled by the core at snapshot time — drives the
    /// depleting bar (and its hover freeze). Sticky cards are absent from the map.
    let countdowns: [NotificationID: Countdown]
    /// Panel width, ≥ the notch width so the sheet emerges from the notch.
    let width: CGFloat
    /// Vertical space reserved at the top so content clears the physical notch band.
    let topInset: CGFloat
    /// Whether the home display has a notch — the card hugs the screen top when it
    /// does, and floats a hair below (leaving shadow room) when it doesn't.
    let hasNotch: Bool
    /// Whether the pointer is over the island — reveals every ✕ together and (via the
    /// core's paused countdowns) freezes the countdown bars.
    let isHovering: Bool
    /// Non-nil only when the content overflows ~72% of screen height: the panel-height
    /// ceiling. The view derives its own scroll-region height from this by subtracting
    /// the chrome it owns (notch clearance + its margins). `nil` = content-sized, no
    /// scroll (the common case), so the panel stays measurable at its natural height.
    let panelMaxHeight: CGFloat?
    /// The ids of every live (registered) source. A `callback` button on a card whose
    /// source is *not* here is disabled (its source is gone, so it would fire into
    /// nothing); `openURL` buttons stay live regardless — the orphan policy, made
    /// visible (spec §5).
    let liveSources: Set<SourceID>
    /// Dismiss a card by id — wired to `IslandCore.dismiss` (the always-present ✕).
    let onDismiss: (NotificationID) -> Void
    /// Fire the action at `index` on a card — wired to `IslandCore.fireAction`. The
    /// core runs `openURL` itself and routes `callback` to the owning source.
    let onAction: (NotificationID, Int) -> Void
    /// Report island-hover up to the controller → `IslandCore.setHovering`.
    let onHoverChange: (Bool) -> Void

    // Transparent breathing room around the sheet so its drop shadow fades *inside*
    // the window instead of being clipped at the rectangular edge. The panel is sized
    // to the padded content, so these are real.
    private static let sideMargin: CGFloat = 16
    private static let bottomMargin: CGFloat = 20
    private static let floatMargin: CGFloat = 10     // top gap on non-notched displays
    private static let contentBottomPad: CGFloat = 4 // pad below the card area, above the margin

    // Gutter between cards — one consistent gap so the column reads as a single sheet,
    // not stacked toasts (spec §2). The tier divider sits in this same rhythm.
    private static let gutter: CGFloat = 6
    // How far the top/bottom scroll edges fade when the stack overflows (spec §4).
    private static let fadeHeight: CGFloat = 22

    // The ambient (pill) plane, derived from every activity-bearing card across all
    // sources. When collapsed we show this as a compact *peek*; on hover the activities
    // expand into full rows and the peek gives way to the sheet (the two planes).
    private var pill: PillState { derivePillState(from: cards) }

    // The rows the downward sheet renders. Collapsed, activity cards live in the pill
    // (not the sheet), so only non-activity cards (toasts, failure cards) show; on hover
    // everything expands into rows.
    private var visibleCards: [PlacedNotification] {
        isHovering ? cards : cards.filter { $0.notification.activity == nil }
    }

    // Show the compact peek only while collapsed and something is actually running.
    private var showPeek: Bool {
        if isHovering { return false }
        if case .bare = pill { return false }
        return true
    }

    // A stable key over the visible card ids — drives the enter/exit + spring reflow
    // whenever the set changes. Unchanged by an in-place update (same ids), so an
    // update animates its content without re-sorting or re-entering (spec §2).
    private var cardKey: [NotificationID] { visibleCards.map(\.id) }

    // The sticky/transient split. `visibleCards` is already sticky-first (core
    // ordering), so the transient tier is the suffix; the divider goes between them.
    private var firstTransientIndex: Int? {
        visibleCards.firstIndex { $0.tier == .transient }
    }

    var body: some View {
        // Hover is tracked on the visible sheet only (not the transparent shadow
        // margins), so reaching the edge of the shadow doesn't count as leaving.
        sheet
            .onContinuousHover { phase in
                if case .active = phase { onHoverChange(true) } else { onHoverChange(false) }
            }
            .padding(.horizontal, Self.sideMargin)
            .padding(.top, hasNotch ? 0 : Self.floatMargin)
            .padding(.bottom, Self.bottomMargin)
            // The iOS drawer curve (AUDIT §2), shared verbatim with the panel-resize
            // animation in PanelController so window + content move as one coordinated
            // unfold rather than a spring-vs-easeOut mismatch (plan 001).
            .animation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.32), value: cardKey)
    }

    private var sheet: some View {
        Group {
            if visibleCards.isEmpty {
                // Nothing in the downward sheet: either a bare resident pill, or — when a
                // deploy is running — just the compact peek.
                if showPeek { peekOnly } else { idlePill }
            } else {
                content
            }
        }
        .frame(width: width)
        .background(background)
    }

    // The resident idle state: a compact pill hugging the notch. Static — no
    // animation, no timeline — so the app is quiescent at idle (spec §5).
    private var idlePill: some View {
        Color.clear
            .frame(height: max(topInset, 14))
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.35))
                    .frame(width: 46, height: 5)
                    .padding(.bottom, 4)
            }
    }

    // The notch clearance is fixed at the top (continuous with the notch); only the
    // card area below it scrolls when the stack overflows. A running-deploy peek sits
    // between the notch band and the cards when collapsed alongside other cards.
    private var content: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)          // clear the notch band
            if showPeek {
                peekRow.padding(.bottom, Self.gutter)
            }
            if let panelMax = panelMaxHeight {
                scrollingCardArea(maxHeight: scrollRegionHeight(panelMax: panelMax))
            } else {
                cardColumn
            }
        }
        .padding(.bottom, Self.contentBottomPad)
    }

    // The compact peek standing alone (a running deploy with no other cards): the notch
    // band, then the glyph + live clock. Static except the clock, which ticks itself.
    private var peekOnly: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)
            peekRow
        }
        .padding(.bottom, Self.contentBottomPad)
    }

    /// The height the scrollable card region may occupy so the whole panel fits within
    /// `panelMax` (~72% of screen). The view owns all of this chrome, so the subtraction
    /// is exact: the outer top margin (only when floating), the notch clearance, the
    /// content bottom pad, and the outer bottom margin.
    private func scrollRegionHeight(panelMax: CGFloat) -> CGFloat {
        let chrome = (hasNotch ? 0 : Self.floatMargin)
            + topInset
            + Self.contentBottomPad
            + Self.bottomMargin
        return max(0, panelMax - chrome)
    }

    // The card column: sticky tier, a single hairline divider, then the transient
    // tier — one `ForEach` (one container) so a card keeps its identity through the
    // spring reflow. Newest sits nearest the notch within each tier (core ordering).
    private var cardColumn: some View {
        VStack(spacing: Self.gutter) {
            ForEach(Array(visibleCards.enumerated()), id: \.element.id) { index, card in
                // The tier divider goes immediately above the first transient card,
                // but only when sticky cards sit above it (spec §6).
                if index == firstTransientIndex, index > 0 {
                    tierDivider
                }
                CardRow(
                    card: card,
                    countdown: countdowns[card.id],
                    revealDismiss: isHovering,
                    sourceIsLive: liveSources.contains(card.id.source),
                    onDismiss: onDismiss,
                    onAction: onAction
                )
                // An activity card only ever appears via hover-reveal, so it reveals
                // *in place* (opacity + a subtle scale) — the panel's downward growth
                // is the motion, and it doesn't slide while the window grows. A regular
                // card (a toast / completion arrival) still slides from the notch (plan 001).
                .transition(card.notification.activity != nil
                    ? .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                    : .asymmetric(
                        insertion: .push(from: .top).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.9, anchor: .top))
                    ))
            }
        }
        .padding(.horizontal, 4)
    }

    // The overflow posture (spec §4): the card column scrolls inside a fixed height
    // with fade/mask edges signalling more above/below; the island stops growing so
    // it never runs off-screen. The newest card stays at the top of the scroll region.
    private func scrollingCardArea(maxHeight: CGFloat) -> some View {
        ScrollView(.vertical) {
            cardColumn
        }
        .scrollIndicators(.hidden)
        .frame(height: maxHeight)
        .mask(fadeMask)
    }

    private var fadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.fadeHeight)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.fadeHeight)
        }
    }

    private var tierDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.10))
            .frame(height: 1)
            .padding(.horizontal, 14)
    }

    // MARK: - The peek (compact activity in the pill)

    // A single-line, glanceable summary of the running activities: a leading glyph and
    // a trailing live clock (or a count when several run at once). The clock ticks
    // itself via `TimelineView` — no re-posting, so the model stays quiescent.
    @ViewBuilder
    private var peekRow: some View {
        HStack(spacing: 10) {
            switch pill {
            case .bare:
                EmptyView()
            case let .single(glyph, trailing):
                peekGlyph(glyph).foregroundStyle(peekTint ?? .white)
                Spacer(minLength: 8)
                peekTrailing(trailing)
            case let .many(count, noun, trailing):
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(count) \(Self.plural(noun, count))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                peekTrailing(trailing)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func peekGlyph(_ icon: Icon) -> some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 16, weight: .semibold))
        case .image:
            // The peek is symbol-only; a raster activity glyph falls back to a default.
            Image(systemName: "shippingbox.fill").font(.system(size: 16, weight: .semibold))
        }
    }

    @ViewBuilder
    private func peekTrailing(_ trailing: PillTrailing) -> some View {
        switch trailing {
        case .none:
            EmptyView()
        case .text(let s):
            Text(s)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        case .clock(let since):
            ElapsedText(since: since)
        }
    }

    // The tint of the single running activity, if it set one (e.g. the green success
    // flash) — read straight off the card so the peek colour tracks the source.
    private var peekTint: Color? {
        guard let card = cards.first(where: { $0.notification.activity != nil }),
              let hex = card.notification.content.tint else { return nil }
        return Color(hexString: hex)
    }

    private static func plural(_ noun: String?, _ count: Int) -> String {
        let base = noun ?? "activity"
        guard count != 1 else { return base }
        return base == "activity" ? "activities" : base + "s"
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(Color.black.opacity(0.92))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)   // fades inside the margins
    }
}

/// A live, self-ticking `M:SS` elapsed clock counting up from `since`. Uses
/// `TimelineView` so it advances once a second on its own — the model never re-posts
/// to move it, keeping the core quiescent while a deploy runs.
private struct ElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(since)))
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension Color {
    /// Parse a `#RRGGBB` hex string (the `Content.tint` wire form) into a `Color`;
    /// returns nil on anything malformed so the caller falls back to a theme colour.
    init?(hexString: String) {
        var s = hexString
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// One notification card: icon · title/body · the hover-revealed ✕, with a thin
/// depleting countdown bar under transient cards.
private struct CardRow: View {
    let card: PlacedNotification
    /// The transient countdown for this card, or nil for a sticky card (no bar).
    let countdown: Countdown?
    /// Whether the island is hovered — reveals the ✕ (all cards' ✕s appear together).
    let revealDismiss: Bool
    /// Whether this card's source is still registered. A `callback` button is disabled
    /// when it isn't (the orphan policy: it would fire into nothing); `openURL` buttons
    /// ignore this — the core runs them itself, so they survive a dead source (spec §5).
    let sourceIsLive: Bool
    let onDismiss: (NotificationID) -> Void
    /// Fire the action at `index` on this card (0 = primary).
    let onAction: (NotificationID, Int) -> Void

    private var content: Content { card.notification.content }
    /// Up to two, in display order — the domain model caps the array at 2 and the core
    /// rejects any post that exceeds it, so this is structurally ≤ 2 buttons.
    private var actions: [Action] { card.notification.actions }

    /// The icon colour: the card's `tint` (`#RRGGBB`) when it sets one — a green ✓ on a
    /// successful deploy, a red ✗ on a failed one — else the default white.
    private var iconColor: Color { content.tint.flatMap(Color.init(hexString:)) ?? .white }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 13) {
                icon
                    .frame(width: 28, height: 28)
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(content.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let body = content.body {
                        Text(body)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2)
                            .contentTransition(.opacity)   // crossfade "in 5 min" → "starting now"
                    }
                }
                Spacer(minLength: 10)
                dismissButton
            }
            if !actions.isEmpty {
                actionRow
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .leading)))
            }
            if let countdown {
                CountdownBar(countdown: countdown)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        // The T-5→T-1 escalation is an in-place upsert (same id), so the outer
        // cardKey animation doesn't fire — animate the card's own morph here: when the
        // action count changes (0 → Join), the Join button fades/scales in and the
        // countdown bar fades out together, so the card visibly *becomes* a Join card
        // rather than teleporting (plan: meeting escalation morph). Keyed on the action
        // count — a stable value that only flips on escalation, so it never disturbs the
        // countdown bar's own per-sample depletion animation.
        .animation(.easeOut(duration: 0.22), value: actions.count)
        .animation(.easeOut(duration: 0.22), value: content.body)
    }

    // The card's 0…2 action buttons, primary (index 0) first — plus the dismiss ✕,
    // which lives in the header and is never modelled as an `Action`. A `callback`
    // button greys out and stops responding once its source is gone; an `openURL`
    // button never does (spec §5 orphan policy).
    private var actionRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                ActionButton(
                    label: action.label,
                    isPrimary: index == 0,
                    isEnabled: isEnabled(action)
                ) {
                    onAction(card.id, index)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// An `openURL` action is always live (core-run); a `callback` action is live only
    /// while its owning source is registered. This gate is *advisory* — the core
    /// re-checks at fire time, so a callback into a source that vanished between render
    /// and tap is a harmless no-op there (see `IslandCore.liveSourceIDs`).
    private func isEnabled(_ action: Action) -> Bool {
        switch action.behavior {
        case .openURL: return true
        case .callback: return sourceIsLive
        }
    }

    // Large, high-contrast, easy to flick to and hit (spec §3) — but hidden until the
    // pointer is over the island so idle cards stay clean. The slot is always reserved
    // (opacity, not removal) so revealing it never reflows the card.
    private var dismissButton: some View {
        Button {
            onDismiss(card.id)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
        .opacity(revealDismiss ? 1 : 0)
        .allowsHitTesting(revealDismiss)
        .animation(.easeInOut(duration: 0.14), value: revealDismiss)
    }

    @ViewBuilder
    private var icon: some View {
        switch content.icon {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 20))
        case .image(.data(let data)):
            if let ns = NSImage(data: data) {
                Image(nsImage: ns).resizable().scaledToFit()
            } else {
                fallbackIcon                         // fail-soft: bad bytes → default glyph (spec §8.3)
            }
        case .image(.file(let url)):
            if let ns = NSImage(contentsOfFile: url.path) {
                Image(nsImage: ns).resizable().scaledToFit()
            } else {
                fallbackIcon                         // fail-soft: missing file → default glyph
            }
        case .none:
            fallbackIcon
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: "bell.fill").font(.system(size: 18)).opacity(0.8)
    }
}

/// One action button on a card. The primary (first) action reads as filled; a
/// secondary action is a quieter outline. A disabled button — a `callback` whose
/// source is gone — greys out and stops responding, the visible half of the orphan
/// policy (spec §5). Tapping calls back up to `IslandCore.fireAction`.
private struct ActionButton: View {
    let label: String
    let isPrimary: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(background)
                .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)               // `.disabled` already blocks hit testing
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var foreground: Color {
        isPrimary ? .black : .white
    }

    @ViewBuilder
    private var background: some View {
        if isPrimary {
            Capsule(style: .continuous).fill(.white.opacity(0.92))
        } else {
            Capsule(style: .continuous).fill(.white.opacity(0.12))
        }
    }
}

/// A transient card's thin lifetime bar. Renders the core's sampled `Countdown` as
/// **one Core-Animation animation** (unified spec R2): it snaps to the sampled
/// fraction, then depletes linearly to empty over exactly what's left — unless the
/// countdown is paused (island-hover), when it holds frozen. No per-frame timeline,
/// so a displayed transient still snaps back to quiescent (perf budget §I-5).
///
/// The (re)start is gated on *meaningful* transitions — first appearance, a
/// pause/resume, an upsert's new interval, or a refresh that lifts `remaining` — so
/// that an unrelated re-render (a sibling card arriving/leaving re-samples this card's
/// ever-decreasing `remaining`) leaves the in-flight animation untouched instead of
/// re-snapping it mid-depletion.
private struct CountdownBar: View {
    let countdown: Countdown
    @State private var fill: CGFloat = 1        // 1 = full width, 0 = empty
    @State private var lastRemaining = Double.infinity
    @State private var lastTotal = -1.0
    @State private var lastPaused = false

    var body: some View {
        Capsule(style: .continuous)
            .fill(.white.opacity(0.14))
            .frame(height: 2.5)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule(style: .continuous)
                        .fill(.white.opacity(0.8))
                        .frame(width: geo.size.width)
                        .scaleEffect(x: fill, anchor: .leading)
                }
            }
            .onAppear { react(initial: true) }
            .onChange(of: countdown) { react(initial: false) }
    }

    private func react(initial: Bool) {
        let remaining = countdown.remaining.timeInterval
        let total = countdown.total.timeInterval
        // Restart only on a real transition; a plain running re-sample (remaining
        // merely ticked down) must not disturb the animation already in flight.
        let restart = initial
            || countdown.isPaused != lastPaused          // pause / resume
            || total != lastTotal                        // upsert to a new interval
            || remaining > lastRemaining + 0.001         // countdown refreshed/re-armed
        lastRemaining = remaining
        lastTotal = total
        lastPaused = countdown.isPaused
        guard restart else { return }
        apply()
    }

    private func apply() {
        // Snap to the freshly-sampled fraction with no animation on the jump…
        var snap = Transaction()
        snap.disablesAnimations = true
        withTransaction(snap) { fill = countdown.fractionRemaining }
        // …then deplete to empty over the remaining time as one linear animation.
        // Paused (hover) or already empty → hold at the frozen fraction.
        guard !countdown.isPaused, countdown.remaining.timeInterval > 0 else { return }
        withAnimation(.linear(duration: countdown.remaining.timeInterval)) { fill = 0 }
    }
}
