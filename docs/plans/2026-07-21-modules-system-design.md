# Modules & Settings — Design

**Date:** 2026-07-21
**Status:** Design locked (grilled), ready for implementation planning
**Builds on:** the GitHub CI/CD source (`GitHubActionsSource.Status`) and the Calendar
source (`CalendarSource.authorizationStatus` / `requestAccess()`), which already hint at
per-integration health/auth.

## Goal

Give macIsland a first-class **Module** layer *over* the (still-dumb) `NotificationSource`,
plus a menu-bar settings surface to manage it. Today every integration is registered by
hand in the boot sequence (`core.register(…)`); there is no user-facing notion of a
"module" — no way to see what's connected, its health/auth, or to turn it off.

**North star:** it should be trivial to build a module. Hand the engine a few lines and you
get a menu row, a status light, and an on/off switch that remembers itself — *no screen
code*. Anything richer (a real settings panel) is **opt-in**, and the system is built so
opting in is easy. The generalizable pieces live in `MacIslandCore` so other modules build
on top of them; `NotificationSource` stays a pure transport, untouched.

## Decisions (settled)

| Axis | Decision |
|------|----------|
| **Module shape** | A concrete **value** in Core (a `struct`), *not* a protocol — it *wraps* a source, it doesn't demand a parallel conformance. |
| **Two layers** | Core `Module` (metadata + factory + health + actions, headless-testable) + an **opt-in** App-side SwiftUI settings panel keyed by id. |
| **Common case** | Engine-only description ⇒ row + status light + toggle + buttons **for free**. Zero SwiftUI for a simple module. |
| **Source contract** | `NotificationSource` stays **unchanged and dumb**. The Module composes over it. |
| **Manager home** | A `ModuleRegistry` in **Core** (tested). Owns registration + persistence, drives `IslandCore`. |
| **Persistence** | Injected `ModuleStore` seam (real = `UserDefaults`, test = in-memory). Persist the **disabled** set; everything defaults **on**. |
| **Toggle: off** | Unregister the source **and sweep its cards immediately** (off means gone — no orphaned sticky pill). |
| **Toggle: on** | Build a **fresh** source via the factory and register (stateful sources can't be resumed after `stop()`). No special per-module hook. |
| **Status** | 3 display states — 🟢 `.ok` / 🟡 `.needsAttention(reason)` / ⚪ off. **Pull**: read when the menu opens (+ after an action). No background polling ⇒ quiescent-at-idle holds. |
| **UI shell** | `MenuBarExtra` dropdown = the list + a read-only "Connected" strip. Rich opt-in panels open in a standard **Settings window** (⌘,). v1 wires the panel hook but ships no built-in panel. |
| **External JSON ingress** | **Not** toggleable modules. Shown read-only in the "Connected" strip (refreshed on menu-open). |
| **Third-party contract** | **Compile-time**: build a `Module`, add it to the list, rebuild. Documented in `DEVELOPING.md`. No runtime plug-in system (YAGNI; Apple-only). |

## Architecture — two layers

The engine (`MacIslandCore`) is verified headlessly, with no display. So the split is
forced, and it's a feature: **a module is a bit of testable data in the engine, plus its
optional screen bits over in the App.**

- **Engine layer (`MacIslandCore`, tested):** `Module`, `ModuleStatus`, `ModuleAction`,
  `ModuleStore`, and the `ModuleRegistry` manager. Pure logic — toggling, persistence,
  card-sweeping, status roll-up — all drivable with a `TestClock` and an in-memory store,
  exactly like the existing `Clock`/`AudioOutput` seams.
- **Screen layer (`MacIslandApp`, build+run):** the `MenuBarExtra` list, the read-only
  "Connected" strip, and the opt-in per-module settings panels (SwiftUI, in a `Settings`
  scene). Verified by build + run, not the headless suite.

The Module layer is **additive**: `IslandCore.register`/`unregister` stay exactly as they
are for non-module sources (the ingress host still mints `SocketSource`s directly). Modules
are a layer that *uses* those verbs; they don't replace them.

## Core additions (the only Core surface changes)

### `ModuleStatus` — the shared health vocabulary

The two real sources report health in incompatible private types (`CalendarAuthorization`;
`GitHubActionsSource.Status`). One Core enum unifies what the panel renders. It carries
only what a health *light* needs — the module vends the actionable affordance separately
(see `ModuleAction`), so the enum stays about state, not behavior.

```swift
/// A module's health as the settings panel renders it. Deliberately tiny: the light is
/// green, or yellow-with-a-reason. "Disabled" is not here — that's the registry's toggle
/// state, not something a live module reports.
public enum ModuleStatus: Equatable, Sendable {
    case ok
    case needsAttention(String)   // reason, e.g. "Not signed in", "Can't reach GitHub"
}
```

Each source maps its native status onto this in its own module definition, so
`CalendarAuthorization` / `GitHubActionsSource.Status` never leak into Core.

### `Module` — the description an author hands the engine

The crux of the "protocol vs wrapper" call: `Module` is a **value you construct**, not a
protocol you conform to. It composes over an opaque `NotificationSource`.

The subtle requirement it must satisfy: **status and actions need the *currently-live*
source instance**, but the source is rebuilt fresh on every enable. So a `Module` isn't
"metadata + a live source" — it's "metadata + a recipe that, each time it's switched on,
produces a fresh source *bundled with the closures bound to that instance*." That bundle is
`ActiveModule`. This is what lets `status` read the concrete source's own state with no
downcasting and no stale capture.

```swift
/// A live, switched-on module: the fresh source plus health/actions bound to *that*
/// instance. Produced by `Module.activate()` on each enable; dropped on disable.
@MainActor
public struct ActiveModule {
    public let source: any NotificationSource
    public let status: () -> ModuleStatus       // reads THIS instance's health
    public let actions: [ModuleAction]           // bound to THIS instance
}

/// The user-facing description of an integration. A value, constructed at the
/// registration site — no protocol to conform to, `NotificationSource` untouched.
@MainActor
public struct Module: Identifiable {
    public let id: SourceID
    public let displayName: String
    public let icon: Content.Icon                // reuse the domain icon type
    let activate: () -> ActiveModule             // the "make a fresh one" recipe

    /// Rich form: build source + bind its status/actions together (concrete type in scope).
    public init(id: SourceID, displayName: String, icon: Content.Icon,
                activate: @escaping () -> ActiveModule)

    /// Trivial form: just a source. Status defaults to `.ok`, no actions — the zero-code
    /// common case (a module in ~5 lines).
    public init(id: SourceID, displayName: String, icon: Content.Icon,
                makeSource: @escaping () -> any NotificationSource)
}
```

Author's-eye view — the two tiers the north star promises:

```swift
// Trivial: row + status + toggle for free, no SwiftUI.
registry.add(Module(id: SourceID(raw: "weather"), displayName: "Weather",
                    icon: .symbol("cloud.rain"), makeSource: { WeatherSource() }))

// Rich: bind health + a "Connect" button to the concrete instance.
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

### `ModuleAction` — a labeled button that isn't a panel

The simple affordances ("Connect Calendar…", "Sign out") are just a label + work — not a
config screen. Core carries them as values; the App renders each as a button, generically.
Anything that needs a real form is the opt-in App panel instead.

```swift
public struct ModuleAction: Identifiable {
    public let id = UUID()
    public let label: String
    let run: () async -> Void
    public init(_ label: String, run: @escaping () async -> Void)
}
```

### `ModuleStore` — the injected persistence seam

Mirrors the `Clock`/`AudioOutput` pattern: a tiny protocol so the registry is headless.

```swift
public protocol ModuleStore: Sendable {
    func disabledIDs() -> Set<SourceID>
    func setDisabled(_ ids: Set<SourceID>)
}
// Production: UserDefaultsModuleStore (one key, a [String] of raw ids).
// Test: an in-memory dictionary-backed double.
```

### `ModuleRegistry` — the manager (the tested heart)

```swift
@MainActor
public final class ModuleRegistry {
    public init(core: IslandCore, store: any ModuleStore)

    public func add(_ module: Module)              // define a module (built-in or third-party)
    public func start()                            // activate every enabled module

    public var modules: [Module] { get }           // the list the UI renders
    public func isEnabled(_ id: SourceID) -> Bool
    public func setEnabled(_ id: SourceID, _ on: Bool)   // the toggle
    public func status(of id: SourceID) -> ModuleDisplayStatus   // .disabled | .live(ModuleStatus)
}
```

- **`setEnabled(id, true)`** → `let a = module.activate(); core.register(a.source)`; retain
  the `ActiveModule`; drop `id` from the persisted disabled set.
- **`setEnabled(id, false)`** → `core.unregister(id, revokingCards: true)`; release the
  `ActiveModule`; add `id` to the persisted disabled set.
- **`status(of:)`** → `.disabled` when off; otherwise the retained `ActiveModule.status()`.

### One tiny `IslandCore` change: sweep-on-unregister

`unregister` today only revokes a source's cards when it opted into `revokeOnDisconnect`
(neither built-in does), so a plain disable would strand GitHub's sticky "Deploy running"
pill. Add an override that force-revokes — existing callers are unaffected:

```swift
public func unregister(_ id: SourceID, revokingCards: Bool = false) async
// sweep when: revokingCards || reg.source.revokeOnDisconnect
```

## Toggle — the state machine

```
        add(module)                     enabled at start()?
 (defined) ──────────▶ (registered/registry) ──yes──▶ activate() → core.register(source)
                                    │                              │
                              setEnabled(false)              setEnabled(false)
                                    │                              ▼
                                    └───────────────▶ core.unregister(id, revokingCards: true)
                                                       + drop ActiveModule + persist disabled
 (disabled) ── setEnabled(true) ──▶ activate() [FRESH source] → core.register + persist enabled
```

Invariant: a disabled module owns **zero** live cards and **zero** background work (its
source's `stop()` tore down timers/observers). Re-enabling is a cold start, never a resume.

## UI shell (`MacIslandApp`)

- **`MenuBarExtra`** (extends the existing ✨ menu): a `.window`-style content view so we
  control layout.
  - **Modules list:** one row per `registry.modules` — icon, name, status light
    (`registry.status(of:)` → 🟢/🟡+reason/⚪), a `Toggle` bound to `setEnabled`, and a
    button per `ActiveModule.action`. Status is read when the view appears and re-read after
    an action fires (so "Connect" flips the light green immediately). No timers.
  - **"Connected" strip (read-only):** external JSON-ingress connections, from the ingress
    host's own connection snapshot (so the dev demo source doesn't leak in). Named
    connections shown by id; anonymous per-connection ones collapsed to "N connected".
  - **Quit** stays.
- **`Settings` scene:** hosts the opt-in per-module panels, keyed by id. A module that has a
  panel shows a "Settings…" button in its row that opens the Settings window (macOS 14
  `@Environment(\.openSettings)`) to its page. **v1 wires this hook but registers no
  built-in panel** — Calendar/GitHub need only auth *buttons*, which live in the row.
- **App-side panel registry:** a light `id → () -> some View` lookup in `MacIslandApp`
  (empty in v1). The extension point for "opt in and build your settings."

### Boot change

Replace the hand-written `core.register(Calendar/GitHub…)` calls with:

```swift
let registry = ModuleRegistry(core: core, store: UserDefaultsModuleStore())
registry.add(Module(/* calendar */)); registry.add(Module(/* github */))
registry.start()
```

`DevSource` stays a plain direct `core.register` (a walking-skeleton demo, not a
user-facing module) and is excluded from the list; the ingress host is unchanged.

## Testing (TDD the Core pieces)

Same seam as the rest of the suite: an `IslandCore` on a `TestClock`, an in-memory
`ModuleStore`, scripted sources; register-drive-assert.

| Scenario | Assert |
|----------|--------|
| `start()` with defaults | enabled modules appear in `core.liveSourceIDs`; none disabled by default |
| Disable a live module | source gone from `liveSourceIDs` **and** its cards gone from `core.ordered` (even without `revokeOnDisconnect`) |
| Re-enable | a **fresh** source instance registered (identity differs); its posts appear |
| Persistence round-trip | `setEnabled(id,false)` → new `ModuleRegistry` on the same store → module stays off after `start()` |
| Status roll-up | source reporting `needsAttention` surfaces via `status(of:)`; disabled → `.disabled` |
| `unregister(revokingCards:true)` | sweeps cards regardless of `revokeOnDisconnect`; `false` path unchanged |
| Quiescence | no timers armed by the registry at idle (perf invariant) |

GUI (menu list, Connected strip, Settings hook) is verified by build + run.

## Performance

The registry does nothing at idle — no timers, no polling. Status is pulled on menu-open
only. Toggling is the sole active moment. Quiescent-at-idle (`PERFORMANCE.md`) is preserved
by construction.

## Third-party contract (`DEVELOPING.md`)

A new "Add a module" section next to "add a source": construct a `Module` (trivial or rich
form above), `registry.add(…)`, rebuild. Opt-in settings: register a SwiftUI view for your
id in the App-side panel registry. Documents `ModuleStatus`, `ModuleAction`, and the
`activate()`/`ActiveModule` factory pattern (why it's a fresh-instance recipe, not a live
object).

## Out of scope / follow-ups

- Runtime plug-in loading (compile-time only, by design).
- Built-in settings *panels* — the hook ships, the first real panel lands when a module
  needs one.
- Live-updating status while the menu sits open; a menu-bar-icon "needs attention" badge.
- Surfacing anonymous ingress connections individually (collapsed to a count in v1).
- A per-module toggle hook (add only when a real module needs work beyond start/stop).
