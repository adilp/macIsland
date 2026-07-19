import AppKit
import SwiftUI
import MacIslandCore

/// Owns the `IslandPanel` and keeps it showing the core's current stack, pinned
/// top-center under the notch and grown downward. The core is the source of truth:
/// on every `IslandCore.onChange` this pushes a fresh `IslandView` snapshot into the
/// hosting view, measures the content, and re-anchors the panel via the pure
/// geometry in `MacIslandCore`. All positioning decisions are the tested
/// `anchorFrame`/`targetScreenIndex`; this controller only applies them.
@MainActor
final class PanelController {
    private let core: IslandCore
    private let panel = IslandPanel()
    private let hostingView: NSHostingView<IslandView>

    init(core: IslandCore) {
        self.core = core
        // A placeholder rootView; `render()` replaces it with the real snapshot.
        hostingView = NSHostingView(rootView: IslandView(
            cards: [], width: 300, topInset: 0, onDismiss: { _ in }
        ))
        panel.contentView = hostingView

        // The single core→panel render signal (the stack → panel data-flow edge).
        core.onChange = { [weak self] in self?.render() }

        // Re-anchor on any display change: resolution, connect/disconnect, arrangement
        // (spec §3). The sole persistent background work — event-driven, ~0% idle CPU.
        // The controller is app-lifetime (retained by the delegate until the process
        // exits), so the `[weak self]` observer needs no explicit teardown.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }

        render()                                  // show the idle pill immediately (boot step 1)
        panel.orderFrontRegardless()              // visible without activating the app
    }

    /// Push the current stack into the island, size the panel to the content, and
    /// re-anchor it under the notch on the built-in display. Called on every stack
    /// change and every display change.
    private func render() {
        guard let (_, metrics) = currentTargetScreen() else { return }

        let width = islandWidth(for: metrics)
        let topInset = notchClearance(for: metrics)

        // Replace the rootView with the fresh snapshot, then force layout so the
        // measured size reflects it synchronously (no observation-timing hazard).
        hostingView.rootView = IslandView(
            cards: core.ordered,
            width: width,
            topInset: topInset,
            onDismiss: { [weak self] id in
                Task { await self?.core.dismiss(id) }
            }
        )
        hostingView.layoutSubtreeIfNeeded()

        let size = CGSize(width: width, height: hostingView.fittingSize.height)
        panel.setFrame(anchorFrame(islandSize: size, on: metrics), display: true)
    }

    /// Island width: a base pill width, widened to at least the notch width (plus a
    /// small hug margin) so the sheet visually emerges from the notch (spec §4).
    private func islandWidth(for metrics: ScreenMetrics) -> CGFloat {
        let base: CGFloat = 320
        guard let notch = metrics.notchWidth else { return base }
        return max(base, notch + 24)
    }

    /// Top space reserved so card content clears the physical notch band; a small
    /// pad on non-notched displays where the pill floats under the menu bar.
    private func notchClearance(for metrics: ScreenMetrics) -> CGFloat {
        metrics.hasNotch ? metrics.notchHeight + 2 : 6
    }
}
