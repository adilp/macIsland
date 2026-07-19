import XCTest
@testable import MacIslandCore

/// `Notification` collides with `Foundation.Notification` (via XCTest); pin the bare
/// name to our value type for readable type-position use.
private typealias Notification = MacIslandCore.Notification

/// Tests for `IslandCore` — the `@MainActor` stack controller + source contract.
/// Driven **entirely at the `SourceHandle` seam** with spy sources and a fake clock;
/// no panel. Each `MARK` block is one acceptance criterion of the ticket.
@MainActor
final class IslandCoreTests: XCTestCase {

    // MARK: - Fixtures

    private func card(_ source: String, _ value: String, _ presence: Presence = .sticky) -> Notification {
        Notification(
            id: NotificationID(source: SourceID(raw: source), value: value),
            content: Content(title: value),
            presence: presence
        )
    }

    private func orderedIDs(_ core: IslandCore) -> [(source: String, value: String)] {
        core.ordered.map { (source: $0.id.source.raw, value: $0.id.value) }
    }

    // MARK: - Criterion 1: register / post / revoke / revokeAll + id stamping

    func test_register_returnsHandle_andPostAppearsInOrderedStack() {
        let core = IslandCore(clock: TestClock())
        let handle = core.register(SpySource("dev"))
        XCTAssertNotNil(handle)

        handle?.post(Content(title: "Hello"), value: "1", presence: .sticky)

        XCTAssertEqual(orderedIDs(core).map(\.value), ["1"])
        XCTAssertEqual(core.ordered.first?.notification.content.title, "Hello")
        XCTAssertEqual(core.ordered.first?.id.source.raw, "dev")
    }

    func test_handleStampsSourceID_soCrossSourceAddressingIsImpossible() {
        let core = IslandCore(clock: TestClock())
        let handle = core.register(SpySource("A"))

        // A source for "A" tries to post a fully-formed notification claiming source
        // "B". The handle must overwrite the source with "A".
        handle?.post(card("B", "x"))

        XCTAssertEqual(orderedIDs(core).map(\.source), ["A"])
        XCTAssertEqual(core.ordered.first?.id.source.raw, "A")
    }

    func test_revoke_removesOnlyMyOwnCard_andIsIdempotent() {
        let core = IslandCore(clock: TestClock())
        let a = core.register(SpySource("A"))!
        let b = core.register(SpySource("B"))!
        a.post(Content(title: "a1"), value: "1", presence: .sticky)
        b.post(Content(title: "b1"), value: "1", presence: .sticky)

        // A revokes value "1" — its OWN card, not B's identically-valued card.
        a.revoke("1")
        XCTAssertEqual(orderedIDs(core).map { "\($0.source):\($0.value)" }, ["B:1"])

        // Idempotent: revoking again is a no-op.
        a.revoke("1")
        XCTAssertEqual(orderedIDs(core).map { "\($0.source):\($0.value)" }, ["B:1"])
    }

    func test_revokeAll_clearsOnlyThatSourcesCards() {
        let core = IslandCore(clock: TestClock())
        let a = core.register(SpySource("A"))!
        let b = core.register(SpySource("B"))!
        a.post(Content(title: "a1"), value: "1", presence: .sticky)
        a.post(Content(title: "a2"), value: "2", presence: .sticky)
        b.post(Content(title: "b1"), value: "1", presence: .sticky)

        a.revokeAll()

        XCTAssertEqual(orderedIDs(core).map { "\($0.source):\($0.value)" }, ["B:1"])
    }

    // MARK: - Criterion 2: transient auto-dismiss timers + hover-pause

    func test_transientCard_autoDismissesWhenClockAdvancesPastInterval() async {
        let clock = TestClock()
        let core = IslandCore(clock: clock)
        let spy = SpySource("dev")
        let handle = core.register(spy)!

        handle.post(Content(title: "toast"), value: "t", presence: .transient(after: .seconds(5)))
        XCTAssertEqual(orderedIDs(core).map(\.value), ["t"])

        // Just short of the interval: still there.
        await clock.advance(by: .seconds(4))
        XCTAssertEqual(orderedIDs(core).map(\.value), ["t"])

        // Past the interval: auto-dismissed, and reported .expired.
        await clock.advance(by: .seconds(2))
        XCTAssertEqual(orderedIDs(core).map(\.value), [])
        XCTAssertEqual(spy.closed.map(\.reason), [.expired])
    }

    func test_stickyCard_neverAutoDismisses() async {
        let clock = TestClock()
        let core = IslandCore(clock: clock)
        let handle = core.register(SpySource("dev"))!

        handle.post(Content(title: "pinned"), value: "s", presence: .sticky)
        await clock.advance(by: .seconds(10_000))

        XCTAssertEqual(orderedIDs(core).map(\.value), ["s"])
        XCTAssertEqual(clock.armedCount, 0, "a sticky card arms no timer — quiescent at idle")
    }

    func test_hoverPause_freezesTransientTimer_thenResumesWithTimeRemaining() async {
        let clock = TestClock()
        let core = IslandCore(clock: clock)
        let handle = core.register(SpySource("dev"))!
        handle.post(Content(title: "toast"), value: "t", presence: .transient(after: .seconds(5)))

        await clock.advance(by: .seconds(3))            // 2s remaining
        XCTAssertEqual(orderedIDs(core).map(\.value), ["t"])

        core.setHovering(true)                          // freeze
        await clock.advance(by: .seconds(100))          // a long hover — no time should be consumed
        XCTAssertEqual(orderedIDs(core).map(\.value), ["t"], "frozen timer must not fire while hovered")

        core.setHovering(false)                         // resume — 2s left from here
        await clock.advance(by: .seconds(1))
        XCTAssertEqual(orderedIDs(core).map(\.value), ["t"], "1s < 2s remaining: still alive")

        await clock.advance(by: .seconds(2))            // now past the remaining 2s
        XCTAssertEqual(orderedIDs(core).map(\.value), [], "resumes and expires after exactly the time that was left")
    }

    func test_cardArrivingWhileHovered_startsFrozen_untilResume() async {
        let clock = TestClock()
        let core = IslandCore(clock: clock)
        let handle = core.register(SpySource("dev"))!

        core.setHovering(true)
        handle.post(Content(title: "toast"), value: "t", presence: .transient(after: .seconds(5)))

        await clock.advance(by: .seconds(100))          // frozen at full 5s while hovered
        XCTAssertEqual(orderedIDs(core).map(\.value), ["t"])

        core.setHovering(false)
        await clock.advance(by: .seconds(6))            // now the full interval runs
        XCTAssertEqual(orderedIDs(core).map(\.value), [])
    }

    func test_upsert_refreshesTheCountdown() async {
        let clock = TestClock()
        let core = IslandCore(clock: clock)
        let handle = core.register(SpySource("dev"))!
        handle.post(Content(title: "v1"), value: "t", presence: .transient(after: .seconds(5)))

        await clock.advance(by: .seconds(4))            // 1s from original death
        handle.post(Content(title: "v2"), value: "t", presence: .transient(after: .seconds(5)))  // re-arm

        await clock.advance(by: .seconds(2))            // would have died under the old timer
        XCTAssertEqual(orderedIDs(core).map(\.value), ["t"], "upsert refreshed the countdown")
        XCTAssertEqual(core.ordered.first?.notification.content.title, "v2")

        await clock.advance(by: .seconds(4))            // past the refreshed 5s
        XCTAssertEqual(orderedIDs(core).map(\.value), [])
    }

    // MARK: - Criterion 3: duplicate-id rejection + vacated-id re-adoption

    func test_register_rejectsASecondLiveSourceWithTheSameId() {
        let core = IslandCore(clock: TestClock())
        let first = core.register(SpySource("dup"))!
        first.post(Content(title: "mine"), value: "1", presence: .sticky)

        // Second registration of a LIVE id → rejected (no silent hijack), first
        // source's card untouched.
        let second = core.register(SpySource("dup"))
        XCTAssertNil(second, "a second live source with the same id must be rejected")
        XCTAssertEqual(orderedIDs(core).map(\.value), ["1"])
    }

    func test_vacatedId_isReadopted_withItsStillVisibleCards() async {
        let core = IslandCore(clock: TestClock())
        let first = core.register(SpySource("rec"))!
        first.post(Content(title: "Recording…"), value: "live", presence: .sticky)
        XCTAssertEqual(orderedIDs(core).map(\.value), ["live"])

        // Previous instance torn down. Default orphan policy leaves the card in place.
        await core.unregister(SourceID(raw: "rec"))
        XCTAssertEqual(orderedIDs(core).map(\.value), ["live"], "leave-cards: an orphaned card stays visible")

        // Now the id is vacated: a new instance re-adopts it (allowed) and owns the
        // routing for the pre-existing card — it can revoke it.
        let second = core.register(SpySource("rec"))
        XCTAssertNotNil(second, "a vacated id can be re-adopted")
        second?.revoke("live")
        XCTAssertEqual(orderedIDs(core).map(\.value), [], "the re-adopted source can revoke the card it inherited")
    }

    // MARK: - Criterion 4: uniform teardown + fault containment

    func test_unregister_callsStopOnce_andIsIdempotent() async {
        let core = IslandCore(clock: TestClock())
        let spy = SpySource("dev")
        core.register(spy)

        await core.unregister(SourceID(raw: "dev"))
        XCTAssertEqual(spy.stopCount, 1)

        await core.unregister(SourceID(raw: "dev"))     // no live registration → no-op
        XCTAssertEqual(spy.stopCount, 1, "teardown is idempotent")
    }

    func test_faultingStart_isToreDownWithoutAffectingOtherSourcesOrTheCore() async {
        let core = IslandCore(clock: TestClock())
        let other = SpySource("other")
        let otherHandle = core.register(other)!
        otherHandle.post(Content(title: "safe"), value: "keep", presence: .sticky)

        // A source whose start() throws is logged and torn down.
        let bad = SpySource("bad")
        bad.throwOnStart = true
        core.register(bad)
        await bad.awaitStopped()
        XCTAssertEqual(bad.stopCount, 1, "a faulting start is torn down")

        // The core and the other source are unaffected: its card survives and it can
        // still post; the faulting id is now free to re-register.
        XCTAssertEqual(orderedIDs(core).map { "\($0.source):\($0.value)" }, ["other:keep"])
        otherHandle.post(Content(title: "again"), value: "keep2", presence: .sticky)
        XCTAssertEqual(orderedIDs(core).map(\.value).sorted(), ["keep", "keep2"])
        XCTAssertNotNil(core.register(SpySource("bad")), "the torn-down id is free again")
    }

    func test_faultingOnClosed_tearsDownOnlyThatSource() async {
        let core = IslandCore(clock: TestClock())
        let bad = SpySource("bad")
        bad.throwOnClosed = true
        let badHandle = core.register(bad)!
        badHandle.post(Content(title: "x"), value: "1", presence: .sticky)

        let other = SpySource("other")
        let otherHandle = core.register(other)!
        otherHandle.post(Content(title: "y"), value: "1", presence: .sticky)

        // Dismissing bad's card fires onClosed, which throws → bad is torn down.
        await core.dismiss(NotificationID(source: SourceID(raw: "bad"), value: "1"))
        XCTAssertEqual(bad.stopCount, 1, "the source whose callback threw is torn down")

        // The other source is untouched and the core still routes to it.
        XCTAssertEqual(other.stopCount, 0)
        XCTAssertEqual(orderedIDs(core).map { "\($0.source):\($0.value)" }, ["other:1"])
        otherHandle.revoke("1")
        XCTAssertEqual(orderedIDs(core).map(\.value), [], "the core survives and still serves other sources")
    }

    func test_teardown_defaultLeavesCards_butRevokeOnDisconnectAutoRevokes() async {
        let core = IslandCore(clock: TestClock())

        // Default: leave the cards.
        let keep = core.register(SpySource("keep"))!
        keep.post(Content(title: "stay"), value: "1", presence: .sticky)
        await core.unregister(SourceID(raw: "keep"))
        XCTAssertEqual(orderedIDs(core).map { "\($0.source):\($0.value)" }, ["keep:1"])

        // Opt-in revokeOnDisconnect: the source's cards auto-revoke on teardown.
        let rec = core.register(SpySource("rec", revokeOnDisconnect: true))!
        rec.post(Content(title: "Recording…"), value: "live", presence: .sticky)
        await core.unregister(SourceID(raw: "rec"))
        XCTAssertEqual(orderedIDs(core).map { "\($0.source):\($0.value)" }, ["keep:1"],
                       "revokeOnDisconnect removed only rec's card, leaving keep's")
    }

    // MARK: - Criterion 5: four CloseReasons through onClosed; dismiss vs revoke; onAction

    private func id(_ source: String, _ value: String) -> NotificationID {
        NotificationID(source: SourceID(raw: source), value: value)
    }

    func test_dismissVsRevoke_reportDistinctReasons() async {
        let core = IslandCore(clock: TestClock())
        let spy = SpySource("dev")
        let handle = core.register(spy)!
        handle.post(Content(title: "a"), value: "1", presence: .sticky)
        handle.post(Content(title: "b"), value: "2", presence: .sticky)

        await core.dismiss(id("dev", "1"))       // user ✕ → .dismissed
        handle.revoke("2")                        // source revoke → .revoked (spawned)
        await spy.awaitClosed(count: 2)

        XCTAssertEqual(spy.closed.map { "\($0.value):\($0.reason)" },
                       ["1:dismissed", "2:revoked"],
                       "dismiss (user) and revoke (source) stay distinct reasons")
    }

    func test_expire_reportsExpiredReason() async {
        let clock = TestClock()
        let core = IslandCore(clock: clock)
        let spy = SpySource("dev")
        let handle = core.register(spy)!
        handle.post(Content(title: "toast"), value: "1", presence: .transient(after: .seconds(5)))

        await clock.advance(by: .seconds(6))
        XCTAssertEqual(spy.closed.map(\.reason), [.expired])
    }

    func test_callbackAction_routesOnAction_thenReportsActed() async {
        let core = IslandCore(clock: TestClock())
        let spy = SpySource("dev")
        let handle = core.register(spy)!
        let n = Notification(
            id: id("dev", "1"),
            content: Content(title: "Meeting soon"),
            actions: [Action(label: "Snooze", behavior: .callback("snooze"))],
            presence: .sticky
        )
        handle.post(n)

        await core.fireAction(id("dev", "1"), at: 0)

        XCTAssertEqual(spy.actions.map { "\($0.value):\($0.actionID)" }, ["1:snooze"],
                       "a callback tap routes (value, actionID) to the owning source")
        XCTAssertEqual(spy.closed.map(\.reason), [.acted], "then reports .acted")
        XCTAssertEqual(orderedIDs(core).map(\.value), [], "dismissOnTap defaults true → card dismissed")
    }

    func test_openURLAction_isCoreRun_andReportsActed() async {
        let opener = OpenSpy()
        let core = IslandCore(clock: TestClock(), openURL: opener.open)
        let spy = SpySource("dev")
        let handle = core.register(spy)!
        let url = URL(string: "https://example.com/join")!
        let n = Notification(
            id: id("dev", "1"),
            content: Content(title: "Standup"),
            actions: [Action(label: "Join", behavior: .openURL(url))],
            presence: .sticky
        )
        handle.post(n)

        await core.fireAction(id("dev", "1"), at: 0)

        XCTAssertEqual(opener.opened, [url], "openURL is core-run via the injected opener")
        XCTAssertEqual(spy.actions.count, 0, "openURL never reaches the source (no onAction)")
        XCTAssertEqual(spy.closed.map(\.reason), [.acted], "openURL tap reports only .acted")
        XCTAssertEqual(orderedIDs(core).map(\.value), [])
    }
}
