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
/// "disabled" out here (rather than folding it into `ModuleStatus`) keeps the module's own
/// health vocabulary about *health*, not toggle state.
public enum ModuleDisplayStatus: Equatable, Sendable {
    case disabled
    case live(ModuleStatus)
}

/// A labeled affordance that isn't a settings panel — a name plus work to do (e.g.
/// "Connect Calendar…"). The App renders each as a button. Anything needing a real form
/// is the opt-in App-side panel instead, not a `ModuleAction`. The work is `@MainActor`
/// because it typically pokes a `@MainActor` source (e.g. `CalendarSource.requestAccess()`).
@MainActor
public struct ModuleAction: Identifiable {
    public let id = UUID()
    public let label: String
    private let work: @MainActor () async -> Void

    public init(_ label: String, run: @escaping @MainActor () async -> Void) {
        self.label = label
        self.work = run
    }

    public func perform() async { await work() }
}

/// A live, switched-on module: the fresh source bundled with health/actions bound to
/// *that* instance. Produced by `Module.activate()` on each enable, dropped on disable.
/// Bundling is the trick that lets `status`/`actions` read the concrete source's own
/// state (which the dumb `NotificationSource` doesn't expose) without downcasting or
/// stale capture — the closures close over the instance built alongside them.
@MainActor
public struct ActiveModule {
    public let source: any NotificationSource
    public let status: @MainActor () -> ModuleStatus
    public let actions: [ModuleAction]

    public init(source: any NotificationSource,
                status: @escaping @MainActor () -> ModuleStatus = { .ok },
                actions: [ModuleAction] = []) {
        self.source = source
        self.status = status
        self.actions = actions
    }
}

/// The user-facing description of an integration — a **value you construct**, not a
/// protocol you conform to (design: "protocol vs wrapper → wrapper"). It composes over an
/// untouched `NotificationSource`. Not "metadata + a live source" but "metadata + a
/// recipe": `activate()` rebuilds a fresh source on every enable, because stateful sources
/// can't be resumed after `stop()`.
@MainActor
public struct Module: Identifiable {
    public let id: SourceID
    public let displayName: String
    public let icon: Icon
    /// Build a fresh live instance + its bound status/actions. Called on each enable.
    public let activate: @MainActor () -> ActiveModule

    /// Rich form: build the source and bind its status/actions together, with the concrete
    /// source type in scope (so `status` can read e.g. `src.authorizationStatus`).
    public init(id: SourceID, displayName: String, icon: Icon,
                activate: @escaping @MainActor () -> ActiveModule) {
        self.id = id
        self.displayName = displayName
        self.icon = icon
        self.activate = activate
    }

    /// Trivial form — the zero-screen-code common case: just a source. Health defaults to
    /// `.ok`, no actions. A module in ~5 lines.
    public init(id: SourceID, displayName: String, icon: Icon,
                makeSource: @escaping @MainActor () -> any NotificationSource) {
        self.init(id: id, displayName: displayName, icon: icon,
                  activate: { ActiveModule(source: makeSource()) })
    }
}
