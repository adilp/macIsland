import AppKit
import SwiftUI
import MacIslandCore

/// Owns the `IslandPanel` and keeps it showing the core's current stack, pinned
/// top-center under the notch and grown downward. The core is the source of truth:
/// on every `IslandCore.onChange` this pushes a fresh `IslandView` snapshot into the
/// hosting view, measures the content, and re-anchors the panel via the pure
/// geometry in `MacIslandCore`. All positioning decisions are the tested
/// `anchorFrame`/`targetScreenIndex`; this controller only applies them.
///
/// Two extra responsibilities for the Calm sheet: it forwards island-hover to
/// `IslandCore.setHovering` (pausing transient timers) and, when the content would
/// exceed ~72% of screen height, it measures the natural height first and then hands
/// the view a bounded scroll region — so the common case stays content-sized and only
/// genuine overflow switches to internal scrolling with fade edges (spec §4).
@MainActor
final class PanelController {
    private let core: IslandCore
    private let panel = IslandPanel()
    private let hostingView: NSHostingView<IslandView>
    /// An offscreen hosting view used **only to measure** the natural (no-scroll)
    /// content height. It always holds the plain layout, so its `fittingSize` is never
    /// destabilized by the displayed view flipping between plain and scroll modes
    /// (measuring on the displayed view returns a stale `0` right after such a flip —
    /// the observation-timing hazard). Never added to a window.
    private let measuringView: NSHostingView<IslandView>
    /// The first render (boot idle pill) snaps into place; later renders animate the
    /// window resize so cards appearing/dismissing don't jump.
    private var hasRendered = false
    /// Mirror of the hover state we last pushed to the core — so a stream of
    /// `onContinuousHover` movement events only does work when it actually flips.
    private var isHovering = false
    /// Brackets each animated panel resize with an `os_signpost` interval, so the
    /// active budget is measurable: frame smoothness across the transition (Instruments
    /// Animation Hitches / `XCTOSSignpostMetric`, perf spec §5.1) and the snap-back
    /// invariant (no interval left open once the animation completes, I‑2).
    private let signposter = TransitionSignposter()

    init(core: IslandCore) {
        self.core = core
        // Placeholder rootViews; `render()` replaces them with the real snapshot.
        let placeholder = IslandView(
            cards: [], countdowns: [:], width: 300, topInset: 0, hasNotch: false,
            isHovering: false, panelMaxHeight: nil, liveSources: [],
            onDismiss: { _ in }, onAction: { _, _ in }, onHoverChange: { _ in }
        )
        hostingView = NSHostingView(rootView: placeholder)
        measuringView = NSHostingView(rootView: placeholder)
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
    /// change, hover change, and display change.
    private func render() {
        guard let (_, metrics) = currentTargetScreen() else { return }

        let width = islandWidth(for: metrics)
        let topInset = notchClearance(for: metrics)
        let countdowns = buildCountdowns()

        // Measure the natural (uncapped, no-scroll) content height on the offscreen
        // view — always plain, so the measurement is deterministic and never the stale
        // `0` a plain/scroll flip on the *displayed* view would yield.
        measuringView.rootView = makeView(
            metrics: metrics, width: width, topInset: topInset,
            countdowns: countdowns, panelMaxHeight: nil
        )
        measuringView.layoutSubtreeIfNeeded()
        let naturalSize = measuringView.fittingSize

        // Beyond the cap, hand the view the panel-height ceiling so it switches its card
        // area to a bounded, internally-scrolling region with fade edges — the panel
        // stops growing and the stack scrolls (the view owns the chrome subtraction).
        // The displayed rootView is set exactly once per render.
        let cap = metrics.frame.height * defaultMaxHeightFraction
        let overflow = naturalSize.height > cap
        hostingView.rootView = makeView(
            metrics: metrics, width: width, topInset: topInset,
            countdowns: countdowns, panelMaxHeight: overflow ? cap : nil
        )

        // `anchorFrame` caps the height at ~72%, so the panel never runs off-screen
        // even though we sized from the natural (uncapped) content.
        let frame = anchorFrame(islandSize: naturalSize, on: metrics)
        if hasRendered {
            // Animate the resize so a card arriving/leaving grows/shrinks the panel
            // in step with the SwiftUI enter/exit transition (spec §5: motion only
            // during transitions, then quiescent). The signpost interval brackets the
            // animation so its smoothness is measurable and the completion proves the
            // snap-back (interval closed ⇒ nothing left animating — I‑2).
            let token = signposter.begin()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                self?.signposter.end(token)
            })
        } else {
            panel.setFrame(frame, display: true)   // boot: snap the idle pill in place
            hasRendered = true
        }
    }

    /// Build the immutable snapshot view for the current stack.
    private func makeView(
        metrics: ScreenMetrics, width: CGFloat, topInset: CGFloat,
        countdowns: [NotificationID: Countdown], panelMaxHeight: CGFloat?
    ) -> IslandView {
        IslandView(
            cards: core.ordered,
            countdowns: countdowns,
            width: width,
            topInset: topInset,
            hasNotch: metrics.hasNotch,
            isHovering: isHovering,
            panelMaxHeight: panelMaxHeight,
            liveSources: core.liveSourceIDs,
            onDismiss: { [weak self] id in
                Task { await self?.core.dismiss(id) }
            },
            onAction: { [weak self] id, index in
                Task { await self?.core.fireAction(id, at: index) }
            },
            onHoverChange: { [weak self] hovering in
                self?.hoverChanged(hovering)
            }
        )
    }

    /// Sample the countdown for every visible transient card, so the view can render
    /// each depleting bar as one CA animation (spec R2). Sticky cards return nil and
    /// are simply absent from the map.
    private func buildCountdowns() -> [NotificationID: Countdown] {
        var map: [NotificationID: Countdown] = [:]
        for card in core.ordered {
            map[card.id] = core.countdown(for: card.id)
        }
        return map
    }

    /// Island-hover changed: pause/resume the core's transient timers and re-render so
    /// the ✕s reveal and the countdown bars pick up their frozen state. Guarded so a
    /// stream of movement events only acts on the actual enter/leave transition.
    private func hoverChanged(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        core.setHovering(hovering)
        render()
    }

    /// Island width: a base pill width, widened to at least the notch width (plus a
    /// small hug margin) so the sheet visually emerges from the notch (spec §4).
    private func islandWidth(for metrics: ScreenMetrics) -> CGFloat {
        let base: CGFloat = 440
        guard let notch = metrics.notchWidth else { return base }
        return max(base, notch + 40)
    }

    /// Top space reserved so card content clears the physical notch band; a small
    /// pad on non-notched displays where the pill floats under the menu bar.
    private func notchClearance(for metrics: ScreenMetrics) -> CGFloat {
        metrics.hasNotch ? metrics.notchHeight + 2 : 6
    }
}
