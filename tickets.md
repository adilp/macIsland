# Tickets: Build macIsland v1

Tracer-bullet tickets that build macIsland — a light, dependency-free macOS notch dynamic-island notifier — from
the [Build macIsland v1 spec](.scratch/macisland/issues/spec-build-macisland-v1.md) (which links the locked design
in `.scratch/macisland/assets/`, the source of truth for exact contracts). All tickets are **ready-for-agent** and
agent-grabbable by construction.

Work the **frontier**: any ticket whose blockers are all done. Order below is a valid dependency order (blockers
first). After **Core stack controller + source contract** lands, two tracks open in parallel (panel vs. sound);
after **A card on the notch**, interaction/actions/sources fan out. Work one ticket at a time with `/implement`,
clearing context between tickets.

Dependency shape: `Domain model → Core+contract → {Card on the notch, Alerting}`; `Card on the notch → {Stacking
interaction, Actions}`; `Actions → Ingress`; `{Alerting, Actions} → Calendar`; `{Stacking interaction, Ingress,
Calendar} → Performance harness`.

---

## Domain model & stack-ordering logic

**What to build:** The canonical, serializable `Notification` value and everything computed purely from it — the
shared vocabulary every later ticket imports. The value carries content, up-to-two actions, presence, and alerting
under a composite `(source, value)` identity; the stack order is derived (not stored) as two tiers, sticky above
transient, newest-first within a tier; re-posting an existing id fully replaces it while holding its stamped
`receivedAt` and its position; revoke is an explicit operation distinct from a user dismiss. Illegal states are
unrepresentable (a transient's duration lives inside the case; presence is one field). No UI, no I/O — pure logic
verified by unit tests. Exact type shape and rules: spec §Implementation Decisions and
[the domain model spec](.scratch/macisland/assets/02-notification-domain-model.md).

**Blocked by:** None — can start immediately.

- [x] `Notification` and its `Content`/`Icon`/`Presence`/`Alerting`/`Action`/`SourceID`/`NotificationID` types exist and are `Codable`/serializable (no closures or live objects in the value).
- [x] Tier ordering is computed from `Presence`: sticky tier above transient tier, newest-first within each; a presence change relocates a card's tier but keeps its position by `receivedAt`.
- [x] Update-in-place (re-post same id) is a full replace that preserves the original `receivedAt` and stack position; revoke removes by id and is distinct from dismiss.
- [x] Only `title` is required; `.transient` defaults to ≈5s; `.ringing` defaults to a 120s timeout; icon supports SF-Symbol and raster (`.file`/`.data`), never a remote URL.
- [x] Unit tests cover ordering, update-in-place, revoke, defaults, and illegal-state-proofing.

## Core stack controller + source contract

**What to build:** The headless heart — the `@MainActor` core that owns the live set of notifications and the two
contract objects that unify every source. Sources push through a `SourceHandle` (which stamps the source id, so a
source only ever supplies `value` and structurally cannot touch another's cards); the core drives each registered
`NotificationSource` by method dispatch resolved through a `(source → registry)` lookup. The core applies
post/upsert/revoke, exposes the computed render order, and arms per-card transient auto-dismiss timers through an
**injected `Clock`** with a hover-pause hook. Registration rejects a duplicate live id and re-adopts a vacated one;
teardown is uniform (a stopped source ≡ a dropped connection) and every source callback is wrapped so a faulting
source is logged (`os.Logger`) and torn down but never crashes the core. Verified entirely at the `SourceHandle`
seam with spy sources + a fake clock — no panel. Contract: [the source-API spec](.scratch/macisland/assets/05-notificationsource-api-spec.md).

**Blocked by:** Domain model & stack-ordering logic.

- [x] A spy source can `register`, `post`, `revoke`, and `revokeAll`, and the core exposes the resulting ordered stack; the handle stamps the source id so cross-source addressing is impossible.
- [x] Transient cards auto-dismiss when the injected clock advances past their interval; a hover-pause signal freezes and resumes those timers without wall-clock sleeps in tests.
- [x] `register` rejects a second live source with the same id and re-adopts the id (with its still-visible cards) once the previous instance is torn down.
- [x] Teardown runs uniformly on stop/throw; a source whose callback throws is logged and unregistered without affecting other sources or the core.
- [x] The four `CloseReason`s are emitted through one `onClosed`, and dismiss (user) vs revoke (source) stay distinct — all asserted through spy sources at the seam.

## A card on the notch (walking skeleton)

**What to build:** The first runnable app — make a real card appear at the notch and dismiss. A borderless
non-activating `NSPanel` that floats over everything (including full-screen apps) without stealing focus, pinned
top-center under the notch and growing downward, re-anchored on screen changes, living on the built-in display only
(a floating top-center pill when there's no notch). Notch metrics and the anchor frame are pure functions
(bottom-left-origin, grow-downward, height capped at `min(content, ~72% screen)`). The app is a single-process
`LSUIElement` menu-bar agent (`MenuBarExtra` with Quit) booting in order panel → menu-bar item → registry, single
-instanced via `LSMultipleInstancesProhibited`, unlinking any stale socket path is deferred but clean shutdown
stops sources. A minimal SwiftUI island renders the core's stack as plain cards, each with a working ✕; a built-in
dev source posts a card so the skeleton is demoable. Geometry: [the notch/window spec](.scratch/macisland/assets/01-notch-geometry-and-window.md).

**Blocked by:** Core stack controller + source contract.

- [x] Launching the app shows the idle pill at the notch and a menu-bar item whose only entry (Quit) exits cleanly.
- [x] A card posted by the dev source appears at the notch, sitting visually continuous with the notch, and clicking its ✕ removes it.
- [x] The panel floats above full-screen apps and never steals key/main focus from the frontmost app.
- [x] On a non-notched display the island renders as a floating top-center pill; the island stays on the built-in display and re-anchors on `didChangeScreenParametersNotification`.
- [x] Only one instance can run at a time; pure notch-geometry/anchor functions are unit-tested against notched, non-notched, and external-screen rects.

## Full stacking interaction ("Calm sheet")

**What to build:** Raise the skeleton's plain list to the decided interaction. The idle pill unrolls straight down
out of the notch as one continuous sheet; a new card enters at the top of its tier nearest the notch while the
others spring-reflow to make room, and an in-place update animates without re-sorting or re-entering. Hovering
anywhere over the island reveals every card's large, easy-to-hit ✕ together and pauses every transient timer (its
thin countdown bar freezes), resuming on pointer-leave. The two tiers read as sticky-above-transient split by a
hairline divider, and beyond a max height the column scrolls internally with fade edges (no cap, no "+N more").
Detail: [the stacking-interaction spec](.scratch/macisland/assets/03-stacking-interaction-spec.md).

**Blocked by:** A card on the notch (walking skeleton).

- [x] Posting several cards shows them as one downward-growing sheet; new cards enter top-of-tier with a spring reflow and updates animate in place holding position.
- [x] Hovering the island reveals all ✕s at once and pauses every transient countdown (bars freeze); leaving hover resumes them.
- [x] Sticky cards render above transient cards with a hairline divider; a sticky card stays pinned on top while transient cards arrive and expire below it.
- [x] Beyond ~72% screen height the stack scrolls internally with top/bottom fade edges and the island never runs off-screen; the newest card stays nearest the notch.

## Alerting & the Alerter

**What to build:** Give the island a voice. A core `Alerter` driven purely by a card's `Alerting` level and its
lifecycle (sources never call it): `.silent` makes no sound, `.soundOnce` plays a single system sound on arrival,
`.ringing` loops a system sound until the earliest of {card gone, any action fired, timeout} using the injected
clock. There is a **single global ring channel** — at most one ring plays, owned by the top ringing card — so two
urgent things never overlap into cacophony. System sounds only (Apple, zero bundle weight); the exact files are
swappable. Verified by asserting ring start/stop at a spy-audio seam; audible check once the app runs.

**Blocked by:** Core stack controller + source contract.

- [x] A `.soundOnce` card plays exactly one sound on arrival; a `.silent` card plays nothing.
- [x] A `.ringing` card loops until the earliest of card-removed, action-fired, or the 120s timeout (asserted via the injected clock), and never outlives its card.
- [x] Two simultaneous ringing cards produce exactly one active ring, owned by the top ringing card; when it ends the channel is free.
- [x] Ring start/stop is asserted at a spy-audio seam with no real audio and no wall-clock waits.

## Actions: openURL, callback routing, dismiss-vs-act

**What to build:** Make cards actionable. A card renders up to two action buttons plus the always-present dismiss.
An `openURL` action is run by the core itself (via `NSWorkspace`) end-to-end and keeps working even after its
source is gone; a `callback` action routes `(value, actionID)` to the owning source's `onAction`. Firing an action
dismisses the card by default, or keeps-and-updates it when `dismissOnTap` is false. The orphan policy is enforced
when a source goes away: its cards are left in place, its dead `callback` buttons are disabled, its `openURL`
buttons stay live, and a source that opted into `revokeOnDisconnect` has its cards auto-revoked. Every termination
is reported through `onClosed` with the right `CloseReason`. Routing detail: [the source-API spec](.scratch/macisland/assets/05-notificationsource-api-spec.md).

**Blocked by:** Core stack controller + source contract; A card on the notch (walking skeleton).

- [ ] A card shows up to two buttons; clicking an `openURL` action opens the URL and (by default) dismisses, reporting `onClosed(.acted)`.
- [ ] Clicking a `callback` action calls the owning source's `onAction(value, actionID)`; a `dismissOnTap:false` action keeps the card for an in-place update.
- [ ] After a source is torn down, its cards remain, its `callback` buttons are disabled, and its `openURL` buttons still work; a `revokeOnDisconnect` source's cards auto-revoke.
- [ ] Dismiss, revoke, expire, and act each report the correct `CloseReason` through `onClosed` — asserted at the `SourceHandle` seam.

## Local JSON ingress (wire codec + IngressHost + SocketSource + CLI)

**What to build:** Let any external tool push notifications without writing Swift — the ingress as N conformers to
the same contract. An `IngressHost` binds a user-private (`0700`) Unix domain socket (default path with
`$MACISLAND_SOCK` override), unlinks any stale socket, accepts many simultaneous connections, and mints one
`SocketSource` per connection whose read loop translates JSONL → `handle.post`/`revoke`/`revokeAll` and serializes
`onAction`/`onClosed` back down that connection. The connection is the source's session: an optional `hello` names
a durable source (re-adopted on reconnect) with an optional `revokeOnDisconnect` flag, no `hello` mints an
anonymous per-connection source, and a malformed line earns an `{"error":…}` ack without dropping the connection.
A thin `macisland` CLI wraps the socket (`notify [--source] [--wait [--timeout]]`, `revoke <id>|--all`, `listen`) —
three postures over one mechanism, with the core persisting zero callback state. The host is the last boot step.
Wire schema: [the ingress spec](.scratch/macisland/assets/04-ingress-wire-format-spec.md).

**Blocked by:** Core stack controller + source contract; Actions: openURL, callback routing, dismiss-vs-act.

- [ ] `echo '{"title":"Build done"}' | macisland notify` (and raw JSONL to the socket) posts a card and returns an `ok` ack; `notify` with an existing id upserts in place.
- [ ] A named `hello` gives a durable namespace re-adopted on reconnect; no `hello` gives an isolated anonymous source; a malformed line returns an `error` ack and the connection survives.
- [ ] `--wait` streams that notification's `action`/`closed` lines until it closes or times out; `listen` streams all of the source's events; fire-and-forget receives none after exit; callbacks after disconnect are dropped, not queued.
- [ ] `revoke <id>` is idempotent and `revoke --all` clears only that source's cards; auth is filesystem-perms only (no token, no network); wire codec + `SocketSource` are tested at an in-memory `Connection` seam plus one real-socket smoke test.

## Calendar/meeting source

**What to build:** The first real built-in source and proof the whole stack carries a genuine feature — one
launch-lifetime `NotificationSource` (`id="calendar"`) adapting EventKit to `handle.post` with zero
calendar-specific code in the core. Every timed meeting gets a T‑5 warning (`.transient` + `.soundOnce`, no
actions); a meeting with a video link additionally, at T‑1, upserts the **same** event id into a `.sticky` +
`.ringing(120s)` card with a core-run `openURL` **Join** action labeled for the provider — non-video meetings get
the T‑5 warning only. The ring stops on Join/dismiss/revoke/timeout; the sticky card self-revokes at the event's
end and on calendar edits; dismissing the T‑5 warning cancels the pending ring while letting it expire lets the
ring fire. EventKit access is auto-requested on first launch (min macOS 14), the source is inert when denied, and
it looks ahead 24h. Ports `CalendarService`/`LinkParser`/`MeetingEvent` from the read-only reference. Detail:
[the Calendar source spec](.scratch/macisland/assets/06-calendar-meeting-source-spec.md).

**Blocked by:** Alerting & the Alerter; Actions: openURL, callback routing, dismiss-vs-act.

- [ ] With a fake `EventStore` + injected clock, every timed meeting posts a T‑5 transient+soundOnce card; a video meeting upserts (same event id) into a sticky+ringing Join card at T‑1; a non-video meeting posts only T‑5.
- [ ] The ring stops at the earliest of Join, dismiss, revoke, or 120s; the sticky card self-revokes at `endDate` and on calendar edit.
- [ ] Dismissing the T‑5 warning cancels the pending ring; letting it expire lets the ring fire; the Join action opens the parsed video URL.
- [ ] On first launch EventKit access is requested; when denied the source is inert (posts nothing) and the rest of the app is unaffected; deployment target is macOS 14.

## Performance harness & budget verification

**What to build:** Prove "performant and light" holds across the assembled app and lock it against regressions.
Add the automatable CI checks — idle/steady memory under the phys-footprint ceiling, a no-leak churn check that
fires and dismisses many notifications and confirms memory returns to baseline, and an animation-hitch check across
an expand/collapse transition. Document the manual idle-quiescence procedure (`powermetrics` + Activity Monitor on
a quiet machine expecting 0.0% CPU / ~0 periodic wakeups) with a logged TODO to automate it on a future self-hosted
runner. Confirm the app is quiescent at idle (no display-link/repeating timer; the transient countdown bar is a
single Core-Animation animation, not a per-frame loop) and snaps back to quiescent after every transition. Budget:
[the performance spec](.scratch/macisland/assets/07-performance-and-idle-budget-spec.md).

**Blocked by:** Full stacking interaction ("Calm sheet"); Local JSON ingress (wire codec + IngressHost + SocketSource + CLI); Calendar/meeting source.

- [ ] CI fails on regression for the idle-memory ceiling and the no-leak churn check (memory returns to baseline after fire+dismiss of many notifications).
- [ ] CI checks animation smoothness across a transition (no hitches) via signpost metrics.
- [ ] The manual idle-quiescence procedure is documented and, run once, shows 0.0% CPU and ~0 periodic wakeups at idle; the automation TODO is logged.
- [ ] Verified: no display-link/repeating timer at idle, and CPU returns to the idle floor immediately after each transition (snap-back).
