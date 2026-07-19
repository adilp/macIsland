import SwiftUI
import AppKit
import MacIslandCore

/// macIsland — the single-process, `LSUIElement` menu-bar agent. A resident
/// notch-pinned `NSPanel` hosts the SwiftUI island; a `MenuBarExtra` gives the one
/// affordance (Quit); the core is wired to a dev source so the walking skeleton is
/// demoable. No Dock icon (activation policy `.accessory`), one instance at a time
/// (unified spec §8.4).
@main
struct MacIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Boot step 2: the menu-bar item. Quit is the only entry for v1; launch-at-login
        // and "Connect Calendar…" are deferred (unified spec §9). Exits cleanly.
        MenuBarExtra("macIsland", systemImage: "sparkles") {
            Button("Quit macIsland") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

/// The boot sequence and lifetime owner. `applicationDidFinishLaunching` runs the
/// fixed order from unified spec §8.4: single-instance check → agent policy → core →
/// panel → registry + dev source. (Alerter, Calendar, and the ingress host land in
/// their own tickets.)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var instanceGuard: SingleInstanceGuard?
    private var core: IslandCore?
    private var panelController: PanelController?
    private var ingressHost: IngressHost?

    func applicationDidFinishLaunching(_ notification: Foundation.Notification) {
        // Single instance: acquire the lock before doing anything; a second instance
        // exits immediately (covers a Finder relaunch as well as terminal launches).
        createAppSupportDirectory()
        guard let acquired = SingleInstanceGuard(path: SingleInstanceGuard.defaultPath()) else {
            NSApp.terminate(nil)
            return
        }
        instanceGuard = acquired

        // Agent posture at runtime: a menu-bar-only app, no Dock icon, never the
        // active app (the panel is a router, not a foreground window). This is the
        // runtime equivalent of the `LSUIElement` / `LSMultipleInstancesProhibited`
        // Info.plist keys, which only take effect once the app ships as a `.app`
        // bundle — a packaging step deferred with repo layout (unified spec §9).
        NSApp.setActivationPolicy(.accessory)

        // The core hosts the panel, registry, and Alerter. Its clock and Alerter are
        // built explicitly so the ring timeout shares the core's timeline and the
        // Alerter uses real macOS system sounds (unified spec §8.1 / §8.4 step 3).
        let clock = SystemClock()
        let alerter = Alerter(audio: SystemAudioOutput(), clock: clock)   // step 3: the sound layer
        let core = IslandCore(clock: clock, alerter: alerter)
        self.core = core
        self.panelController = PanelController(core: core)   // step 1: panel → idle pill
        core.register(DevSource())                           // step 4: registry + dev source

        // Step 4 (cont.): the built-in Calendar source — one launch-lifetime source
        // registered after the panel exists (unified spec §8.4 / §5). It shares the
        // core's clock so its meeting timers and the ring timeout live on one timeline;
        // EventKit access is auto-requested on first launch and it stays inert if denied
        // (Calendar spec §2). `EventKitStore` is the real EventKit seam.
        core.register(CalendarSource(store: EventKitStore(), clock: clock))

        // Step 5 (last): the local JSON ingress. Bind the UDS and start accepting only
        // now that the core can render — each connection mints a SocketSource (unified
        // spec §8.4). A bind failure is logged, not fatal: the GUI still runs.
        let host = IngressHost(core: core)
        do {
            try host.start()
            self.ingressHost = host
        } catch {
            Log.lifecycle.error("ingress host failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    /// Clean shutdown (unified spec §8.4): stop accepting and unlink the socket file.
    /// The single-instance lock is released by `SingleInstanceGuard`'s own teardown.
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
