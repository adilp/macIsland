# 002 — Meeting T-5→T-1 escalation morph

- **Status**: DONE (executed inline; build green, 165 tests unchanged)
- **Commit**: 6545e1f
- **Severity**: MEDIUM
- **Category**: State indication / preventing a jarring change
- **Estimated scope**: 1 file (`IslandView.swift`), small

## Problem

A meeting fires a T-5 warning card (transient, countdown bar, no Join), then one
minute out **upserts the same card** (same id) into the T-1 Join card (sticky,
ringing, Join button). Because it's an in-place upsert, `cardKey` is unchanged, so
the outer animation never fires — the Join button and the "starting now" text
**teleport in** and the countdown bar vanishes instantly. This is the exact moment
the user needs to register "join now", and it pops.

## Target

The card visibly *becomes* a Join card: the Join button fades + scales in from
`scale(0.97, anchor: .leading)`, the countdown bar fades out, and the body text
crossfades ("in 5 minutes" → "starting now") — all on `ease-out` @ `0.22s`, keyed on
the action count so it fires only on escalation (never disturbing the countdown
bar's own per-sample depletion).

## Steps (as built)

1. `actionRow` → `.transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .leading)))`.
2. `CountdownBar` → `.transition(.opacity)`.
3. Body `Text` → `.contentTransition(.opacity)`.
4. Card body `VStack` → `.animation(.easeOut(duration: 0.22), value: actions.count)` and
   `.animation(.easeOut(duration: 0.22), value: content.body)`.

## Boundaries

- Motion only — no changes to `CalendarSource`, the upsert logic, or card layout.

## Verification

- **Mechanical**: `swift build` clean; `swift test` green (165, no view coverage).
- **Feel check** (hard to trigger on demand — needs a real video meeting reaching
  T-1, or a `CalendarSource` test double): confirm the Join button eases in and the
  countdown bar fades out together, and the body text crossfades — no pop.
- **Note**: app-wide `prefers-reduced-motion` handling is still absent (a separate
  accessibility pass); the 0.97 scale here is gentle enough to be acceptable interim.
