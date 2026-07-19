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

        // Boot step 3–4 (steps 1–2 below): the core, then the panel that shows the
        // idle pill, then the registry with a dev source that posts the demo card.
        let core = IslandCore(clock: SystemClock())
        self.core = core
        self.panelController = PanelController(core: core)   // step 1: panel → idle pill
        core.register(DevSource())                           // step 4: registry + dev source
    }

    /// Ensure macIsland's Application Support directory exists so the lock file (and,
    /// later, the ingress socket) can be created there.
    private func createAppSupportDirectory() {
        try? FileManager.default.createDirectory(
            at: AppSupport.directory, withIntermediateDirectories: true
        )
    }
}
