# 001 — Unify the pill→card hover-expand motion

- **Status**: DONE (executed inline; build green, 165 tests unchanged)
- **Commit**: 73fa498
- **Severity**: HIGH
- **Category**: Easing & duration; Physicality & origin
- **Estimated scope**: 2 files (`PanelController.swift`, `IslandView.swift`), small

## Problem

Hovering a running-deploy pill to expand it into a card feels jarring. Three
motions fire at once on mismatched systems/curves:

1. The AppKit window resize and the SwiftUI content animate on **different curves**
   — one a weak ease-out, the other a spring that overshoots — so the window edge
   and the content don't track during the grow.

```swift
// Sources/MacIslandApp/PanelController.swift:111-114 — current
NSAnimationContext.runAnimationGroup({ ctx in
    ctx.duration = 0.32
    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
    panel.animator().setFrame(frame, display: true)
}, ...)
```

```swift
// Sources/MacIslandApp/IslandView.swift:109 — current
.animation(.spring(response: 0.34, dampingFraction: 0.82), value: cardKey)
```

2. The hover-revealed activity card plays a **slide-from-top** while the panel is
   *also* growing downward — double motion, reads as a jump not an unfold.

```swift
// Sources/MacIslandApp/IslandView.swift:199-202 — current
.transition(.asymmetric(
    insertion: .push(from: .top).combined(with: .opacity),
    removal: .opacity.combined(with: .scale(scale: 0.9, anchor: .top))
))
```

## Target

Both the window resize and the SwiftUI content animate on **one shared curve** —
the iOS drawer curve `cubic-bezier(0.32, 0.72, 0, 1)` at `0.32s` (AUDIT.md §2,
`--ease-drawer`) — so the window and content move as one. The hover-revealed
activity card reveals **in place** (opacity + a subtle `scale(0.97)`) so the
panel's downward growth *is* the motion; genuine arrivals (toasts, completion
cards) keep their slide-from-top.

```swift
// PanelController.swift — target
ctx.duration = 0.32
ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
```

```swift
// IslandView.swift — target
.animation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.32), value: cardKey)
```

```swift
// IslandView.swift cardColumn — target: scope the transition per card
// activity card (only ever appears via hover-reveal) → in-place reveal
// regular card (toast / completion arrival) → slide from the notch
.transition(card.notification.activity != nil
    ? .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
    : .asymmetric(
        insertion: .push(from: .top).combined(with: .opacity),
        removal: .opacity.combined(with: .scale(scale: 0.9, anchor: .top))))
```

## Repo conventions to follow

- Spring/curve values are inline literals at their use site (no motion-token file
  yet); keep them inline. The panel-resize animation lives entirely in
  `PanelController.render()`; the content animation is the single `.animation`
  modifier on `IslandView.body`.
- Exemplar of a deliberate curve already in the repo: the countdown bar's
  `withAnimation(.linear(...))` in `IslandView.swift` (`CountdownBar.apply`).

## Steps

1. `PanelController.swift`: replace `CAMediaTimingFunction(name: .easeOut)` with
   `CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)`; leave `ctx.duration =
   0.32`.
2. `IslandView.swift`: replace the `body` `.animation(.spring(response: 0.34,
   dampingFraction: 0.82), value: cardKey)` with `.animation(.timingCurve(0.32,
   0.72, 0, 1, duration: 0.32), value: cardKey)`.
3. `IslandView.swift` `cardColumn`: make the `CardRow` `.transition(...)`
   conditional on `card.notification.activity != nil` per the Target block.

## Boundaries

- Motion properties only — do NOT change layout, sizing, the two-plane peek logic,
  or any source outside these two files.
- Do NOT add dependencies or a token file.
- If the code at these lines has drifted from the excerpts above, STOP and report.

## Verification

- **Mechanical**: `swift build` succeeds; `swift test` stays green (these are
  view-only changes, no test coverage — the suite must simply not regress).
- **Feel check** (run `.build/debug/MacIslandApp` with a deploy in flight):
  - Hover the running pill — it should **unfold** into the card as one smooth
    downward growth; the window edge and the card bottom move together (no lag,
    no overshoot-then-settle mismatch).
  - The card should **not** slide down independently while the panel grows.
  - Hover out — it collapses back to the pill on the same curve.
  - Skim the pointer on/off quickly a few times — no stutter or restart-from-zero.
- **Done when**: the expand reads as a single coordinated unfold, not a
  slide-plus-resize.
