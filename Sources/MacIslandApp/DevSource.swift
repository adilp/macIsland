import MacIslandCore

/// A built-in demo source so the island is demoable out of the box. It posts a small
/// spread that exercises the Calm sheet: one **sticky** card pinned at the top and a
/// couple of **transient** cards below it, so a run shows the two tiers and their
/// hairline divider, the spring reflow as cards stack, the thin countdown bars, and
/// the hover-reveal ✕ / countdown freeze (stacking-interaction spec §1–§6).
///
/// The transient lifetimes are long (not the ≈5s default) so there's time to hover
/// and watch a bar freeze before it expires. A plain value `struct` — the ~5-line
/// hello-world floor of the source API (`id` + `start`), every other method a no-op.
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
                presence: .sticky
            )
            handle.post(
                Content(
                    title: "Build finished",
                    body: "A transient toast — watch its countdown bar deplete.",
                    icon: .symbol("hammer.fill")
                ),
                value: "build",
                presence: .transient(after: .seconds(30))
            )
            handle.post(
                Content(
                    title: "New message",
                    body: "Hover the island to freeze every countdown at once.",
                    icon: .symbol("message.fill")
                ),
                value: "message",
                presence: .transient(after: .seconds(45))
            )
        }
    }
}
