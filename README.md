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
- `Sources/MacIslandApp` — the `LSUIElement` menu-bar agent (notch panel + boot sequence).
- `Sources/MacIslandCLI` — the `macisland` command, thin sugar over the ingress socket.
- `Tests/MacIslandCoreTests` — headless tests at the `SourceHandle` / `NotificationSource` and in-memory
  `Connection` seams.

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
```

_This README is a minimal orientation stub — the full README shape is deliberately deferred (see the build spec's
Out of Scope)._
