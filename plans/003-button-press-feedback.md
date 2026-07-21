# 003 — Button press feedback

- **Status**: DONE (executed inline; build green, 165 tests unchanged)
- **Commit**: f51b92b
- **Severity**: HIGH (leverage) / low risk
- **Category**: Feedback
- **Estimated scope**: 1 file (`IslandView.swift`), small

## Problem

The card's buttons — **Open run / Join** (`ActionButton`) and the dismiss **✕**
(`dismissButton`) — used `.buttonStyle(.plain)`, which gives no `:active` state, so a
tap had zero press response.

## Target

A shared `PressableButtonStyle`: the label dips to `scale(0.97)` while held and eases
back on release, `ease-out` @ `0.14s` — subtle and fast, matching the frequency tier.
Under `prefers-reduced-motion`, drop the scale and use a faint opacity dip to `0.85`.

## Steps (as built)

1. Add a file-scope `private struct PressableButtonStyle: ButtonStyle` that reads
   `@Environment(\.accessibilityReduceMotion)` (via an inner `View` so the environment
   resolves) and applies `.scaleEffect(...0.97...)` / opacity + `.animation(.easeOut(
   duration: 0.14), value: configuration.isPressed)`.
2. `dismissButton`: `.buttonStyle(.plain)` → `.buttonStyle(PressableButtonStyle())`.
3. `ActionButton`: `.buttonStyle(.plain)` → `.buttonStyle(PressableButtonStyle())`.

## Boundaries

- Motion only; no change to button layout, labels, or the disabled/orphan styling.
- The `MenuBarExtra` Quit button is left system-styled (out of scope).

## Verification

- **Mechanical**: `swift build` clean; `swift test` green (165).
- **Feel check**: hover a card, press **Open run** / **✕** — the button dips slightly
  and springs back on release; holding shows the dip, releasing eases out. Toggle
  Reduce Motion (System Settings › Accessibility › Display) and confirm the scale is
  replaced by a faint opacity dip.
- This is the first reduced-motion-aware component; the rest of the app's motion still
  needs an app-wide reduced-motion pass (tracked separately).
