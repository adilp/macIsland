import AppKit

/// The resident, borderless, non-activating panel that hosts the SwiftUI island —
/// verbatim to the notch/window spec §2. A `NSPanel` (not a plain `NSWindow`)
/// because only a panel gets `.nonactivatingPanel`, the flag that lets us show and
/// click island content without activating macIsland or deactivating the frontmost
/// app. The island is a router, never a focus thief: it can never become key or main.
final class IslandPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        // Chrome-free transparent surface — only the drawn island content shows.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                       // the island draws its own shadow if any

        // Float at/under the notch and OVER full-screen apps, but below Control
        // Center popovers. `.statusBar` sits just above `.mainMenu`.
        level = .statusBar

        collectionBehavior = [
            .canJoinAllSpaces,                  // present on every Space
            .fullScreenAuxiliary,               // show over another app's full-screen space
            .stationary,                        // unaffected by Mission Control / Exposé
            .ignoresCycle                       // excluded from Cmd-` window cycling
        ]

        // Router, never focus-thief: stay visible even though we're almost never the
        // frontmost app, and never move.
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = false              // content is clickable; empty margins pass through via hit-testing
    }

    // We route actions and take no text input → never steal key/main focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
