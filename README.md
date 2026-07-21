# macIsland

A light, dependency-free, open-source macOS **dynamic-island notifier** — an always-resident pill at the notch
that unrolls downward into a per-row-dismissible **stack** of notification cards, fed by a built-in **Calendar**
source and a **local JSON ingress** any tool can write to. Notifications coexist (a second alert never erases the
first), sticky things stay pinned above transient toasts, and an imminent meeting rings with a one-click Join.

> **Status:** greenfield build. The design is locked; the work is sliced into tracer-bullet tickets.

## Where things are

- **Build backlog:** [`tickets.md`](tickets.md) — work the frontier one ticket at a time with `/implement`.
- **Design (source of truth):** [`.scratch/macisland/assets/08-unified-design-architecture-spec.md`](.scratch/macisland/assets/08-unified-design-architecture-spec.md) and the seven section-specs it links.
- **Build spec:** [`.scratch/macisland/issues/spec-build-macisland-v1.md`](.scratch/macisland/issues/spec-build-macisland-v1.md) (scope, user stories, test seams).

## Layout

- `Sources/MacIslandCore` — the dependency-free core (domain model, stack controller, source contract, registry,
  `Alerter`, panel/geometry, and the local JSON ingress: wire codec, `SocketSource`, `IngressHost`).
  **Apple frameworks only, zero third-party runtime dependencies.**
- `Sources/MacIslandGitHub` — the built-in GitHub CI/CD deploy source (its own library so the core stays
  network-free and the source stays headless-testable).
- `Sources/MacIslandApp` — the `LSUIElement` menu-bar agent (notch panel + boot sequence).
- `Sources/MacIslandCLI` — the `macisland` command, thin sugar over the ingress socket.
- `Tests/MacIslandCoreTests`, `Tests/MacIslandGitHubTests` — headless tests at the `SourceHandle` /
  `NotificationSource` and in-memory `Connection` seams.

## Developing & extending

**[`docs/DEVELOPING.md`](docs/DEVELOPING.md)** is the developer guide: how the targets fit together, the
domain model, and — the main event — how to **add your own source**. Everything that puts something on the
island is a `NotificationSource`; adding a feature means adding a source, in two flavors:

- **In-process (Swift):** conform to `NotificationSource` (floor: `id` + `start`), then `core.register(…)` at
  boot. Post live-updating cards and iOS-Live-Activity-style pill "peeks".
- **Out-of-process (any language):** push JSONL to the ingress socket (see below) — no Swift required.

## Performance

"Performant and light" is a gated goal, not a vibe: idle memory ceiling, a no-leak churn check, and the
quiescent-at-idle / snap-back invariants fail CI on regression. See [`PERFORMANCE.md`](PERFORMANCE.md) for the
budget, the automated gates, and the manual pre-release idle-quiescence procedure.

## Ingress — push a notification without writing Swift

Any tool can post over a Unix-domain socket (JSONL, both directions). The `macisland` CLI wraps it:

```sh
echo '{"title":"Build done"}' | macisland notify                 # fire-and-forget toast
macisland notify --source ci --wait < payload.json               # post, then stream the answer
macisland revoke pr-42 --source ci                               # or --all
```

`$MACISLAND_SOCK` overrides the socket path (default `~/Library/Application Support/macIsland/ingress.sock`).

## Build

Requires **macOS 14+ (Sonoma)**.

```sh
swift build
swift test
swift run MacIslandApp     # launch the menu-bar agent
```

See [`docs/DEVELOPING.md`](docs/DEVELOPING.md) to go further.
