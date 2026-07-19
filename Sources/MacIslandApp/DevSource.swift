import MacIslandCore

/// A built-in demo source so the walking skeleton is demoable out of the box: on
/// `start` it posts one sticky card at the notch (ticket criterion 2 — "a card
/// posted by the dev source appears at the notch … clicking its ✕ removes it").
///
/// Sticky, not transient, so it stays put for the demo instead of auto-dismissing.
/// A plain value `struct` — the ~5-line hello-world floor of the source API (`id` +
/// `start`); every other `NotificationSource` method keeps its default no-op.
struct DevSource: NotificationSource {
    let id = SourceID(raw: "dev")

    func start(_ handle: SourceHandle) async throws {
        // `start` runs off the main actor (spec §8.6); the handle is `@MainActor`, so
        // hop onto it to post — the same one-way trip a real source's callbacks make.
        await MainActor.run {
            handle.post(
                Content(
                    title: "macIsland is live",
                    body: "This is a dev card — click ✕ to dismiss.",
                    icon: .symbol("sparkles")
                ),
                value: "welcome",
                presence: .sticky
            )
        }
    }
}
