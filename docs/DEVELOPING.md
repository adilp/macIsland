# Developing & extending macIsland

How the code is laid out, how to build and test it, and — the main event — how to
**add your own source** so the notch shows whatever you want.

If you only want to *push* a notification from an existing tool, you don't need Swift
at all — jump to [External sources (JSON ingress)](#external-sources-json-ingress).

## Build, test, run

Requires **macOS 14+ (Sonoma)**. Apple frameworks only — zero third-party runtime
dependencies.

```sh
swift build                    # build everything
swift test                     # the headless suite (no display, no network, no audio)
swift run MacIslandApp         # launch the menu-bar agent (notch panel + sources)
```

The app is an `LSUIElement` agent: no Dock icon, a menu-bar ✨ with the **Modules** list
and **Quit**, and a resident pill at the notch. It's single-instance — a second launch
exits immediately.

**Calendar access needs a real app bundle.** `swift run` launches a bare binary with no
`Info.plist`, so macOS TCC suppresses the EventKit permission prompt — the "Connect
Calendar…" module button silently no-ops. To exercise Calendar, build a bundle and launch
it:

```sh
scripts/package-app.sh           # → .build/macIsland.app (Info.plist + usage string, ad-hoc signed)
open .build/macIsland.app        # launch it; now the Calendar prompt appears
```

Everything else — GitHub CI/CD, the JSON ingress, the pill — works fine straight from
`swift run`.

## Architecture at a glance

Four Swift-package targets, one core idea:

| Target | What it is |
| --- | --- |
| **`MacIslandCore`** | The dependency-free, headless-testable heart: the domain model, the stack/ordering, the source contract, the `Alerter`, notch geometry, and the local JSON ingress (wire codec, `SocketSource`, `IngressHost`). **Apple frameworks only; no network — sources fetch their own.** |
| **`MacIslandGitHub`** | The built-in GitHub CI/CD source (a library, so Core stays network-free and the source stays headless-testable). A good real-world example to copy. |
| **`MacIslandApp`** | The SwiftUI/AppKit GUI: the notch-pinned `NSPanel`, the island views, and the boot sequence that registers sources. |
| **`MacIslandCLI`** | The `macisland` command — thin sugar over the ingress socket. |

**The one abstraction:** everything that puts something on the island is a
`NotificationSource`. The core is a *dumb display + router* — it cannot tell a
socket-backed source from an EventKit-backed one. Add a feature = add a source.

## The domain model

Every source emits `Notification`s — an orthogonal value, fully serializable (no
closures, no live objects):

| Axis | Type | Values |
| --- | --- | --- |
| **Content** | `Content` | `title` (required), `body?`, `icon?` (`.symbol("sf.name")` / `.image`), `tint?` (`"#RRGGBB"`) |
| **Presence** (lifetime) | `Presence` | `.transient(after: Duration)` (auto-dismiss, default ≈5s) / `.sticky` |
| **Alerting** (sound) | `Alerting` | `.silent` / `.soundOnce` / `.ringing(timeout:)` — the core owns all sounds |
| **Actions** (0…2) | `[Action]` | `label`, `behavior` (`.openURL(URL)` / `.callback(String)`), `dismissOnTap` |
| **Activity** (optional peek) | `ActivityStyle?` | a compact in-pill presentation — see [Pill activities](#pill-activities) |
| **Identity** | `NotificationID` | `(source, value)` — you supply `value`; the core stamps `source` |

Two axes are computed, never stored: the **tier** (sticky-above-transient) from
`Presence`, and the **pill state** from the activity set. Illegal states can't be
represented (a sticky card can't carry a countdown; a transient can't lack a duration).

## In-process sources (Swift)

Conform to `NotificationSource`. The **floor is `id` + `start`** — every other method
defaults to a no-op.

```swift
import MacIslandCore

struct WeatherSource: NotificationSource {
    let id = SourceID(raw: "weather")

    func start(_ handle: SourceHandle) async throws {
        // `start` runs off the main actor; the handle is @MainActor, so hop on to post.
        await MainActor.run {
            handle.post(
                Content(title: "Rain in 20 min", icon: .symbol("cloud.rain.fill")),
                value: "rain",
                presence: .transient(after: .seconds(10))
            )
        }
    }
}
```

Register it in the boot sequence (`Sources/MacIslandApp/MacIslandApp.swift`,
`applicationDidFinishLaunching`):

```swift
core.register(WeatherSource())
```

That's the whole hello-world. `Sources/MacIslandApp/DevSource.swift` is a slightly
richer built-in example (sticky + transient cards, two action kinds).

### The handle (source → core)

`SourceHandle` is what the core hands you in `start`. It **stamps your source id** on
every call, so touching another source's cards is structurally impossible.

```swift
handle.post(_ content: Content, value: String? = nil,      // value nil → core assigns a UUID
            actions: [Action] = [], presence: Presence = .transient(after: …),
            alerting: Alerting = .silent, activity: ActivityStyle? = nil)
handle.post(_ notification: Notification)                  // full form
handle.revoke(_ value: String)                             // remove one of *my* cards
handle.revokeAll()                                         // remove all of them
handle.hasCard(_ value: String) -> Bool                    // is it still live?
```

- **Upsert by id:** posting the same `value` again updates the card in place (holds its
  position; no re-sort, no re-arrival). This is how you show live-updating state.
- Retain the handle to post later (a read loop, a timer, a callback). Hold it weakly if
  your source outlives a single `start`.

### Stateful sources & lifecycle

A trivial source is a `struct`. A stateful one (timers, network, a poll loop) is a
`@MainActor final class` — see **`GitHubActionsSource`** as the canonical example:
injected `Clock` + client, a poll loop scheduled on the clock, upsert-by-id, and a
`status` for a future settings panel.

Core → source callbacks (all `async throws`; the core wraps each so a fault tears the
source down but never crashes the app):

```swift
func onAction(_ value: String, _ actionID: String) async throws   // a .callback button was tapped
func onClosed(_ value: String, reason: CloseReason) async throws  // .acted / .dismissed / .expired / .revoked
func stop() async throws                                          // teardown
var revokeOnDisconnect: Bool { get }                             // opt-in: auto-revoke my cards when I go away
```

## Actions

Two behaviors only — the core is a router, never an executor:

- **`.openURL(url)`** — the core opens it via `NSWorkspace`. Runs end-to-end and keeps
  working even after your source is gone. No round-trip.
- **`.callback(actionID)`** — the core routes `(value, actionID)` to your
  `onAction`. Do the work there (and optionally `handle.post` an update).

`dismissOnTap` (default `true`) controls whether firing removes the card. Set it
`false` for "keep the card and update it" flows, or for a persistent card you want to
survive taps (only the ✕ then dismisses it).

## Pill activities

An activity is the notch analogue of an iOS **Live Activity** — a compact "peek" in the
pill (glyph + a live clock) that expands into its full card on hover. Post a `.sticky`
card with an `activity`:

```swift
handle.post(
    Content(title: "Deploy Web", body: "main · a1b2c3d", icon: .symbol("shippingbox.fill")),
    value: "run-123",
    actions: [Action(label: "Open run", behavior: .openURL(runURL), dismissOnTap: false)],
    presence: .sticky,
    alerting: .silent,
    activity: ActivityStyle(
        glyph: .symbol("shippingbox.fill"),
        since: startedAt,        // trailing shows a live count-up clock (view ticks it — no re-posting)
        relevance: 0             // Apple-style relevanceScore: who leads the pill when several run
    )
)
```

The pill is **source-agnostic**: `derivePillState(from: core.ordered)` merges every
activity across all sources. Concurrency follows Apple's model — the highest-`relevance`
activity **leads** (ties break by render order, nearest-notch), and the rest collapse to
a minimal **"+N"**. Hovering expands them all into the stack, so there's no cram problem.
Emit an activity and you get all of this for free.

## Modules — user-facing integrations

A **module** is the user-facing wrapper over a source: the thing that shows up in the
menu-bar dropdown with a name, an icon, a status light, and an on/off switch that
remembers itself across launches. A `NotificationSource` stays a pure, dumb transport —
`Module` is an *additive* layer over it (Core: `Module.swift`, `ModuleRegistry.swift`).

A `Module` is a **value you construct**, not a protocol you conform to. It's not
"metadata + a live source" but "metadata + a **recipe**": `activate()` rebuilds a *fresh*
source every time you switch the module on, because a stateful source (timers, a poll
loop) can't be resumed after `stop()`. Switching off unregisters the source **and sweeps
its cards** (off means gone).

### The trivial form (zero screen code)

The common case is ~5 lines. You get a menu row, a status light, and a persisted toggle
for free:

```swift
registry.add(Module(id: SourceID(raw: "weather"), displayName: "Weather",
                    icon: .symbol("cloud.rain"), makeSource: { WeatherSource() }))
```

### The rich form (health + actions)

Bind health and any labeled buttons to the concrete instance — the source's own type is
in scope inside the closure, so `status` can read whatever it exposes:

```swift
registry.add(Module(id: SourceID(raw: "calendar"), displayName: "Calendar",
                    icon: .symbol("calendar")) {
    let src = CalendarSource(store: EventKitStore(), clock: clock)
    return ActiveModule(
        source: src,
        status: { src.authorizationStatus == .authorized ? .ok : .needsAttention("Not connected") },
        actions: [ModuleAction("Connect Calendar…") { _ = await src.requestAccess() }]
    )
})
```

- **`status`** returns a `ModuleStatus` — `.ok` (🟢) or `.needsAttention("reason")` (🟡).
  It's *pulled* when the menu opens, so keep it cheap (read a cached property, don't do IO).
- **`actions`** are labeled buttons (a name + async work), rendered in the row. Use them for
  simple affordances like "Connect…" or "Sign out" — not for a config form.

### Registering & toggling

Built-ins are registered in the boot sequence (`MacIslandApp.swift`) —
`registry.add(Module(…))` then `registry.start()`. **Adding a module is adding a line.**
The registry persists which modules are *disabled* (so new ones default on), and toggling
drives `IslandCore.register` / `unregister(revokingCards: true)`.

### Opt-in settings panel

If a module needs real configuration (not just buttons), it opts into a settings panel that
opens in the standard Settings window: add an entry to `ModuleSettingsPanels.byID`
(`MacIslandApp/ModuleSettings.swift`) keyed by the module's id. The row then shows a
"Settings…" button. This is opt-in — most modules never need it.

### What's *not* a module

External JSON-ingress producers (the socket path below) are **not** modules — they're
ephemeral, per-connection, and not configurable. They appear read-only in the dropdown's
"Connected" strip, but you can't toggle them.

## External sources (JSON ingress)

Any tool in any language can push a notification over a Unix-domain socket — no Swift.
The `macisland` CLI wraps it:

```sh
# fire-and-forget toast
echo '{"title":"Build done","body":"in 2m","icon":"hammer.fill"}' | macisland notify

# a sticky, ringing card with an Open action, under a named source
echo '{"title":"Deploy failed","presence":"sticky","alerting":"ringing",
       "actions":[{"label":"View","url":"https://ci/42"}]}' | macisland notify --source ci

macisland revoke pr-42 --source ci      # or: macisland revoke --all --source ci
macisland listen --source ci            # stream this source's action/closed events
```

Under the hood it's newline-delimited JSON (JSONL), both directions, over
`$MACISLAND_SOCK` (default `~/Library/Application Support/macIsland/ingress.sock`). A
tool can speak it directly:

```jsonl
{"hello":{"source":"ci","revokeOnDisconnect":false}}                       // optional: name a durable source
{"op":"notify","title":"…","body":"…","icon":"hammer.fill","id":"build-42","presence":"sticky","alerting":"ringing","actions":[{"label":"View","url":"https://…"}]}
{"op":"revoke","id":"build-42"}                                            // or {"op":"revoke","all":true}
```

Fields: `title` (required), `body`, `icon` (SF Symbol name), `id` (the card's `value`;
omit → the core assigns one), `presence` (`"sticky"` | seconds | omit → ≈5s transient),
`alerting` (`"silent"` | `"once"` | `"ringing"` | omit → silent), `actions`
(`[{label, url}]` — wire actions are `openURL`). The core replies with acks
(`{"ok":true,"id":"…"}`) and, on the same connection, events
(`{"event":"action","id":"…","action":"…"}`, `{"event":"closed","id":"…","reason":"…"}`).
See `Sources/MacIslandCore/IngressWire.swift` for the codec.

Isolation is structural: a named source owns only its own cards; anonymous connections
are per-connection. A duplicate live id is rejected, never silently hijacked.

## Testing

The core is verified **headlessly** at the `SourceHandle` / `NotificationSource` seam —
no display, no real time, no real audio. Three seams are injected:

| Seam | Protocol | Production | Test double |
| --- | --- | --- | --- |
| Time | `Clock` | `SystemClock` | `TestClock` (hand-advanced) |
| Sound | `AudioOutput` | `SystemAudioOutput` | `SpyAudio` (records calls) |
| GitHub | `GitHubClient` | `GitHubDeployClient` | `FakeGitHubClient` (scripted) |

Pattern: build an `IslandCore` with a `TestClock` (+ a spy `Alerter`), `register` your
source, drive it, and assert on `core.ordered` and the spies. Advance virtual time with
`await clock.advance(by:)` — nothing sleeps. See `Tests/MacIslandGitHubTests/` for a
full state-machine suite and `Tests/MacIslandCoreTests/Doubles.swift` for the doubles.

New in-process sources should take an injected `Clock` (and any other IO seam) so they
can be tested the same way. GUI (`MacIslandApp`) is verified by build + run, not the
headless suite.

## Performance invariants (non-negotiable)

"Light and performant" is CI-gated, not a vibe (see `PERFORMANCE.md`): an idle-memory
ceiling, a no-leak churn check, and a **quiescent-at-idle** invariant. Practically:

- **One-shot timers only** — no repeating timers or polling loops while idle. A single
  pending one-shot is fine; a backoff that re-arms is fine. A source that polls should
  back off hard when there's nothing happening (the GitHub source ramps 60s → 5min).
- **No per-frame work at idle** — the clock ticks in the view via `TimelineView`, and
  the model never re-posts just to advance a clock.
- Don't animate the resident idle pill.

## UI layer (brief)

`Sources/MacIslandApp/IslandView.swift` renders the pill (`derivePillState`) and the
downward card sheet; `PanelController.swift` measures the SwiftUI content and animates
the notch panel to fit. Motion conventions live inline (the iOS drawer curve
`cubic-bezier(0.32, 0.72, 0, 1)` at 0.32s is shared between the panel resize and the
content). Animation work is tracked in [`plans/`](../plans/).

## Where to look next

- **Design docs:** the plans under [`docs/plans/`](plans/) — the GitHub CI/CD source and
  the modules system each have a design write-up.
- **Performance budget & gates:** `PERFORMANCE.md`.
- **Coding style:** match the surrounding code — dense doc-comments that explain *why*,
  `@MainActor` sources, injected seams, and Core staying dependency-free and
  network-free.
