# macIsland — performance & idle-cost budget

macIsland's product promise is that it is **performant and light**. This document
turns that promise into checks: what is gated automatically in CI, the manual
pre-release step CI cannot do reliably, and how each guiding invariant is verified.

## The one-line contract

> **At rest, macIsland does nothing** — 0.0% CPU, no periodic wakeups, ≤100 MB. It
> costs CPU only in brief, refresh-locked bursts while a transition animates, and
> returns to *nothing* the instant the animation ends.

Everything below is that sentence, made measurable.

---

## Automated CI gates (now)

Gated by [`.github/workflows/ci.yml`](.github/workflows/ci.yml) — a regression **fails
the build**. All of these run headless (no window server, no `sudo`, no wall-clock
sleeps) at the `IslandCore` / `SourceHandle` seam with a hand-advanced `TestClock`, so
they are deterministic and reliable on shared runners.

| Budget | Check | Where |
|---|---|---|
| **Idle memory ≤ 100 MB (app process)** | Launch `MacIslandApp`, settle, assert phys footprint under the hard ceiling (spec §1.3, §5.1 "Launch, settle, assert…") | [`Scripts/idle-memory-check.sh`](Scripts/idle-memory-check.sh) → CI `performance-budget` job |
| **Idle memory (core target)** | Settled core-host phys footprint under the ceiling — guards the core against a gross regression | `PerformanceBudgetTests.test_idleFootprint_underCeiling` |
| **No-leak churn** | Fire + dismiss 2,000–5,000 notifications; the stack empties, **no** timer stays armed, and phys footprint does not grow monotonically | `PerformanceBudgetTests.test_churn_*` |
| **Quiescent at idle (I‑1)** | With nothing displayed, **zero** timers armed; the `Clock` seam offers only one-shots, so a repeating timer is structurally impossible | `PerformanceBudgetTests.test_idle_isQuiescent_noArmedTimers`, `…_transients_armExactlyOneOneShotEach…` |
| **Snap-back (I‑2)** | After **every** transition — expire, dismiss, act — the armed-timer count returns straight to the idle floor of `0` | `PerformanceBudgetTests.test_snapBack_*` |
| **Transition instrumentation** | Each animated panel transition opens exactly one `os_signpost` interval and closes it (nothing left running once it ends) | `TransitionSignposterTests` |

Phys footprint is read two ways, both the same number Activity Monitor's "Memory"
column reports: in-process via mach `task_info(TASK_VM_INFO).phys_footprint`
([`MemoryFootprint`](Sources/MacIslandCore/MemoryFootprint.swift), for the headless
core checks), and out-of-process via `vmmap --summary` (the app-process script).

**Two layers, deliberately.** The headless `test_idleFootprint_underCeiling` runs in the
test host, which bears none of the shipped SwiftUI-on-AppKit framework baseline — so on
its own it only proves *the core target adds near-zero and does not leak as
notifications come and go*. The authoritative ≤100 MB reading against the **real
resident app** is [`Scripts/idle-memory-check.sh`](Scripts/idle-memory-check.sh), gated
in CI (needs the runner's window server) and re-run in the manual pre-release step
below. Together: the core check catches core regressions fast and headlessly; the app
check catches a real product-footprint regression.

---

## Manual idle-quiescence check (pre-release)

The idle **0.0% CPU / ~0 periodic wakeups** budget is *not* reliably measurable on
shared CI runners: the reliable tool (`powermetrics`) needs **root/sudo**, and shared
runners are **noisy** (spec §5.2). Run this on a **quiet machine** (close other apps)
before each release.

1. Build & launch the release app; leave it **idle** — no notifications posted, pointer
   away from the notch — for ~60 s.
2. **Activity Monitor** → the `MacIslandApp` process:
   - **% CPU** reads **0.0**
   - **Idle Wake Ups** ~ **0**
   - **Memory** ≤ **100 MB**
3. `sudo powermetrics --samplers tasks -n 1` (or a short window) → macIsland shows
   **~0 wakeups/s**.
4. *Optional deep check:* **Instruments → Time Profiler** over the idle window shows
   **no samples** attributable to our code.
5. **Pass** = a flat 0.0% CPU line, no periodic wakeups, stable memory — the process is
   asleep.

The **memory** portion of step 2 is scriptable without sudo:
`Scripts/idle-memory-check.sh` launches the app, settles, and asserts phys footprint
under the ceiling (it's the same check CI runs). The **CPU / wakeups** portion still
needs `powermetrics` + a quiet machine, so the whole procedure stays manual.

### Run-once results (fill in before release)

_Not yet run in an automated context — record a real measurement here on a quiet
machine as part of the release checklist._

| Field | Target | Measured | Date / machine |
|---|---|---|---|
| % CPU at idle (60 s) | 0.0 | _TBD_ | _TBD_ |
| Idle Wake Ups | ~0 | _TBD_ | _TBD_ |
| `powermetrics` wakeups/s | ~0 | _TBD_ | _TBD_ |
| Memory (phys footprint) | ≤ 100 MB | _TBD_ | _TBD_ |

---

## Active budget — animation smoothness

Active = the sub-second windows a transition animates (expand / collapse, card enter +
spring reflow, dismiss). The sole active target is **display-native, no dropped frames**
(60 fps floor / 120 ProMotion — spec §2.1). There is **no** peak-CPU ceiling; the
property that matters is the snap-back (I‑2), gated headlessly above.

Each panel transition is bracketed by an `os_signpost` interval
(`TransitionSignposter`, subsystem `com.macisland.core`, category `animation`, name
`PanelTransition`) so the smoothness window is measurable two ways:

- **Instruments (now).** Open **Instruments → Animation Hitches** (or **Core Animation
  FPS**), record a launch, post + dismiss a card to drive an expand/collapse, and scope
  to the `PanelTransition` interval. Pass = the refresh rate holds through the interval
  with no hitches.
- **`XCTOSSignpostMetric` (deferred — see below).** The ready UI test lives at
  [`PerformanceUITests/AnimationHitchUITests.swift`](PerformanceUITests/AnimationHitchUITests.swift).

---

## Guiding invariants — how each is verified

The posture rules from spec §3. They are **strong guidance, not review gates** — CI
gates the *outcomes* (memory, no-leak, snap-back), which is what the table's right
column points to.

| Invariant | Verified by |
|---|---|
| **I‑1** No display-link / repeating timer at idle | `Clock` exposes only one-shot `schedule(after:)`; no `TimelineView`/`CADisplayLink`/repeating `Timer` anywhere in `Sources/`; `PerformanceBudgetTests.test_idle_isQuiescent_noArmedTimers` |
| **I‑2** Return-to-quiescent after every transition (snap-back) | `PerformanceBudgetTests.test_snapBack_*`; `TransitionSignposter` interval closes on completion |
| **I‑3** No timer-driven geometry, no polling | Re-anchor only on `didChangeScreenParametersNotification` (`PanelController`) |
| **I‑4** Timers one-shot & event-anchored | `Clock.schedule(after:)` is one-shot only; the Calendar source arms at most one T‑5/T‑1 fire (`CalendarEngine`) |
| **I‑5** Static idle content | The idle pill is inert — no timeline/animation (`IslandView.idlePill`); the countdown **bar** is one CA animation, not a per-frame loop (spec R2) |
| **I‑6** Single process | Menu bar + panel + registry + ingress in one `LSUIElement` agent (`MacIslandApp`) |
| **I‑7** Every background activity OS-event-driven | Screen-parameters notification, `EKEventStoreChanged`, socket readable/acceptable, one-shot timer fires — never a poll loop |

---

## Deferred automation (TODO)

Two budgets cannot be gated on shared CI runners and stay documented until a
**dedicated, quiet, self-hosted macOS runner** exists (spec §5.3). These are deliberate,
logged gaps — not silent omissions.

- [ ] **Idle quiescence** (0.0% CPU + ~0 wakeups) — needs `sudo powermetrics` and a
  noise-free machine. Until then it is the manual pre-release step above.
- [ ] **Frame-level animation hitches** across an expand/collapse — needs the XCTest
  **UI-testing** bundle + a **window server**, which SwiftPM cannot host. Adopting an
  Xcode UI-test target hosted by `MacIslandApp` promotes
  `PerformanceUITests/AnimationHitchUITests.swift` into a gating job in `ci.yml`.

**TODO:** once that runner exists, promote both into gating CI jobs.
