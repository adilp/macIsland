// macIsland core — the dependency-free heart of the notch dynamic-island notifier.
//
// Apple frameworks only; zero third-party runtime dependencies (build spec's
// dependency rule). The domain model, stack controller, source contract,
// registry, `Alerter`, and panel/geometry all live in this one module — a small
// codebase a forker can read whole.
//
// Landed so far (pure/headless — no UI, verified at the `SourceHandle` seam):
//   • Domain model & stack-ordering — `Notification` and its `Content` / `Icon` /
//     `ImageSource` / `Presence` / `Alerting` / `Action` / `ActionBehavior` /
//     `SourceID` / `NotificationID` value types (all `Codable`/`Sendable`,
//     illegal-state-proofed) + `NotificationStack` (two-tier sticky > transient,
//     newest-first, update-in-place holding `receivedAt`, revoke/dismiss).
//   • Core stack controller + source contract — `IslandCore` (the `@MainActor`
//     heart: registry, post/upsert/revoke, transient auto-dismiss via the injected
//     `Clock` with hover-pause, action routing, four-`CloseReason` reporting,
//     uniform teardown + source-fault containment, plus an `onChange` render signal)
//     driving the two contract objects `SourceHandle` (push; stamps the source id) +
//     `NotificationSource`, over an injected `Clock` (`SystemClock` in production)
//     with `os.Logger` diagnostics.
//   • Walking-skeleton foundations — the pure, headless-testable pieces the notch
//     app is built on: `NotchGeometry` (`ScreenMetrics` + `anchorFrame` +
//     `targetScreenIndex`; top-pinned, grow-downward, 72% cap, notched-else-built-in)
//     and `SingleInstanceGuard` (flock-based one-instance lock). The AppKit/SwiftUI
//     GUI that consumes them (`IslandPanel`, the island views, boot ordering) lives
//     in the `MacIslandApp` executable target, keeping this module display-free and
//     unit-testable.
//
// Later tickets add the `Alerter`, the full "Calm sheet" interaction, the ingress,
// and the Calendar source — all atop this model.
//
// (No module-namespace enum on purpose: a type named `MacIslandCore` would shadow
// the module name and break `MacIslandCore.Notification` qualification.)
