// swift-tools-version: 6.0
import PackageDescription

// macIsland — a light, dependency-free macOS notch dynamic-island notifier.
// Design source of truth: .scratch/macisland/assets/08-unified-design-architecture-spec.md
// Build backlog: tickets.md

let package = Package(
    name: "macIsland",
    platforms: [
        // min macOS 14 (Sonoma) — set by EventKit's modern full-access API (spec §8.2).
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacIslandCore", targets: ["MacIslandCore"]),
        .executable(name: "MacIslandApp", targets: ["MacIslandApp"])
    ],
    targets: [
        // The dependency-free, headless-testable core: the domain model, stack
        // controller, source contract (SourceHandle / NotificationSource), registry,
        // and the pure notch geometry + single-instance guard the app builds on.
        // Apple frameworks only — zero third-party runtime dependencies. (The AppKit/
        // SwiftUI GUI — panel, island views, boot — lives in MacIslandApp so this
        // target stays unit-testable without a display.)
        .target(name: "MacIslandCore"),

        // The LSUIElement menu-bar agent: the resident notch-pinned NSPanel hosting
        // the SwiftUI island, a MenuBarExtra (Quit), and the boot sequence that wires
        // the core to a dev source. GUI, so verified by build + run, not headless tests.
        .executableTarget(
            name: "MacIslandApp",
            dependencies: ["MacIslandCore"]
        ),

        // Headless tests, driven at the SourceHandle / NotificationSource seam with an
        // injected Clock, plus the pure geometry/guard seams (see the build spec's
        // Testing Decisions).
        .testTarget(
            name: "MacIslandCoreTests",
            dependencies: ["MacIslandCore"]
        )

        // Added by a later ticket:
        //   • MacIslandCLI — .executableTarget, product name `macisland` (avoids a
        //       case-only clash with the MacIsland* dirs on case-insensitive filesystems)
        //       → ticket "Local JSON ingress"
    ]
)
