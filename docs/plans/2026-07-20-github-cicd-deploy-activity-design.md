# GitHub CI/CD Deploy Activity — Design

**Date:** 2026-07-20
**Status:** Design locked, ready for implementation planning
**Repo watched:** `example-org/example-org` (private)

## Goal

Surface example-org deploys on the island so you don't have to go check on CI.
While a deploy runs, the notch shows a compact, iOS-Live-Activity-style **peek**
(icon + live elapsed clock). On finish it resolves: green-flash on success, a
sticky ringing card on failure. No noise otherwise.

## Decisions (settled)

| Axis | Decision |
|------|----------|
| Peek content | Icon + locally-ticking elapsed time (honest; GitHub gives no real %) |
| Concurrency | One merged pill summary → expands into one card per deploy |
| Coexistence | Two planes: peek owns the pill (ambient), notifications unroll below |
| Transport | `gh auth token` once → native URLSession polling the REST API |
| Scope | All `main` deploys, whoever pushed |
| Success | Pill green-flashes ~2s, then collapses/revokes (optional brief toast) |
| Failure / timed-out | Revoke activity → post sticky `.ringing` card (reuses existing ring) |
| Cancelled / skipped | Quiet revoke, no ring, no red |
| Cadence | ~15s while a run is active; idle backs off 60s → ~5min |
| Push nudge | Local `pre-push` git hook `touch`es a watched file → immediate fast poll |

**Deploy workflows watched:** Deploy API, Deploy Web, Deploy Web (Democrat),
Mobile Native Build, Mobile OTA Update.

## Architecture — two layers

The key insight that keeps new work small: **only an *in-progress* deploy needs the
new surface. Every terminal state hands off to machinery that already exists.**

- **Ambient layer (new): "activities."** A queued/in-progress run lives as an
  *activity* — compact-by-default, occupying the pill (icon + live clock),
  expanding into a card row only on hover. Activities never auto-unroll and never
  make noise. This is the only genuinely new presentation mode.
- **Notification layer (existing): "cards."** On any terminal state the source
  **revokes the activity** and, if it failed, **posts an ordinary sticky ringing
  card** — exactly what `CalendarSource` already does for a meeting Join. Success
  green-flashes and revokes. Cancelled/skipped revokes silently.

Payoff: the failure card, the ring, sticky/transient behavior, ring-ownership
policy, and the `openURL` action are all **reused unchanged**. New surface area is
confined to "render in-progress activities as a compact pill that expands into the
stack."

Coexistence falls out for free: the pill renders a summary of the *activity set*;
the downward stack renders activity rows (on hover) plus real notification cards,
ordered by the existing sticky/transient tiers. A meeting ring and a failed-deploy
ring resolve through the single ring channel already in place.

## Components

1. **`GitHubActionsSource: NotificationSource`** (App-layer / small `MacIslandGitHub`
   module, so `MacIslandCore` stays network-free and Apple-only). Owns the poll
   loop, tracks known runs, translates status changes into `handle.post` /
   `handle.revoke`. Takes injected `Clock` and `GitHubClient`.
2. **`GitHubClient`** (protocol + real impl). Holds the token from `gh auth token`,
   lists recent `main` runs for the five deploy workflow IDs via URLSession,
   returns `[RunSnapshot]` (`{id, workflowName, status, conclusion, attempt,
   startedAt, completedAt, htmlUrl, actor}`). No domain knowledge. Faked in tests.

## Domain additions (Core — the only Core changes)

`Presence` / `Alerting` / `Action` are untouched. Add an optional activity
descriptor to a posted item:

```swift
public struct ActivityStyle: Equatable, Codable, Sendable {
    public var glyph: Icon        // compact leading symbol
    public var since: Date?       // set → trailing shows a live elapsed clock
    public var trailing: String?  // used when since == nil (static)
    public var noun: String?      // e.g. "deploy" — for pluralized pill summaries
}
```

An item with a non-nil `activity` is "pill-resident" — the pill gates purely on
`activity != nil`, independent of presence. This keeps two axes clean: `Presence` =
*lifetime* (a running activity is a sticky card; the success flash is a brief
`.transient` one); `ActivityStyle` = *render me compactly in the pill*. Because it's
an ordinary card underneath, expand-into-stack works with no extra plumbing.

**Pill summary is a Core facility, not GitHub's.** A pure function derives pill
state over *all* activity-bearing items across *every* source:

```swift
// MacIslandCore — source-agnostic
enum PillState { case bare, single(glyph: Icon, trailing: Trailing),
                      many(count: Int, noun: String?, maxSince: Date?) }
func derivePillState(from ordered: [PlacedNotification]) -> PillState
```

Rules: 0 → `bare`; 1 → its glyph + clock/static trailing; ≥2 sharing a `noun` →
`N deploys · <maxElapsed>`; mixed nouns → neutral `N activities`. Any module that
emits activities participates in the same pill for free.

**Wire/JSON-ingress support for activities is deferred** (YAGNI — only the
in-process GitHub source needs it now).

## View layer (`IslandView`)

- Pill renders `derivePillState(from: core.ordered)`. The clock ticks via SwiftUI
  `TimelineView` — **no per-second re-posting.**
- Expanded, each activity is a stack row (sticky tier) with its own clock and an
  "Open run" action.
- Success → brief green tint on the pill before revoke.

## Data flow / state machine

**On `start()`:** run `gh auth token`, cache in `GitHubClient`. On failure (gh
missing / logged out) post one sticky "Deploy watch off · run `gh auth login`" card
and keep the source alive on the slow tick so it self-heals. Then schedule the
first poll via the injected `Clock`.

**Each poll:** list recent `main` runs, keep those whose `workflow_id` is a deploy
ID, reconcile against an in-memory `[runID: (status, attempt)]` map:

- **New** queued/in-progress → `post` sticky card, `ActivityStyle(glyph: 🚀,
  since: startedAt, noun: "deploy")`, value `run-<id>` (namespaced under the
  `github` source id → `github/run-<id>`), action
  `openURL(htmlUrl)`.
- **Still running** → no-op (clock ticks locally; never re-post to advance time).
- **→ success** → green-flash, then `revoke` (optional 2s transient toast).
- **→ failure / timed-out** → `revoke` activity, `post` sticky `.ringing` card
  ("❌ Deploy Web failed", body = branch·short-sha, `openURL` action).
- **→ cancelled / skipped** → `revoke` silently.
- **Vanished from a *successful* 200** → `revoke` quietly (never gets stuck).

**Cold-start guard:** on the first poll after launch, adopt only *currently
in-progress* runs; treat already-completed runs as baseline. Prevents ringing about
failures that finished while the app was off.

## Cadence & push nudge

- **Cadence:** any active run → next poll ~15s; otherwise back off 60s → 2min →
  5min cap, snapping back to 15s the instant a run appears.
- **Rate limit:** non-issue — 5000 req/hr authenticated; even 15s polling is ~240/hr.
- **Push nudge (Option 2):** a **local** `pre-push` git hook in example-org `touch`es
  a watched file the moment *you* push; the source watches it via `DispatchSource`
  and calls `pollNow()` → immediate fast-poll. So your own deploys are caught
  instantly and idle backoff only ever governs *teammates'* deploys (result card a
  few minutes later is fine).
  - **Fully local & safe:** `.git/hooks/` is never tracked/committed/pushed, so it
    can't reach other developers' machines. Hook is a no-op if the socket/file
    target is absent, runs backgrounded with a sub-second timeout, and always exits
    `0` — it can never block or slow a push.
  - **No installer** — `Scripts/macisland-prepush-nudge.sh` is the ~5-line hook; copy
    it into example-org's `.git/hooks/pre-push` once (`cp … .git/hooks/pre-push &&
    chmod +x .git/hooks/pre-push`). A plain file `touch` is instant and local, so the
    hook needs no backgrounding — it no-ops when the island isn't running and always
    exits 0.

## Implementation notes (as built)

- New library target **`MacIslandGitHub`** (+ test target `MacIslandGitHubTests`) so
  the core stays network-free while the source is headless-testable.
- Core additions: `ActivityStyle`, `PillState`/`PillTrailing`, `derivePillState`, and
  an optional `Notification.activity`. The pill summary is source-agnostic Core.
- `GitHubActionsSource` reconcile removes a run from tracking on any terminal state, so
  the cold-start guard and re-run re-adoption both fall out for free (no attempt field).
- The elapsed clock ticks in the view via `TimelineView`; the model never re-posts.
- 20 new tests (8 pill-state + 12 source); full suite green at 165.

## Error handling & edge cases

- **Auth failure:** one info card, source stays alive, retries on slow tick. A `401`
  mid-run re-fetches the token once (may have rotated); still `401` → info card +
  back off. Never spam.
- **Network failure (the important rule):** a failed request is a **silent no-op** —
  skip, keep all state, retry next tick. **Completion is only ever inferred from a
  200 that shows a terminal `conclusion`.** A dropped request must never be read as
  "finished" (no fake completions, no cleared pill on a Wi-Fi blip).
- **Re-runs:** GitHub reuses the id and flips `completed → in_progress` with a bumped
  attempt. Reconcile keys on `(id, status, attempt)` → activity re-adopts. Free.
- **Sleep/wake:** timers don't fire asleep, so poll immediately on
  `NSWorkspace.didWake`. Freshness window: a failure with `completed_at` within
  ~10min rings; older completions resolve silently (revoke + non-ringing sticky
  card).
- **`stop()`:** cancel timers, `revokeAll` to clear the pill.

## Testing

Reuses existing seams: injectable `Clock` (`TestClock`), injectable `AudioOutput`
(`SpyAudio`), the `SourceHandle`/`NotificationSource` boundary. One new seam: a
**`GitHubClient` protocol** with a fake returning a *scripted* `[RunSnapshot]`
sequence per poll. Everything headless — no network, timers, or SwiftUI.

**Core tests (`MacIslandCoreTests`) — pill summary is source-agnostic:**
`derivePillState` — 0/1/≥2, max-elapsed, mixed-noun fallback, and **activities from
two different sources merge into one pill**.

**GitHubActionsSource tests (fake client + TestClock + SpyAudio):**

1. New in-progress → sticky activity card, correct value + `openURL`.
2. Two polls in-progress → **no re-post, `receivedAt` unchanged** (clock ticks
   locally).
3. Success → activity revoked, **no ring**.
4. Failure → activity revoked, sticky card, **`startRinging` called once**.
5. Cancelled/skipped → silent revoke, no card, no ring.
6. **Cold-start guard:** first poll shows completed failure → no ring.
7. **Network-failure safety:** poll throws → activity **still present**; next 200
   resolves it.
8. Vanished on a successful 200 → quiet revoke (distinct from #7).
9. Re-run (same id, attempt 2) → activity re-adopted.
10. Cadence: active → ~15s; idle → backoff ramp; new run snaps back to 15s.
11. Wake freshness: stale completed failure → silent; recent → ring.

**Push nudge:** both the file-watch and the timer call one `pollNow()` entrypoint;
tests exercise `pollNow()` directly, the file-watch shim is verified manually.

## Forward-compat: module status (for the upcoming Modules feature)

`GitHubActionsSource` exposes a small status/auth descriptor from day one
(`ok` / `needs-gh-login` / `error`) so the future **Modules** settings panel has
something to render immediately, and the "auth off" card becomes a proper status row.

## Out of scope / follow-ups

- **Modules settings surface** (menu-bar dropdown listing Calendar, GitHub, and
  third-party modules with status/auth + on-off toggles) — its own design doc next.
  Introduces a `Module` layer over `NotificationSource`, persistence, and a
  third-party module contract.
- Activity support over the JSON-ingress wire (deferred until a non-Swift producer
  needs it).
- Non-`main` / per-branch deploy watching.
