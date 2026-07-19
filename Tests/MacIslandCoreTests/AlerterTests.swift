import XCTest
@testable import MacIslandCore

private typealias Notification = MacIslandCore.Notification

/// Tests for the core `Alerter` — the sound layer driven purely by a card's
/// `Alerting` level + lifecycle (unified spec §8.1). Exercised **through `IslandCore`
/// at the `SourceHandle` seam** (sources never call the Alerter) and observed at the
/// **spy-audio seam** with the injected fake clock — no real audio, no wall-clock
/// waits (ticket "Alerting & the Alerter").
@MainActor
final class AlerterTests: XCTestCase {

    /// Build a core whose sound layer is the spy, sharing the fake clock so the ring
    /// timeout is driven deterministically.
    private func makeCore() -> (core: IslandCore, audio: SpyAudio, clock: TestClock) {
        let clock = TestClock()
        let audio = SpyAudio()
        let core = IslandCore(clock: clock, alerter: Alerter(audio: audio, clock: clock))
        return (core, audio, clock)
    }

    private func id(_ source: String, _ value: String) -> NotificationID {
        NotificationID(source: SourceID(raw: source), value: value)
    }

    // MARK: - Criterion 1: soundOnce plays once on arrival; silent plays nothing

    func test_soundOnceCard_playsExactlyOneSoundOnArrival() {
        let (core, audio, _) = makeCore()
        let handle = core.register(SpySource("dev"))!

        handle.post(Content(title: "ping"), value: "1", presence: .sticky, alerting: .soundOnce)

        XCTAssertEqual(audio.playOnceCount, 1, "a .soundOnce card plays exactly one sound on arrival")
        XCTAssertFalse(audio.ringing, "soundOnce never starts the ring channel")
    }

    func test_silentCard_playsNothing() {
        let (core, audio, _) = makeCore()
        let handle = core.register(SpySource("dev"))!

        handle.post(Content(title: "quiet"), value: "1", presence: .sticky, alerting: .silent)

        XCTAssertEqual(audio.playOnceCount, 0, "a .silent card plays nothing")
        XCTAssertFalse(audio.ringing)
    }

    func test_soundOnce_doesNotReplayOnUpsert_butReplaysAfterDismissAndRepost() async {
        let (core, audio, _) = makeCore()
        let handle = core.register(SpySource("dev"))!

        // Arrival → one chime.
        handle.post(Content(title: "v1"), value: "1", presence: .sticky, alerting: .soundOnce)
        XCTAssertEqual(audio.playOnceCount, 1)

        // In-place update (same id) is not an arrival → no replay.
        handle.post(Content(title: "v2"), value: "1", presence: .sticky, alerting: .soundOnce)
        XCTAssertEqual(audio.playOnceCount, 1, "an upsert is not an arrival — no replay")

        // Gone, then a genuinely new arrival of the same id → chimes again.
        await core.dismiss(id("dev", "1"))
        handle.post(Content(title: "v3"), value: "1", presence: .sticky, alerting: .soundOnce)
        XCTAssertEqual(audio.playOnceCount, 2, "a fresh arrival after removal chimes again")
    }

    // MARK: - Criterion 2: ring loops until earliest of removed / acted / 120s timeout

    /// A ringing card. `.sticky` because a ring only makes sense on a card that
    /// persists (the model notes the timeout "only bites for sticky cards").
    private func ringingCard(_ source: String, _ value: String,
                             timeout: Duration = Alerting.defaultRingTimeout,
                             actions: [Action] = []) -> Notification {
        Notification(
            id: id(source, value),
            content: Content(title: value),
            actions: actions,
            presence: .sticky,
            alerting: .ringing(timeout: timeout)
        )
    }

    func test_ringingCard_startsTheRingOnArrival() {
        let (core, audio, _) = makeCore()
        let handle = core.register(SpySource("dev"))!

        handle.post(ringingCard("dev", "1"))

        XCTAssertEqual(audio.startCount, 1, "a ringing card starts exactly one loop")
        XCTAssertTrue(audio.ringing, "the ring is active")
        XCTAssertEqual(audio.playOnceCount, 0, "a ring is not a one-shot chime")
    }

    func test_ring_stopsWhenCardRemoved_neverOutlivesItsCard() async {
        let (core, audio, _) = makeCore()
        let handle = core.register(SpySource("dev"))!
        handle.post(ringingCard("dev", "1"))
        XCTAssertTrue(audio.ringing)

        await core.dismiss(id("dev", "1"))

        XCTAssertFalse(audio.ringing, "the ring never outlives its card")
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(core.ordered.count, 0)
    }

    func test_ring_stopsAtTimeout_viaInjectedClock_whileCardStays() async {
        let (core, audio, clock) = makeCore()
        let handle = core.register(SpySource("dev"))!
        handle.post(ringingCard("dev", "1"))   // default 120s timeout

        await clock.advance(by: .seconds(119))
        XCTAssertTrue(audio.ringing, "still ringing just before the timeout")

        await clock.advance(by: .seconds(2))   // past 120s
        XCTAssertFalse(audio.ringing, "the ring stops at the 120s timeout")
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(core.ordered.map(\.id.value), ["1"], "the sticky card outlives its ring")

        // A later, unrelated reconcile must not resurrect the timed-out ring.
        handle.post(Content(title: "other"), value: "2", presence: .sticky, alerting: .silent)
        XCTAssertFalse(audio.ringing, "a terminated ring does not restart while its card persists")
        XCTAssertEqual(audio.startCount, 1)
    }

    func test_ring_stopsWhenActionFired_evenIfCardKept() async {
        let (core, audio, _) = makeCore()
        let handle = core.register(SpySource("dev"))!
        // A keep-the-card action (dismissOnTap:false) so we isolate "action fired"
        // from "card removed" as the ring-ending trigger.
        let keep = Action(label: "Snooze", behavior: .callback("snooze"), dismissOnTap: false)
        handle.post(ringingCard("dev", "1", actions: [keep]))
        XCTAssertTrue(audio.ringing)

        await core.fireAction(id("dev", "1"), at: 0)

        XCTAssertFalse(audio.ringing, "any action fired ends the ring")
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(core.ordered.map(\.id.value), ["1"], "the kept card stays; only its ring ended")
    }

    func test_ring_earliestTrigger_removalBeatsTimeout() async {
        let (core, audio, clock) = makeCore()
        let handle = core.register(SpySource("dev"))!
        handle.post(ringingCard("dev", "1"))

        await clock.advance(by: .seconds(10))   // long before the 120s timeout
        await core.dismiss(id("dev", "1"))       // removal is the earliest trigger
        XCTAssertFalse(audio.ringing)
        XCTAssertEqual(audio.stopCount, 1)

        // The since-cancelled timeout must not fire a second stop later.
        await clock.advance(by: .seconds(200))
        XCTAssertEqual(audio.stopCount, 1, "the timeout was cancelled when the card left — no phantom stop")
    }

    // MARK: - Criterion 3: single global ring channel, owned by the top ringing card

    func test_twoRingingCards_produceExactlyOneActiveRing() {
        let (core, audio, _) = makeCore()
        let handle = core.register(SpySource("dev"))!

        handle.post(ringingCard("dev", "1"))          // A
        handle.post(ringingCard("dev", "2"))          // B — newer sticky sits nearer the notch (top)

        XCTAssertTrue(audio.ringing, "the channel is live")
        XCTAssertEqual(audio.startCount, 1, "no stacked loops — the second card takes the one channel, not a new ring")
    }

    func test_ringOwnedByTopCard_removingNonTopLeavesRingUndisturbed() async {
        let (core, audio, _) = makeCore()
        let handle = core.register(SpySource("dev"))!
        handle.post(ringingCard("dev", "1"))          // A (older → lower)
        handle.post(ringingCard("dev", "2"))          // B (newer → top → owns the ring)

        // Remove the NON-top card. The owner is the top card, so the channel is
        // untouched — no stop, still ringing.
        await core.dismiss(id("dev", "1"))
        XCTAssertTrue(audio.ringing, "removing a non-owning ringing card doesn't disturb the ring")
        XCTAssertEqual(audio.stopCount, 0)

        // Remove the owner (now the last ringing card) → the channel frees.
        await core.dismiss(id("dev", "2"))
        XCTAssertFalse(audio.ringing, "when the ring ends the channel is free")
        XCTAssertEqual(audio.stopCount, 1)
    }

    func test_channelFree_whenAllRingingCardsGone() async {
        let (core, audio, _) = makeCore()
        let handle = core.register(SpySource("dev"))!
        handle.post(ringingCard("dev", "1"))
        handle.post(ringingCard("dev", "2"))
        XCTAssertTrue(audio.ringing)

        handle.revokeAll()

        XCTAssertFalse(audio.ringing, "no ringing cards left → channel free")
        XCTAssertEqual(audio.stopCount, 1)
    }

    /// Chosen tie-break for the single channel: when the owning card's ring ends while
    /// another ringing card remains, the channel hands over to that next top card (one
    /// continuous ring, never two). The channel is only *free* once no ringing card
    /// remains. Pins the decision so a reviewer can see exactly where to flip it.
    func test_ownerTimeout_handsChannelToNextRingingCard_thenFreesWhenNoneRemain() async {
        let (core, audio, clock) = makeCore()
        let handle = core.register(SpySource("dev"))!
        handle.post(ringingCard("dev", "1"))          // A
        handle.post(ringingCard("dev", "2"))          // B owns the channel (top)

        await clock.advance(by: .seconds(120))        // B's cutoff
        XCTAssertTrue(audio.ringing, "B timed out, but A still rings — the channel hands over, never two at once")
        XCTAssertEqual(audio.startCount, 2, "one continuous channel: B's ring stopped, A's began (never concurrent)")
        XCTAssertEqual(audio.stopCount, 1)

        await clock.advance(by: .seconds(120))        // A's cutoff
        XCTAssertFalse(audio.ringing, "both ringing cards have timed out → channel free")
        XCTAssertEqual(audio.stopCount, 2)
    }
}
