import Foundation
import MacIslandCore

/// A built-in demo source so the island is demoable out of the box. It posts a small
/// spread that exercises the Calm sheet: one **sticky** card pinned at the top and a
/// couple of **transient** cards below it, so a run shows the two tiers and their
/// hairline divider, the spring reflow as cards stack, the thin countdown bars, the
/// hover-reveal ✕ / countdown freeze (stacking-interaction spec §1–§6), and — now —
/// **action buttons**: a core-run `openURL` and a routed `callback`, up to two per card.
///
/// The transient lifetimes are long (not the ≈5s default) so there's time to hover
/// and watch a bar freeze before it expires. A plain value `struct` — the ~5-line
/// hello-world floor of the source API (`id` + `start`), every other method a no-op
/// (a `callback` tap routes here to the default no-op `onAction`, then the card
/// dismisses — the visible half of action routing).
struct DevSource: NotificationSource {
    let id = SourceID(raw: "dev")

    func start(_ handle: SourceHandle) async throws {
        // `start` runs off the main actor (spec §8.6); the handle is `@MainActor`, so
        // hop onto it to post — the same one-way trip a real source's callbacks make.
        await MainActor.run {
            handle.post(
                Content(
                    title: "macIsland is live",
                    body: "Sticky card — hover to reveal ✕, then click to dismiss.",
                    icon: .symbol("sparkles")
                ),
                value: "welcome",
                actions: [
                    // A core-run openURL — opens end-to-end via NSWorkspace, no round-trip.
                    Action(label: "Open Repo", behavior: .openURL(URL(string: "https://github.com")!)),
                ],
                presence: .sticky
            )
            handle.post(
                Content(
                    title: "Build finished",
                    body: "A transient toast — watch its countdown bar deplete.",
                    icon: .symbol("hammer.fill")
                ),
                value: "build",
                actions: [
                    // Two actions — the display cap: an openURL and a routed callback.
                    Action(label: "View logs", behavior: .openURL(URL(string: "https://example.com/logs")!)),
                    Action(label: "Rerun", behavior: .callback("rerun")),
                ],
                presence: .transient(after: .seconds(30))
            )
            handle.post(
                Content(
                    title: "New message",
                    body: "Hover the island to freeze every countdown at once.",
                    icon: .symbol("message.fill")
                ),
                value: "message",
                actions: [
                    // A keep-and-update callback: firing it routes to onAction and leaves
                    // the card in place (dismissOnTap:false) for a source to update.
                    Action(label: "Reply", behavior: .callback("reply"), dismissOnTap: false),
                ],
                presence: .transient(after: .seconds(45))
            )
        }
    }
}
