import SwiftUI
import MacIslandCore

/// The SwiftUI "island": the idle pill when empty, otherwise a downward sheet of
/// notification cards. This is the walking-skeleton rendering — plain cards, each
/// with a working ✕ (unified spec §3). The richer "Calm sheet" interaction
/// (spring reflow, hover-reveal, internal scroll, countdown bars) is the next
/// ticket; here the ✕ is always visible so a card can be dismissed.
///
/// The controller pushes an immutable snapshot (`cards`, `width`, `topInset`) into a
/// fresh `IslandView` on every change, so sizing is synchronous and the panel resizes
/// deterministically — no observation-timing hazard.
struct IslandView: View {
    let cards: [PlacedNotification]
    /// Panel width, ≥ the notch width so the sheet emerges from the notch.
    let width: CGFloat
    /// Vertical space reserved at the top so content clears the physical notch band.
    let topInset: CGFloat
    /// Dismiss a card by id — wired to `IslandCore.dismiss` (the always-present ✕).
    let onDismiss: (NotificationID) -> Void

    var body: some View {
        Group {
            if cards.isEmpty {
                idlePill
            } else {
                sheet
            }
        }
        .frame(width: width)
        .background(background)
    }

    // The resident idle state: a compact pill hugging the notch. Static — no
    // animation, no timeline — so the app is quiescent at idle (spec §5).
    private var idlePill: some View {
        Color.clear
            .frame(height: max(topInset, 10))
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.35))
                    .frame(width: 34, height: 4)
                    .padding(.bottom, 3)
            }
    }

    // A plain top-to-bottom list of cards in the core's render order (newest nearest
    // the notch). The two-tier sticky/transient split, hairline divider, spring
    // reflow, and internal scroll are the next ticket ("Full stacking interaction").
    private var sheet: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)          // clear the notch band
            ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                if i > 0 { rowDivider }
                CardRow(card: card, onDismiss: onDismiss)
            }
        }
        .padding(.bottom, 6)
    }

    private var rowDivider: some View {
        Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.horizontal, 12)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.black.opacity(0.92))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }
}

/// One notification card: icon · title/body · the always-present ✕.
private struct CardRow: View {
    let card: PlacedNotification
    let onDismiss: (NotificationID) -> Void

    private var content: Content { card.notification.content }

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 22, height: 22)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text(content.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let body = content.body {
                    Text(body)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button {
                onDismiss(card.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var icon: some View {
        switch content.icon {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 16))
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
        Image(systemName: "bell.fill").font(.system(size: 14)).opacity(0.8)
    }
}
