# Modules & Settings Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a first-class **Module** layer over the (unchanged, dumb) `NotificationSource`, plus a menu-bar settings surface to see, toggle, and configure integrations.

**Architecture:** Two layers. In `MacIslandCore` (headless-tested): value types `Module`/`ActiveModule`/`ModuleStatus`/`ModuleAction`, an injected `ModuleStore` persistence seam, and a `ModuleRegistry` manager that drives `IslandCore.register`/`unregister`. In `MacIslandApp` (build+run): a `MenuBarExtra` list + a read-only "Connected" strip, and an opt-in per-module `Settings` panel keyed by id. `NotificationSource` is untouched; the layer is additive.

**Tech Stack:** Swift package, macOS 14+, Apple frameworks only. XCTest (`@MainActor final class … : XCTestCase`, `func test_…() async`). Injected `Clock`/`ModuleStore` seams; `swift build` / `swift test`.

**Design doc:** `docs/plans/2026-07-21-modules-system-design.md`. **Branch:** `feat/modules-system`.

**Conventions to match:** dense "why" doc-comments; `@MainActor` types; reuse `Content.Icon` for module icons; test doubles live in `Tests/MacIslandCoreTests/`. Use @superpowers:test-driven-development for every Core task (RED → GREEN → commit).

---

### Task 1: `ModuleStatus` + `ModuleDisplayStatus` (Core)

**Files:**
- Create: `Sources/MacIslandCore/Module.swift`
- Test: `Tests/MacIslandCoreTests/ModuleTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest
@testable import MacIslandCore

@MainActor
final class ModuleTests: XCTestCase {
    func test_moduleStatus_equatable() {
        XCTAssertEqual(ModuleStatus.ok, .ok)
        XCTAssertEqual(ModuleStatus.needsAttention("x"), .needsAttention("x"))
        XCTAssertNotEqual(ModuleStatus.needsAttention("x"), .needsAttention("y"))
    }

    func test_displayStatus_distinguishesDisabledFromLive() {
        XCTAssertEqual(ModuleDisplayStatus.disabled, .disabled)
        XCTAssertEqual(ModuleDisplayStatus.live(.ok), .live(.ok))
        XCTAssertNotEqual(ModuleDisplayStatus.disabled, .live(.ok))
    }
}
```

**Step 2: Run to verify it fails**

Run: `swift test --filter ModuleTests`
Expected: FAIL — "cannot find 'ModuleStatus' in scope".

**Step 3: Write minimal implementation** (in `Sources/MacIslandCore/Module.swift`)

```swift
import Foundation

/// A module's health as the settings panel renders it. Deliberately tiny: the light is
/// green (`.ok`), or yellow-with-a-reason (`.needsAttention`). "Disabled" is **not** a
/// `ModuleStatus` — an off module has no live source to report, so that state is the
/// registry's (`ModuleDisplayStatus.disabled`), never the module's.
public enum ModuleStatus: Equatable, Sendable {
    case ok
    case needsAttention(String)   // reason, e.g. "Not signed in", "Can't reach GitHub"
}

/// What the panel actually shows per row: ⚪ off, or a live module's 🟢/🟡. Splitting
/// "disabled" out here (rather than adding it to `ModuleStatus`) keeps the module's own
/// health vocabulary about *health*, not toggle state.
public enum ModuleDisplayStatus: Equatable, Sendable {
    case disabled
    case live(ModuleStatus)
}
```

**Step 4: Run to verify it passes** — `swift test --filter ModuleTests` → PASS.

**Step 5: Commit**

```bash
git add Sources/MacIslandCore/Module.swift Tests/MacIslandCoreTests/ModuleTests.swift
git commit -m "feat(core): add ModuleStatus / ModuleDisplayStatus"
```

---

### Task 2: `ModuleAction` (Core)

**Files:**
- Modify: `Sources/MacIslandCore/Module.swift`
- Test: `Tests/MacIslandCoreTests/ModuleTests.swift`

**Step 1: Add the failing test** (append to `ModuleTests`)

```swift
func test_moduleAction_runsItsWork() async {
    var ran = false
    let action = ModuleAction("Connect") { ran = true }
    XCTAssertEqual(action.label, "Connect")
    await action.perform()
    XCTAssertTrue(ran, "perform() runs the action's work")
}
```

**Step 2: Run to verify it fails** — `swift test --filter ModuleTests/test_moduleAction_runsItsWork` → FAIL ("cannot find 'ModuleAction'").

**Step 3: Implement** (append to `Module.swift`)

```swift
/// A labeled affordance that isn't a settings panel — a name plus work to do (e.g.
/// "Connect Calendar…"). The App renders each as a button. Anything needing a real
/// form is the opt-in App-side panel instead, not a `ModuleAction`.
@MainActor
public struct ModuleAction: Identifiable {
    public let id = UUID()
    public let label: String
    private let work: () async -> Void

    public init(_ label: String, run: @escaping () async -> Void) {
        self.label = label
        self.work = run
    }

    public func perform() async { await work() }
}
```

**Step 4: Run to verify it passes** — PASS.

**Step 5: Commit**

```bash
git add Sources/MacIslandCore/Module.swift Tests/MacIslandCoreTests/ModuleTests.swift
git commit -m "feat(core): add ModuleAction"
```

---

### Task 3: `Module` + `ActiveModule` (Core)

**Files:**
- Modify: `Sources/MacIslandCore/Module.swift`
- Test: `Tests/MacIslandCoreTests/ModuleTests.swift`

**Note:** `Content.Icon` is the existing icon type (`.symbol(_:)` / `.image(_:)`) used by `Content.icon`. Reuse it — do not invent a new icon type.

**Step 1: Add failing tests**

```swift
func test_trivialModule_defaultsToOkAndNoActions() {
    let m = Module(id: SourceID(raw: "weather"), displayName: "Weather",
                   icon: .symbol("cloud.rain"), makeSource: { SpySource("weather") })
    let active = m.activate()
    XCTAssertEqual(active.status(), .ok, "trivial module is healthy by default")
    XCTAssertTrue(active.actions.isEmpty)
    XCTAssertEqual(active.source.id, SourceID(raw: "weather"))
}

func test_activate_buildsAFreshSourceEachTime() {
    var builds = 0
    let m = Module(id: SourceID(raw: "m"), displayName: "M", icon: .symbol("gear"),
                   makeSource: { builds += 1; return SpySource("m") })
    _ = m.activate(); _ = m.activate()
    XCTAssertEqual(builds, 2, "each activate() builds a fresh source (no resume)")
}
```

**Step 2: Run to verify it fails** — FAIL ("cannot find 'Module'").

**Step 3: Implement** (append to `Module.swift`)

```swift
/// A live, switched-on module: the fresh source bundled with health/actions bound to
/// *that* instance. Produced by `Module.activate()` on each enable, dropped on disable.
/// Bundling is the trick that lets `status`/`actions` read the concrete source's own
/// state (which the dumb `NotificationSource` doesn't expose) without downcasting or
/// stale capture — the closures close over the instance built alongside them.
@MainActor
public struct ActiveModule {
    public let source: any NotificationSource
    public let status: () -> ModuleStatus
    public let actions: [ModuleAction]

    public init(source: any NotificationSource,
                status: @escaping () -> ModuleStatus = { .ok },
                actions: [ModuleAction] = []) {
        self.source = source
        self.status = status
        self.actions = actions
    }
}

/// The user-facing description of an integration — a **value you construct**, not a
/// protocol you conform to (design: "protocol vs wrapper → wrapper"). It composes over
/// an untouched `NotificationSource`. Not "metadata + a live source" but "metadata + a
/// recipe": `activate()` rebuilds a fresh source on every enable, because stateful
/// sources can't be resumed after `stop()`.
@MainActor
public struct Module: Identifiable {
    public let id: SourceID
    public let displayName: String
    public let icon: Content.Icon
    /// Build a fresh live instance + its bound status/actions. Called on each enable.
    public let activate: () -> ActiveModule

    /// Rich form: build the source and bind its status/actions together, with the
    /// concrete source type in scope (so `status` can read e.g. `src.authorizationStatus`).
    public init(id: SourceID, displayName: String, icon: Content.Icon,
                activate: @escaping () -> ActiveModule) {
        self.id = id
        self.displayName = displayName
        self.icon = icon
        self.activate = activate
    }

    /// Trivial form — the zero-screen-code common case: just a source. Health defaults to
    /// `.ok`, no actions. A module in ~5 lines.
    public init(id: SourceID, displayName: String, icon: Content.Icon,
                makeSource: @escaping () -> any NotificationSource) {
        self.init(id: id, displayName: displayName, icon: icon,
                  activate: { ActiveModule(source: makeSource()) })
    }
}
```

**Step 4: Run to verify it passes** — `swift test --filter ModuleTests` → PASS (all).

**Step 5: Commit**

```bash
git add Sources/MacIslandCore/Module.swift Tests/MacIslandCoreTests/ModuleTests.swift
git commit -m "feat(core): add Module + ActiveModule (wrapper over NotificationSource)"
```

---

### Task 4: `ModuleStore` seam + `UserDefaultsModuleStore` + in-memory double

**Files:**
- Create: `Sources/MacIslandCore/ModuleStore.swift`
- Create: `Tests/MacIslandCoreTests/ModuleStoreDoubles.swift`
- Test: `Tests/MacIslandCoreTests/ModuleStoreTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest
@testable import MacIslandCore

@MainActor
final class ModuleStoreTests: XCTestCase {
    func test_inMemoryStore_roundTrips() {
        let store = InMemoryModuleStore()
        XCTAssertTrue(store.disabledIDs().isEmpty)
        store.setDisabled([SourceID(raw: "github")])
        XCTAssertEqual(store.disabledIDs(), [SourceID(raw: "github")])
    }

    func test_userDefaultsStore_persistsAcrossInstances() {
        let suite = "modules.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        UserDefaultsModuleStore(defaults: defaults).setDisabled([SourceID(raw: "calendar")])
        // A fresh store over the same defaults must see it — the persistence contract.
        XCTAssertEqual(UserDefaultsModuleStore(defaults: defaults).disabledIDs(),
                       [SourceID(raw: "calendar")])
    }
}
```

**Step 2: Run to verify it fails** — FAIL ("cannot find 'InMemoryModuleStore' / 'UserDefaultsModuleStore'").

**Step 3: Implement**

`Sources/MacIslandCore/ModuleStore.swift`:

```swift
import Foundation

/// The persistence seam for module on/off state — injected like `Clock`/`AudioOutput`
/// so `ModuleRegistry` stays headless-testable. We persist the **disabled** set (not the
/// enabled one) so new built-ins default **on** without a migration.
public protocol ModuleStore {
    func disabledIDs() -> Set<SourceID>
    func setDisabled(_ ids: Set<SourceID>)
}

/// Production store — one `UserDefaults` key holding the sorted raw ids of disabled
/// modules. Injectable defaults so tests can use a throwaway suite.
public final class UserDefaultsModuleStore: ModuleStore {
    private let defaults: UserDefaults
    private let key = "modules.disabled"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func disabledIDs() -> Set<SourceID> {
        Set((defaults.stringArray(forKey: key) ?? []).map(SourceID.init(raw:)))
    }

    public func setDisabled(_ ids: Set<SourceID>) {
        defaults.set(ids.map(\.raw).sorted(), forKey: key)   // sorted → stable on disk
    }
}
```

`Tests/MacIslandCoreTests/ModuleStoreDoubles.swift`:

```swift
@testable import MacIslandCore

/// In-memory `ModuleStore` for headless registry tests — the persistence analogue of
/// `TestClock`.
final class InMemoryModuleStore: ModuleStore {
    private var ids: Set<SourceID>
    init(_ ids: Set<SourceID> = []) { self.ids = ids }
    func disabledIDs() -> Set<SourceID> { ids }
    func setDisabled(_ ids: Set<SourceID>) { self.ids = ids }
}
```

**Step 4: Run to verify it passes** — `swift test --filter ModuleStoreTests` → PASS.

**Step 5: Commit**

```bash
git add Sources/MacIslandCore/ModuleStore.swift Tests/MacIslandCoreTests/ModuleStoreDoubles.swift Tests/MacIslandCoreTests/ModuleStoreTests.swift
git commit -m "feat(core): add ModuleStore seam (UserDefaults + in-memory double)"
```

---

### Task 5: `IslandCore.unregister(revokingCards:)` — sweep on disable

**Files:**
- Modify: `Sources/MacIslandCore/IslandCore.swift:125-138` (the `unregister` method)
- Test: `Tests/MacIslandCoreTests/UnregisterCardSweepTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest
@testable import MacIslandCore

private typealias Notification = MacIslandCore.Notification

@MainActor
final class UnregisterCardSweepTests: XCTestCase {
    func test_unregister_revokingCards_sweepsEvenWhenSourceDidNotOptIn() async {
        let core = IslandCore(clock: TestClock())
        // SpySource defaults revokeOnDisconnect = false (the fire-and-forget default).
        let handle = core.register(SpySource("gh"))
        handle?.post(Content(title: "Deploy running"), value: "run-1", presence: .sticky)
        XCTAssertEqual(core.ordered.count, 1)

        await core.unregister(SourceID(raw: "gh"), revokingCards: true)

        XCTAssertTrue(core.ordered.isEmpty, "disable sweeps the module's cards")
        XCTAssertFalse(core.liveSourceIDs.contains(SourceID(raw: "gh")))
    }

    func test_unregister_default_stillHonorsFireAndForget() async {
        let core = IslandCore(clock: TestClock())
        let handle = core.register(SpySource("ci"))   // revokeOnDisconnect = false
        handle?.post(Content(title: "toast"), value: "t1", presence: .sticky)

        await core.unregister(SourceID(raw: "ci"))    // default: no sweep

        XCTAssertEqual(core.ordered.count, 1, "default unregister leaves cards (unchanged)")
    }

    func test_unregister_sweep_firesOnChange() async {
        let core = IslandCore(clock: TestClock())
        let handle = core.register(SpySource("gh"))
        handle?.post(Content(title: "x"), value: "1", presence: .sticky)
        var ticks = 0
        core.onChange = { ticks += 1 }
        await core.unregister(SourceID(raw: "gh"), revokingCards: true)
        XCTAssertEqual(ticks, 1, "sweeping a visible card re-renders the panel")
    }
}
```

**Step 2: Run to verify it fails** — FAIL (extra `revokingCards:` argument).

**Step 3: Implement** — modify the existing `unregister` signature + body (do **not** add an overload; a single defaulted param avoids call-site ambiguity for the existing `unregister(id)` callers — `faultTeardown` and `IngressHost`):

```swift
public func unregister(_ id: SourceID, revokingCards: Bool = false) async {
    guard let reg = registry[id] else { return }
    registry[id] = nil                       // remove first: routing + re-entrancy see it gone
    reg.startTask?.cancel()
    // Orphan policy (spec §5): default LEAVEs the cards. `revokeOnDisconnect` opts a
    // source in; `revokingCards` is the *caller* forcing it — the module toggle's
    // "off means gone", independent of the source's own default.
    if revokingCards || reg.source.revokeOnDisconnect {
        let mine = stack.ordered.filter { $0.id.source == id }
        for card in mine { removeCard(card.id) }
        if !mine.isEmpty {                   // a card left the screen → reconcile + re-render
            alerter.reconcile(stack.ordered)
            notifyChange()
        }
    }
    await safely(id) { try await reg.source.stop() }
    Log.registry.info("unregistered source '\(id.raw, privacy: .public)'")
}
```

**Step 4: Run to verify it passes** — `swift test --filter UnregisterCardSweepTests` → PASS. Then full `swift test` to confirm no regression in existing `unregister` callers.

**Step 5: Commit**

```bash
git add Sources/MacIslandCore/IslandCore.swift Tests/MacIslandCoreTests/UnregisterCardSweepTests.swift
git commit -m "feat(core): unregister(revokingCards:) force-sweeps a source's cards"
```

---

### Task 6: `ModuleRegistry` — the manager

**Files:**
- Create: `Sources/MacIslandCore/ModuleRegistry.swift`
- Test: `Tests/MacIslandCoreTests/ModuleRegistryTests.swift`

**Step 1: Write the failing tests**

```swift
import XCTest
@testable import MacIslandCore

@MainActor
final class ModuleRegistryTests: XCTestCase {

    private func makeCore() -> IslandCore { IslandCore(clock: TestClock()) }

    func test_start_registersEnabledModules_byDefault() {
        let core = makeCore()
        let reg = ModuleRegistry(core: core, store: InMemoryModuleStore())
        reg.add(Module(id: SourceID(raw: "a"), displayName: "A", icon: .symbol("gear"),
                       makeSource: { SpySource("a") }))
        reg.start()
        XCTAssertTrue(core.liveSourceIDs.contains(SourceID(raw: "a")))
        XCTAssertTrue(reg.isEnabled(SourceID(raw: "a")))
    }

    func test_start_skipsDisabledModules() {
        let core = makeCore()
        let reg = ModuleRegistry(core: core, store: InMemoryModuleStore([SourceID(raw: "a")]))
        reg.add(Module(id: SourceID(raw: "a"), displayName: "A", icon: .symbol("gear"),
                       makeSource: { SpySource("a") }))
        reg.start()
        XCTAssertFalse(core.liveSourceIDs.contains(SourceID(raw: "a")))
        XCTAssertFalse(reg.isEnabled(SourceID(raw: "a")))
    }

    func test_disable_unregistersAndPersists() async {
        let core = makeCore()
        let store = InMemoryModuleStore()
        let reg = ModuleRegistry(core: core, store: store)
        reg.add(Module(id: SourceID(raw: "a"), displayName: "A", icon: .symbol("gear"),
                       makeSource: { SpySource("a") }))
        reg.start()

        await reg.setEnabled(SourceID(raw: "a"), false)

        XCTAssertFalse(core.liveSourceIDs.contains(SourceID(raw: "a")))
        XCTAssertEqual(store.disabledIDs(), [SourceID(raw: "a")], "off is persisted")
    }

    func test_reEnable_buildsFreshSource() async {
        let core = makeCore()
        var builds = 0
        let reg = ModuleRegistry(core: core, store: InMemoryModuleStore())
        reg.add(Module(id: SourceID(raw: "a"), displayName: "A", icon: .symbol("gear"),
                       makeSource: { builds += 1; return SpySource("a") }))
        reg.start()                                    // builds == 1
        await reg.setEnabled(SourceID(raw: "a"), false)
        await reg.setEnabled(SourceID(raw: "a"), true) // builds == 2 (fresh, not resumed)

        XCTAssertEqual(builds, 2)
        XCTAssertTrue(core.liveSourceIDs.contains(SourceID(raw: "a")))
    }

    func test_persistedOff_survivesANewRegistry() {
        let core = makeCore()
        let store = InMemoryModuleStore([SourceID(raw: "a")])   // previously disabled
        let reg = ModuleRegistry(core: core, store: store)      // fresh registry, same store
        reg.add(Module(id: SourceID(raw: "a"), displayName: "A", icon: .symbol("gear"),
                       makeSource: { SpySource("a") }))
        reg.start()
        XCTAssertFalse(core.liveSourceIDs.contains(SourceID(raw: "a")))
    }

    func test_status_reflectsLiveHealth_andDisabled() async {
        let core = makeCore()
        var health: ModuleStatus = .ok
        let reg = ModuleRegistry(core: core, store: InMemoryModuleStore())
        reg.add(Module(id: SourceID(raw: "a"), displayName: "A", icon: .symbol("gear")) {
            ActiveModule(source: SpySource("a"), status: { health })
        })
        reg.start()
        XCTAssertEqual(reg.status(of: SourceID(raw: "a")), .live(.ok))

        health = .needsAttention("Not signed in")
        XCTAssertEqual(reg.status(of: SourceID(raw: "a")), .live(.needsAttention("Not signed in")))

        await reg.setEnabled(SourceID(raw: "a"), false)
        XCTAssertEqual(reg.status(of: SourceID(raw: "a")), .disabled)
    }

    func test_registryArmsNoTimers_atIdle() {
        let clock = TestClock()
        let core = IslandCore(clock: clock)
        let reg = ModuleRegistry(core: core, store: InMemoryModuleStore())
        reg.add(Module(id: SourceID(raw: "a"), displayName: "A", icon: .symbol("gear"),
                       makeSource: { SpySource("a") }))
        reg.start()
        XCTAssertEqual(clock.armedCount, 0, "the registry itself schedules nothing (quiescent)")
    }
}
```

**Step 2: Run to verify it fails** — FAIL ("cannot find 'ModuleRegistry'").

**Step 3: Implement** (`Sources/MacIslandCore/ModuleRegistry.swift`)

```swift
import Foundation

/// The Modules manager: owns the module definitions, remembers on/off across launches
/// (via the injected `ModuleStore`), and drives `IslandCore` registration. The one place
/// the two-object source contract meets user-facing module state. `@MainActor` like the
/// core it drives; headless-testable with a `TestClock` core + `InMemoryModuleStore`.
///
/// It does **no** background work — no timers, no polling. Status is pulled on demand
/// (the menu reads it on open), so it's quiescent at idle by construction (`PERFORMANCE.md`).
@MainActor
public final class ModuleRegistry {
    private let core: IslandCore
    private let store: any ModuleStore
    private var defined: [Module] = []
    /// The live bundle for each currently-enabled module (source + bound status/actions).
    /// Absent ⇒ disabled. This is where `status(of:)` reads health, and what a disable drops.
    private var active: [SourceID: ActiveModule] = [:]
    private var disabled: Set<SourceID>

    public init(core: IslandCore, store: any ModuleStore) {
        self.core = core
        self.store = store
        self.disabled = store.disabledIDs()
    }

    /// The list the settings UI renders, in registration order.
    public var modules: [Module] { defined }

    /// Define a module (a built-in at boot, or a third-party's). Call before `start()`.
    public func add(_ module: Module) { defined.append(module) }

    /// Activate every module not persisted as disabled. Call once, after boot.
    public func start() {
        for module in defined where !disabled.contains(module.id) { enable(module) }
    }

    public func isEnabled(_ id: SourceID) -> Bool { !disabled.contains(id) }

    /// The toggle. On ⇒ build a fresh source + register. Off ⇒ unregister and sweep its
    /// cards (off means gone). Persists the new state either way. Idempotent.
    public func setEnabled(_ id: SourceID, _ on: Bool) async {
        guard let module = defined.first(where: { $0.id == id }) else { return }
        if on {
            disabled.remove(id)
            store.setDisabled(disabled)
            if active[id] == nil { enable(module) }
        } else {
            disabled.insert(id)
            store.setDisabled(disabled)
            if active[id] != nil {
                active[id] = nil
                await core.unregister(id, revokingCards: true)
            }
        }
    }

    /// The per-row display status: ⚪ when off, else the live source's own 🟢/🟡.
    public func status(of id: SourceID) -> ModuleDisplayStatus {
        guard let a = active[id] else { return .disabled }
        return .live(a.status())
    }

    /// The live actions for a row (empty when disabled) — the App renders each as a button.
    public func actions(of id: SourceID) -> [ModuleAction] { active[id]?.actions ?? [] }

    private func enable(_ module: Module) {
        let a = module.activate()
        active[module.id] = a
        core.register(a.source)
    }
}
```

**Step 4: Run to verify it passes** — `swift test --filter ModuleRegistryTests` → PASS. Then full `swift test` (green suite).

**Step 5: Commit**

```bash
git add Sources/MacIslandCore/ModuleRegistry.swift Tests/MacIslandCoreTests/ModuleRegistryTests.swift
git commit -m "feat(core): add ModuleRegistry (toggle, persistence, status roll-up)"
```

---

### Task 7: Rewire boot to use modules (App)

**Files:**
- Modify: `Sources/MacIslandApp/MacIslandApp.swift:60-91` (replace the hand-registered Calendar + GitHub `core.register(…)` calls)

**No headless test** — GUI/boot, verified by build + run.

**Step 1: Build a module factory** — add a helper in `AppDelegate` (or a small `BuiltInModules.swift`) that constructs the two built-ins, mapping each source's native status onto `ModuleStatus`:

```swift
// In AppDelegate, replace the two `core.register(CalendarSource…/GitHubActionsSource…)`
// blocks with a ModuleRegistry.

let registry = ModuleRegistry(core: core, store: UserDefaultsModuleStore())
self.moduleRegistry = registry   // retain: new stored property `private var moduleRegistry: ModuleRegistry?`

// Calendar: a fresh source per enable; status from EventKit auth; a Connect action.
registry.add(Module(id: SourceID(raw: "calendar"), displayName: "Calendar",
                    icon: .symbol("calendar")) {
    let src = CalendarSource(store: EventKitStore(), clock: clock)
    return ActiveModule(
        source: src,
        status: { src.authorizationStatus == .authorized ? .ok : .needsAttention("Not connected") },
        actions: [ModuleAction("Connect Calendar…") { _ = await src.requestAccess() }]
    )
})

// GitHub: map its Status; no button (gh login is a terminal step — the reason string says so).
// The repo/branch/workflow filter come from the user's saved GitHubConfig (see GitHubSettingsView).
registry.add(Module(id: SourceID(raw: "github"), displayName: "GitHub CI/CD",
                    icon: .symbol("shippingbox.fill")) {
    let config = UserDefaultsGitHubConfigStore().load()!   // parks until configured; see MacIslandApp
    let src = GitHubActionsSource(
        client: GitHubDeployClient(config: config),
        clock: clock,
        nudgeFile: AppSupport.directory.appendingPathComponent("github.poke"))
    return ActiveModule(source: src, status: {
        switch src.status {
        case .starting, .ok:        return .ok
        case .needsAuth(let r):     return .needsAttention(r)
        case .error(let e):         return .needsAttention(e)
        }
    })
})

registry.start()
```

Keep `core.register(DevSource())` as-is (dev demo, not a user-facing module; its id `"dev"` is not `ingress:`-prefixed so it won't appear in the Connected strip). Leave the ingress host block unchanged.

**Step 2: Build** — `swift build` → succeeds.

**Step 3: Run & verify** — `swift run MacIslandApp`. Confirm: no crash at boot; Calendar prompts/監視 as before; a deploy still surfaces (behaviour unchanged — modules just wrap the same sources). Use @run if a project run-skill exists.

**Step 4: Commit**

```bash
git add Sources/MacIslandApp/MacIslandApp.swift
git commit -m "feat(app): register built-in sources through ModuleRegistry"
```

---

### Task 8: Menu-bar modules list + read-only Connected strip (App)

**Files:**
- Create: `Sources/MacIslandApp/ModulesMenu.swift`
- Modify: `Sources/MacIslandApp/MacIslandApp.swift` (MenuBarExtra body; expose `registry` + `core` from the delegate)

**No headless test** — SwiftUI, verified by build + run.

**Step 1: Make the delegate publish its registry/core** so the `MenuBarExtra` body can read them once boot completes:

```swift
// AppDelegate conforms to ObservableObject; mark the two properties @Published (or use
// @Observable). They start nil and are set at the end of applicationDidFinishLaunching.
@Published var moduleRegistry: ModuleRegistry?
@Published var islandCore: IslandCore?
```

**Step 2: MenuBarExtra body** (`.window` style so we get real controls):

```swift
MenuBarExtra("macIsland", systemImage: "sparkles") {
    if let registry = delegate.moduleRegistry, let core = delegate.islandCore {
        ModulesMenu(registry: registry, core: core)
    } else {
        Button("Quit macIsland") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
.menuBarExtraStyle(.window)
```

**Step 3: `ModulesMenu.swift`** — rows + Connected strip. Re-reads status on appear and after a toggle/action via a `version` bump (the menu is short-lived, so pull-on-open is enough — matches the design's "read when the menu opens"):

```swift
import SwiftUI
import MacIslandCore

/// The menu-bar dropdown: one row per module (icon · name · status light · toggle ·
/// action buttons) plus a read-only "Connected" strip of external JSON-ingress
/// connections. Pull-model: statuses are read on appear and after each interaction —
/// no background work, so the idle quiescence budget is untouched.
struct ModulesMenu: View {
    let registry: ModuleRegistry
    let core: IslandCore
    @Environment(\.openSettings) private var openSettings
    @State private var version = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(registry.modules) { module in
                moduleRow(module)
            }
            let connected = connectedIngress()
            if !connected.isEmpty {
                Divider()
                Text("Connected").font(.caption).foregroundStyle(.secondary)
                ForEach(connected, id: \.self) { Text($0).font(.caption) }
            }
            Divider()
            Button("Quit macIsland") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 300)
        .id(version)   // re-read pulled state after an interaction
    }

    @ViewBuilder private func moduleRow(_ module: Module) -> some View {
        let display = registry.status(of: module.id)
        HStack {
            Image(systemName: iconName(module.icon))
            VStack(alignment: .leading) {
                Text(module.displayName)
                statusLabel(display)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { registry.isEnabled(module.id) },
                set: { on in Task { await registry.setEnabled(module.id, on); version += 1 } }
            )).labelsHidden()
        }
        ForEach(registry.actions(of: module.id)) { action in
            Button(action.label) { Task { await action.perform(); version += 1 } }
        }
    }

    @ViewBuilder private func statusLabel(_ s: ModuleDisplayStatus) -> some View {
        switch s {
        case .disabled:                   Label("Off", systemImage: "circle").foregroundStyle(.secondary)
        case .live(.ok):                  Label("OK", systemImage: "circle.fill").foregroundStyle(.green)
        case .live(.needsAttention(let r)): Label(r, systemImage: "exclamationmark.circle.fill").foregroundStyle(.yellow)
        }.font(.caption)
    }

    /// External JSON-ingress connections = live sources namespaced `ingress:` (SocketSource
    /// ids). Named ones show their name; anonymous per-connection ones collapse to a count.
    private func connectedIngress() -> [String] {
        let ingress = core.liveSourceIDs.map(\.raw).filter { $0.hasPrefix("ingress:") }
        let named = ingress.filter { !$0.hasPrefix("ingress:anon-") }
                           .map { String($0.dropFirst("ingress:".count)) }.sorted()
        let anon = ingress.count - named.count
        return named + (anon > 0 ? ["\(anon) anonymous"] : [])
    }

    private func iconName(_ icon: Content.Icon) -> String {
        if case .symbol(let name) = icon { return name }
        return "puzzlepiece.extension"   // .image fallback in the menu
    }
}
```

**Step 4: Build + run** — `swift build`, then `swift run MacIslandApp`. Click ✨: confirm Calendar + GitHub rows with status lights + working toggles (turn GitHub off → its pill/cards vanish; on → it comes back), the "Connect Calendar…" button, and (with `macisland notify --source ci …` running) a "Connected" strip showing `ci`.

**Step 5: Commit**

```bash
git add Sources/MacIslandApp/ModulesMenu.swift Sources/MacIslandApp/MacIslandApp.swift
git commit -m "feat(app): menu-bar modules list + read-only Connected strip"
```

---

### Task 9: Settings-window hook + opt-in panel registry (App)

**Files:**
- Create: `Sources/MacIslandApp/ModuleSettings.swift`
- Modify: `Sources/MacIslandApp/MacIslandApp.swift` (add a `Settings` scene; add a "Settings…" button per module that has a panel)

**No headless test** — verified by build + run. **v1 ships the hook empty** (no built-in panel).

**Step 1: Panel registry + Settings scene**

```swift
// ModuleSettings.swift
import SwiftUI
import MacIslandCore

/// The opt-in extension point: a module id → its SwiftUI settings panel. Empty in v1
/// (Calendar/GitHub need only buttons). A module "opts in and builds its settings" by
/// adding an entry here — the row then shows a "Settings…" button that opens this panel
/// in the standard Settings window.
@MainActor
enum ModuleSettingsPanels {
    static let byID: [SourceID: () -> AnyView] = [:]   // e.g. SourceID(raw:"github"): { AnyView(GitHubSettings()) }
    static func hasPanel(_ id: SourceID) -> Bool { byID[id] != nil }
}

/// Hosts whichever module's panel was opened. Falls back to a placeholder so the empty-v1
/// window isn't blank if reached.
struct ModulesSettingsView: View {
    let registry: ModuleRegistry
    var body: some View {
        if registry.modules.contains(where: { ModuleSettingsPanels.hasPanel($0.id) }) {
            ForEach(registry.modules) { m in
                if let panel = ModuleSettingsPanels.byID[m.id] { panel() }
            }
        } else {
            Text("No module settings yet.").foregroundStyle(.secondary).padding()
        }
    }
}
```

Add the scene to `MacIslandApp.body` (after the `MenuBarExtra`):

```swift
Settings {
    if let registry = delegate.moduleRegistry {
        ModulesSettingsView(registry: registry)
    }
}
```

**Step 2: Wire the row button** — in `ModulesMenu.moduleRow`, when the module has a panel show a "Settings…" button that opens the window:

```swift
if ModuleSettingsPanels.hasPanel(module.id) {
    Button("Settings…") { openSettings() }
}
```

(With the empty v1 registry this never renders — the hook is present and reachable the moment a panel is added.)

**Step 3: Build + run** — `swift build`, `swift run MacIslandApp`. Confirm the app still boots and no "Settings…" button appears (empty registry). Optional smoke test: temporarily add a dummy panel entry, confirm the button appears and ⌘,/click opens the window, then revert.

**Step 4: Commit**

```bash
git add Sources/MacIslandApp/ModuleSettings.swift Sources/MacIslandApp/MacIslandApp.swift
git commit -m "feat(app): wire opt-in module Settings-window hook (empty in v1)"
```

---

### Task 10: Document the module contract (`DEVELOPING.md`)

**Files:**
- Modify: `docs/DEVELOPING.md` (add an "Adding a module" section after "In-process sources (Swift)")

**Step 1: Write the section** — cover: what a `Module` is (a value, not a protocol; wraps a source), the trivial vs rich forms (with the two code snippets from the design doc), `ModuleStatus`/`ModuleAction`, why `activate()` is a fresh-instance recipe (no resume), how to register (`registry.add(…)` in boot), toggle behaviour (off sweeps, on rebuilds, persisted), and the opt-in `ModuleSettingsPanels` entry for a settings screen. Note that external JSON-ingress producers aren't modules (they appear read-only in the "Connected" strip).

**Step 2: Verify** — re-read the section; confirm code samples match the shipped signatures (`Module`, `ActiveModule`, `ModuleAction`, `ModuleRegistry.add`).

**Step 3: Commit**

```bash
git add docs/DEVELOPING.md
git commit -m "docs: document the Module contract for third-party authors"
```

---

## Final verification

- `swift build` — clean.
- `swift test` — full suite green (Core module tests + no regressions).
- `swift run MacIslandApp` — ✨ dropdown lists Calendar + GitHub with status + toggles; disabling GitHub sweeps its cards; "Connect Calendar…" works; a `macisland notify --source ci` shows in the Connected strip; app is idle-quiescent (no new timers).
- Confirm `NotificationSource` (`Sources/MacIslandCore/SourceContract.swift`) is unchanged.
