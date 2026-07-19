import XCTest
@testable import MacIslandCore

/// `Notification` collides with `Foundation.Notification` (via XCTest); pin the bare
/// name to our value type for readable type-position use.
private typealias Notification = MacIslandCore.Notification

/// Tests for the **Actions** ticket — up to two action buttons plus the always-present
/// dismiss, `openURL` core-run vs `callback` routed, dismiss-vs-act, and the orphan
/// policy. Driven entirely at the `SourceHandle`/`IslandCore` seam (no panel); the
/// button *rendering* is build-verified in the app target. Complements the routing
/// cases already in `IslandCoreTests` "Criterion 5" with the behaviors those don't
/// cover: `dismissOnTap:false` keep-and-update, source-liveness for disabling orphaned
/// callbacks, `openURL` surviving a dead source, and the 0…2 action cap.
@MainActor
final class ActionsTests: XCTestCase {

    private func id(_ source: String, _ value: String) -> NotificationID {
        NotificationID(source: SourceID(raw: source), value: value)
    }

    private func orderedIDs(_ core: IslandCore) -> [String] {
        core.ordered.map(\.id.value)
    }

    // MARK: - Criterion 1: the 0…2 action cap ("up to two buttons")

    func test_post_rejectsMoreThanTwoActions() {
        let core = IslandCore(clock: TestClock())
        let handle = core.register(SpySource("dev"))!
        let tooMany = Notification(
            id: id("dev", "1"),
            content: Content(title: "Overloaded"),
            actions: [
                Action(label: "One", behavior: .callback("a")),
                Action(label: "Two", behavior: .callback("b")),
                Action(label: "Three", behavior: .callback("c")),
            ],
            presence: .sticky
        )
        handle.post(tooMany)
        XCTAssertEqual(orderedIDs(core), [], "a card exceeding the 0…2 action cap is rejected at post")
    }

    func test_post_acceptsExactlyTwoActions() {
        let core = IslandCore(clock: TestClock())
        let handle = core.register(SpySource("dev"))!
        let two = Notification(
            id: id("dev", "1"),
            content: Content(title: "Two actions"),
            actions: [
                Action(label: "One", behavior: .callback("a")),
                Action(label: "Two", behavior: .openURL(URL(string: "https://example.com")!)),
            ],
            presence: .sticky
        )
        handle.post(two)
        XCTAssertEqual(orderedIDs(core), ["1"], "a two-action card is accepted, not rejected")
        XCTAssertEqual(core.ordered.first?.notification.actions.count, 2, "two actions is the max, and allowed")
    }

    // MARK: - Criterion 2: a dismissOnTap:false callback keeps the card for in-place update

    func test_callbackAction_dismissOnTapFalse_keepsCardForInPlaceUpdate() async {
        let core = IslandCore(clock: TestClock())
        let spy = SpySource("dev")
        let handle = core.register(spy)!
        let snooze = Notification(
            id: id("dev", "1"),
            content: Content(title: "Meeting soon"),
            actions: [Action(label: "Snooze", behavior: .callback("snooze"), dismissOnTap: false)],
            presence: .sticky
        )
        handle.post(snooze)

        await core.fireAction(id("dev", "1"), at: 0)

        // The tap routed to the source, but the card is NOT dismissed and NOT reported
        // closed — it stays so the source can update it in place.
        XCTAssertEqual(spy.actions.map { "\($0.value):\($0.actionID)" }, ["1:snooze"])
        XCTAssertEqual(spy.closed.map(\.reason), [], "dismissOnTap:false must not report .acted")
        XCTAssertEqual(orderedIDs(core), ["1"], "dismissOnTap:false keeps the card")

        // The source updates in place (same id, full replace) — the card holds position.
        handle.post(
            Content(title: "Snoozed 5 min"),
            value: "1",
            presence: .sticky
        )
        XCTAssertEqual(orderedIDs(core), ["1"], "still one card after the in-place update")
        XCTAssertEqual(core.ordered.first?.notification.content.title, "Snoozed 5 min",
                       "the update replaced the content in place")

        // A kept-alive card still terminates through the normal reasons: revoking it
        // reports `.revoked` (not `.acted`), proving the earlier tap didn't leave it in
        // a half-closed state.
        handle.revoke("1")
        await spy.awaitClosed(count: 1)
        XCTAssertEqual(spy.closed.map(\.reason), [.revoked],
                       "the keep-alive card closes via its eventual revoke, once, as .revoked")
        XCTAssertEqual(orderedIDs(core), [])
    }

    // MARK: - Criterion 3: orphan policy — liveness disables callbacks, openURL survives

    func test_liveSourceIDs_dropsASourceOnceTornDown_whileItsCardsRemain() async {
        let core = IslandCore(clock: TestClock())
        let dev = core.register(SpySource("dev"))!
        let keep = core.register(SpySource("keep"))!
        dev.post(Content(title: "orphan me"), value: "1", presence: .sticky)
        keep.post(Content(title: "stay live"), value: "1", presence: .sticky)

        XCTAssertTrue(core.liveSourceIDs.contains(SourceID(raw: "dev")))
        XCTAssertTrue(core.liveSourceIDs.contains(SourceID(raw: "keep")))

        // Tear down "dev": default orphan policy leaves its card, but the source is gone,
        // so the panel must be able to see it's no longer live (to disable its callbacks).
        await core.unregister(SourceID(raw: "dev"))

        XCTAssertFalse(core.liveSourceIDs.contains(SourceID(raw: "dev")),
                       "a torn-down source is no longer live, so its callback buttons disable")
        XCTAssertTrue(core.liveSourceIDs.contains(SourceID(raw: "keep")),
                      "the surviving source stays live")
        XCTAssertEqual(orderedIDs(core).sorted(), ["1", "1"],
                       "leave-cards: the orphaned card remains visible alongside the live one")
    }

    func test_orphanedOpenURLAction_stillFires_afterSourceTornDown() async {
        let opener = OpenSpy()
        let core = IslandCore(clock: TestClock(), openURL: opener.open)
        let spy = SpySource("dev")
        let dev = core.register(spy)!
        let url = URL(string: "https://example.com/logs")!
        dev.post(
            Notification(
                id: id("dev", "1"),
                content: Content(title: "Build failed"),
                actions: [Action(label: "View logs", behavior: .openURL(url))],
                presence: .sticky
            )
        )

        // Source goes away; its card is left in place (default orphan policy).
        await core.unregister(SourceID(raw: "dev"))
        XCTAssertEqual(orderedIDs(core), ["1"], "the orphaned card remains")

        // The core-run openURL action keeps working even though the source is gone.
        await core.fireAction(id("dev", "1"), at: 0)
        XCTAssertEqual(opener.opened, [url], "openURL is core-run and survives a dead source")
        XCTAssertEqual(orderedIDs(core), [], "firing it still dismisses the orphaned card by default")
        // Pinned interaction of two spec rules: an openURL tap normally reports
        // `.acted`, but on an *orphaned* card there is no live source to tell — so no
        // `.acted` lands. (The spy is torn down; its onClosed is never invoked.)
        XCTAssertEqual(spy.closed.map(\.reason), [], "no .acted reported to a source that is already gone")
    }

    func test_orphanedCallbackAction_isASafeNoOp_afterSourceTornDown() async {
        let core = IslandCore(clock: TestClock())
        let spy = SpySource("dev")
        let handle = core.register(spy)!
        handle.post(
            Notification(
                id: id("dev", "1"),
                content: Content(title: "Approve?"),
                actions: [Action(label: "Approve", behavior: .callback("approve"), dismissOnTap: false)],
                presence: .sticky
            )
        )
        await core.unregister(SourceID(raw: "dev"))

        // Firing a callback whose source is gone must not crash or route anywhere — the
        // panel disables such buttons, but the core is defensively a no-op regardless.
        await core.fireAction(id("dev", "1"), at: 0)
        XCTAssertEqual(spy.actions.count, 0, "a callback into a dead source routes nowhere")
        // The card staying here is `dismissOnTap:false` (incidental to the no-op claim):
        // an orphaned `dismissOnTap:true` callback would likewise not route, yet would
        // still dismiss — the dismiss branch runs regardless of whether a source was found.
        XCTAssertEqual(orderedIDs(core), ["1"], "dismissOnTap:false leaves the orphaned card in place")
    }
}
