import SwiftUI
import AppKit
import MacIslandCore
import MacIslandGitHub

/// macIsland — the single-process, `LSUIElement` menu-bar agent. A resident
/// notch-pinned `NSPanel` hosts the SwiftUI island; a `MenuBarExtra` gives the settings
/// surface (the Modules list + Quit); the core is wired to a dev source so the walking
/// skeleton is demoable. No Dock icon (activation policy `.accessory`), one instance at a
/// time (unified spec §8.4).
@main
struct MacIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Boot step 2: the menu-bar item. Its content is a `View` that observes the delegate
        // so it flips from a bare Quit to the full Modules list the instant boot publishes
        // the registry (a `Scene` content builder wouldn't — see `MenuBarContent`). A
        // `.window` style gives us real toggle/status rows, not plain menu items.
        MenuBarExtra("macIsland", systemImage: "sparkles") {
            MenuBarContent(delegate: delegate)
        }
        .menuBarExtraStyle(.window)

        // The opt-in per-module settings surface (design: rich config panels open in a real
        // Settings window, roomier than the dropdown). Empty in v1 — the built-ins need only
        // buttons — so the hook ships and the first module with a panel just slots in.
        Settings {
            SettingsContent(delegate: delegate)
        }
    }
}

/// The menu-bar dropdown's content. It takes the delegate as an `@ObservedObject` — not the
/// `@NSApplicationDelegateAdaptor` value read straight in the `Scene` — because a `Scene`'s
/// content builder evaluates once and won't re-read the delegate's `@Published` optionals,
/// whereas an `@ObservedObject` `View` re-renders on publish. So this flips to the Modules
/// list the moment boot sets the registry, instead of staying stuck on the bootstrap Quit.
private struct MenuBarContent: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        if let registry = delegate.moduleRegistry, let core = delegate.islandCore {
            ModulesMenu(registry: registry, core: core)
        } else {
            Button("Quit macIsland") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

/// The Settings window content — same observation reasoning as `MenuBarContent`.
private struct SettingsContent: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        if let registry = delegate.moduleRegistry {
            ModulesSettingsView(registry: registry)
        }
    }
}

/// The boot sequence and lifetime owner. `applicationDidFinishLaunching` runs the fixed
/// order from unified spec §8.4: single-instance check → agent policy → core → panel →
/// registry + dev source → modules → ingress. An `ObservableObject` so the `MenuBarExtra`
/// picks up the `ModuleRegistry` the instant boot finishes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var instanceGuard: SingleInstanceGuard?
    private var panelController: PanelController?
    private var ingressHost: IngressHost?

    /// Published so the menu-bar scene re-renders into the Modules list once boot wires
    /// them. Nil until `applicationDidFinishLaunching` completes.
    @Published var islandCore: IslandCore?
    @Published var moduleRegistry: ModuleRegistry?

    func applicationDidFinishLaunching(_ notification: Foundation.Notification) {
        // Migrate any values written to the old `.standard` / named-suite domains before
        // anything reads from them — this must be the very first settings-touching call.
        AppDefaults.migrateLegacyDomains()

        // Single instance: acquire the lock before doing anything; a second instance
        // exits immediately (covers a Finder relaunch as well as terminal launches).
        createAppSupportDirectory()
        guard let acquired = SingleInstanceGuard(path: SingleInstanceGuard.defaultPath()) else {
            NSApp.terminate(nil)
            return
        }
        instanceGuard = acquired

        // Agent posture at runtime: a menu-bar-only app, no Dock icon, never the active
        // app (the panel is a router, not a foreground window). Runtime equivalent of the
        // `LSUIElement` Info.plist keys, which only take effect once the app ships as a
        // `.app` bundle — a packaging step deferred with repo layout (unified spec §9).
        NSApp.setActivationPolicy(.accessory)

        // The core hosts the panel, registry, and Alerter. Its clock and Alerter are built
        // explicitly so the ring timeout shares the core's timeline and the Alerter uses
        // real macOS system sounds (unified spec §8.1 / §8.4 step 3).
        let clock = SystemClock()
        let alerter = Alerter(audio: SystemAudioOutput(), clock: clock)   // step 3: the sound layer
        let core = IslandCore(clock: clock, alerter: alerter)
        self.islandCore = core
        self.panelController = PanelController(core: core)   // step 1: panel → idle pill
        core.register(DevSource())                           // step 4: registry + dev source

        // Step 4 (cont.): the built-in modules. Both were previously hand-registered here;
        // now they go through the `ModuleRegistry` so the menu can show status + toggle
        // them and their on/off survives launches. Each `Module` is a *recipe* that rebuilds
        // a fresh source on enable and binds its status (and any action) to that instance.
        let registry = ModuleRegistry(core: core, store: UserDefaultsModuleStore(defaults: AppDefaults.shared))
        registry.add(Self.calendarModule(clock: clock))
        registry.add(Self.githubModule(clock: clock))
        registry.start()
        self.moduleRegistry = registry

        // Step 5 (last): the local JSON ingress. Bind the UDS and start accepting only now
        // that the core can render — each connection mints a SocketSource (unified spec
        // §8.4). A bind failure is logged, not fatal: the GUI still runs.
        let host = IngressHost(core: core)
        do {
            try host.start()
            self.ingressHost = host
        } catch {
            Log.lifecycle.error("ingress host failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Built-in module definitions

    /// The Calendar module: a fresh `CalendarSource` per enable, health from EventKit
    /// authorization, and a "Connect Calendar…" action driving the same grant path as
    /// first-run. EventKit access is process-global, so a fresh instance can request it.
    private static func calendarModule(clock: any Clock) -> Module {
        Module(id: SourceID(raw: "calendar"), displayName: "Calendar", icon: .symbol("calendar")) {
            let src = CalendarSource(store: EventKitStore(), clock: clock)
            return ActiveModule(
                source: src,
                status: { src.authorizationStatus == .authorized ? .ok : .needsAttention("Not connected") },
                // The Connect affordance only makes sense until access is granted — once
                // authorized it's a dead button, so it disappears and the light shows OK.
                actions: {
                    src.authorizationStatus == .authorized
                        ? []
                        : [ModuleAction("Connect Calendar…") { _ = await src.requestAccess() }]
                }
            )
        }
    }

    /// The GitHub CI/CD module: watches the repo the user points it at (via the Settings
    /// panel — `GitHubSettingsView`) and maps the source's native `Status` onto the shared
    /// `ModuleStatus`. Config is read fresh on every `activate()`, so saving a repo and
    /// calling `registry.reload` rebuilds the source against it. Until a repo is set the
    /// module parks: a do-nothing source and a "set a repository" prompt, never polling.
    private static func githubModule(clock: any Clock) -> Module {
        Module(id: SourceID(raw: "github"), displayName: "GitHub CI/CD",
               icon: .symbol("shippingbox.fill")) {
            guard let config = UserDefaultsGitHubConfigStore(defaults: AppDefaults.shared).load() else {
                // Unconfigured → park on the id (so the row still shows) and point the user
                // at Settings. No client is built, so nothing is polled.
                return ActiveModule(
                    source: ParkedSource(id: SourceID(raw: "github")),
                    status: { .needsAttention("Set a repository in Settings…") }
                )
            }
            let src = GitHubActionsSource(
                client: GitHubDeployClient(config: config),
                clock: clock,
                nudgeFile: AppSupport.directory.appendingPathComponent("github.poke")
            )
            return ActiveModule(source: src, status: {
                switch src.status {
                case .starting, .ok:    return .ok
                case .needsAuth(let r): return .needsAttention(r)
                case .error(let e):     return .needsAttention(e)
                }
            })
        }
    }

    /// Clean shutdown (unified spec §8.4): stop accepting and unlink the socket file. The
    /// single-instance lock is released by `SingleInstanceGuard`'s own teardown.
    func applicationWillTerminate(_ notification: Foundation.Notification) {
        ingressHost?.stop()
    }

    /// Ensure macIsland's Application Support directory exists so the lock file and the
    /// ingress socket can be created there. Created `0700` (user-only) — the ingress
    /// socket's trust boundary is filesystem permissions alone (spec §8).
    private func createAppSupportDirectory() {
        try? FileManager.default.createDirectory(
            at: AppSupport.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
    }
}

/// A do-nothing source for a module that's registered but not yet configured (e.g. the
/// GitHub module before a repo is set). It occupies the module's id so the row still
/// renders with its status, while polling nothing. `start` returns immediately.
private struct ParkedSource: NotificationSource {
    let id: SourceID
    func start(_ handle: SourceHandle) async throws {}
}
