import Foundation
import Combine

/// The Modules manager: owns the module definitions, remembers on/off across launches
/// (via the injected `ModuleStore`), and drives `IslandCore` registration. The one place
/// the two-object source contract meets user-facing module state. `@MainActor` like the
/// core it drives; headless-testable with a `TestClock` core + `InMemoryModuleStore`.
///
/// It does **no** background work — no timers, no polling. Status is pulled on demand (the
/// menu reads it on open), so it's quiescent at idle by construction (`PERFORMANCE.md`).
///
/// `ObservableObject` only so the menu re-renders when the *set* of live modules changes
/// (a toggle, or a `reload` after a settings save) — health itself is still pulled on read,
/// never pushed, so this adds no background work.
@MainActor
public final class ModuleRegistry: ObservableObject {
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
        objectWillChange.send()
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

    /// Rebuild an *enabled* module's live source from scratch — the same teardown as a
    /// disable-then-enable, but without touching the persisted on/off. For a module whose
    /// configuration changed under it (e.g. a new repo entered in Settings): `activate()`
    /// re-reads that config, so the fresh source watches the new target. No-op if the
    /// module is unknown or currently disabled (a disabled module rebuilds on next enable).
    public func reload(_ id: SourceID) async {
        guard let module = defined.first(where: { $0.id == id }), active[id] != nil else { return }
        objectWillChange.send()
        active[id] = nil
        await core.unregister(id, revokingCards: true)
        enable(module)
    }

    /// The per-row display status: ⚪ when off, else the live source's own 🟢/🟡.
    public func status(of id: SourceID) -> ModuleDisplayStatus {
        guard let a = active[id] else { return .disabled }
        return .live(a.status())
    }

    /// The live actions for a row (empty when disabled) — the App renders each as a button.
    /// Re-read on demand so a status-dependent action (e.g. "Connect…") appears/disappears.
    public func actions(of id: SourceID) -> [ModuleAction] { active[id]?.actions() ?? [] }

    private func enable(_ module: Module) {
        let a = module.activate()
        active[module.id] = a
        core.register(a.source)
    }
}
