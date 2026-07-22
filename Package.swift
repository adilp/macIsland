// swift-tools-version: 6.0
import PackageDescription

// macIsland — a light, dependency-free macOS notch dynamic-island notifier.
// Developer & extension guide: docs/DEVELOPING.md

let package = Package(
    name: "macIsland",
    platforms: [
        // min macOS 14 (Sonoma) — set by EventKit's modern full-access API (spec §8.2).
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacIslandCore", targets: ["MacIslandCore"]),
        // A GitHub CI/CD deploy-activity source. Its own library (not folded into the
        // core) so MacIslandCore stays network-free / Apple-only, while the source
        // remains headless-testable at the NotificationSource seam.
        .library(name: "MacIslandGitHub", targets: ["MacIslandGitHub"]),
        .executable(name: "MacIslandApp", targets: ["MacIslandApp"]),
        // The `macisland` CLI — thin sugar over the ingress socket (spec §9). Lowercase
        // product name to avoid a case-only clash with the MacIsland* dirs on a
        // case-insensitive filesystem.
        .executable(name: "macisland", targets: ["MacIslandCLI"])
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
        // The GitHub CI/CD source: polls GitHub Actions for deploy runs and maps them
        // onto pill *activities* (running) and sticky ringing cards (failure). Owns its
        // own network (URLSession) and token acquisition (`gh auth token`) — the core
        // does no network, sources fetch themselves. Depends only on the core's domain
        // model + NotificationSource seam.
        .target(
            name: "MacIslandGitHub",
            dependencies: ["MacIslandCore"]
        ),

        .executableTarget(
            name: "MacIslandApp",
            dependencies: ["MacIslandCore", "MacIslandGitHub"]
        ),

        // Headless tests, driven at the SourceHandle / NotificationSource seam with an
        // injected Clock, plus the pure geometry/guard seams (see the build spec's
        // Testing Decisions).
        .testTarget(
            name: "MacIslandCoreTests",
            dependencies: ["MacIslandCore"]
        ),

        // Headless tests for the GitHub source, driven with a scripted fake client and
        // an injected TestClock — no network, no real `gh`, no wall-clock waits.
        .testTarget(
            name: "MacIslandGitHubTests",
            dependencies: ["MacIslandGitHub"]
        ),

        // The `macisland` CLI: a thin POSIX client that translates each subcommand
        // (notify/revoke/listen) into the JSONL wire protocol over the ingress socket
        // (spec §9). Reuses the core's socket-path resolution, UnixSocket, and wire
        // vocabulary — never a second mechanism.
        .executableTarget(
            name: "MacIslandCLI",
            dependencies: ["MacIslandCore"]
        )
    ]
)
