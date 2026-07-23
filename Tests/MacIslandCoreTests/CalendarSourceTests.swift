import XCTest
@testable import MacIslandCore

/// `Notification` collides with `Foundation.Notification` (via XCTest); pin the bare
/// name to our value type for readable type-position use.
private typealias Notification = MacIslandCore.Notification

/// Tests for the **Calendar/meeting source** — the first real `NotificationSource`,
/// a thin EventKit→`handle.post` adapter. Driven at the ticket's seam: a **fake
/// `MeetingStore` + injected `Clock`** through a real `IslandCore`, so the whole
/// chain (engine → source → handle → core → stack/alerter) is asserted with no
/// EventKit, no real audio, and no wall-clock waits. Calendar spec 06 §§3–6; unified
/// spec §5.
@MainActor
final class CalendarSourceTests: XCTestCase {

    private let calendarSource = SourceID(raw: "calendar")

    private func calID(_ value: String) -> NotificationID {
        NotificationID(source: calendarSource, value: value)
    }

    /// A core wired to spy audio + an open-URL spy, plus a `CalendarSource` over a fake
    /// store — everything sharing one hand-advanced `TestClock`.
    private func makeSystem(
        _ meetings: [MeetingEvent],
        authorization: CalendarAuthorization = .authorized,
        grantOnRequest: Bool = true
    ) -> (core: IslandCore, store: FakeMeetingStore, clock: TestClock, audio: SpyAudio, opened: OpenSpy, source: CalendarSource) {
        let clock = TestClock()
        let audio = SpyAudio()
        let opened = OpenSpy()
        let core = IslandCore(
            clock: clock,
            alerter: Alerter(audio: audio, clock: clock),
            openURL: { opened.open($0) }
        )
        let store = FakeMeetingStore(meetings: meetings, authorization: authorization, grantOnRequest: grantOnRequest)
        let source = CalendarSource(store: store, clock: clock)
        core.register(source)
        return (core, store, clock, audio, opened, source)
    }

    private func cards(_ core: IslandCore) -> [Notification] { core.ordered.map(\.notification) }

    // MARK: - Criterion 1: T-5 for every meeting, T-1 (video) update-in-place

    func test_everyTimedMeeting_postsT5TransientSoundOnceCard() async {
        let clock = TestClock()
        let start = clock.now().addingTimeInterval(600)   // 10 minutes out
        let sys = makeSystem([.make(id: "m", title: "Standup", start: start)])
        await sys.store.awaitFetch()

        await sys.clock.advance(by: .seconds(300))        // → T-5 (start − 5min)

        XCTAssertEqual(cards(sys.core).count, 1)
        let card = cards(sys.core)[0]
        XCTAssertEqual(card.id, calID("m"))
        XCTAssertEqual(card.content.title, "Standup")
        XCTAssertEqual(card.content.body, "in 5 minutes · Work")
        XCTAssertEqual(card.content.icon, .symbol("calendar"))    // non-video icon
        XCTAssertEqual(card.actions, [])                          // no Join on T-5
        XCTAssertEqual(card.presence, .transient(after: .seconds(10)))
        XCTAssertEqual(card.alerting, .soundOnce)
        XCTAssertEqual(sys.audio.playOnceCount, 1)                // arrival chime
        XCTAssertFalse(sys.audio.ringing)                         // never rings
    }

    func test_videoMeeting_upsertsSameId_intoStickyRingingJoinCard_atT1() async {
        // First seen ~65s out so the ~10s T-5 transient is still alive at T-1 → a true
        // update-in-place (spec §4: the near-start edge-case guarantee).
        let clock = TestClock()
        let start = clock.now().addingTimeInterval(65)
        let sys = makeSystem([.make(id: "vid", title: "Design", start: start, videoLink: VideoLink.meet)])
        await sys.store.awaitFetch()

        // T-5 fired immediately (inside the 5-min window): a transient warning card.
        XCTAssertEqual(cards(sys.core).count, 1)
        XCTAssertEqual(cards(sys.core)[0].presence, .transient(after: .seconds(10)))
        XCTAssertEqual(cards(sys.core)[0].content.icon, .symbol("video.fill"))
        let receivedAt = sys.core.ordered[0].receivedAt

        await sys.clock.advance(by: .seconds(5))          // → T-1 (start − 60s)

        // Same id, updated in place (position held), now the sticky ringing Join card.
        XCTAssertEqual(cards(sys.core).count, 1)
        let card = cards(sys.core)[0]
        XCTAssertEqual(card.id, calID("vid"))
        XCTAssertEqual(sys.core.ordered[0].receivedAt, receivedAt, "update-in-place holds receivedAt")
        XCTAssertEqual(card.content.body, "starting now")
        XCTAssertEqual(card.presence, .sticky)
        XCTAssertEqual(card.alerting, .ringing())
        XCTAssertEqual(card.actions.count, 1)
        XCTAssertEqual(card.actions[0].label, "Join Meet")
        XCTAssertEqual(card.actions[0].behavior, .openURL(VideoLink.meet.url))
        XCTAssertTrue(card.actions[0].dismissOnTap)
        XCTAssertTrue(sys.audio.ringing)                  // ring started
    }

    func test_nonVideoMeeting_postsOnlyT5_neverRings() async {
        let clock = TestClock()
        let start = clock.now().addingTimeInterval(600)
        let sys = makeSystem([.make(id: "nv", start: start, videoLink: nil)])
        await sys.store.awaitFetch()

        await sys.clock.advance(by: .seconds(300))        // T-5
        XCTAssertEqual(cards(sys.core).count, 1)
        await sys.clock.advance(by: .seconds(240))        // past where T-1 would be (start − 60s)

        // The transient expired (10s ≪ 240s) and nothing new arrived; no ring ever.
        XCTAssertTrue(cards(sys.core).isEmpty)
        XCTAssertEqual(sys.audio.startCount, 0)
    }

    // MARK: - Criterion 2: ring stops at earliest of {Join, dismiss, revoke, 120s}; endDate self-revoke

    /// Drive a video meeting to its ringing T-1 state and return the system + card id.
    private func ringingSystem(id: String = "vid", durationMinutes: Double = 30)
    async -> (core: IslandCore, store: FakeMeetingStore, clock: TestClock, audio: SpyAudio, opened: OpenSpy, source: CalendarSource, cardID: NotificationID) {
        let clock = TestClock()
        let start = clock.now().addingTimeInterval(600)
        let sys = makeSystem([.make(id: id, start: start, durationMinutes: durationMinutes, videoLink: VideoLink.meet)])
        await sys.store.awaitFetch()
        await sys.clock.advance(by: .seconds(540))        // → T-1 (start − 60s): ringing
        XCTAssertTrue(sys.audio.ringing, "precondition: ringing at T-1")
        return (sys.core, sys.store, sys.clock, sys.audio, sys.opened, sys.source, calID(id))
    }

    func test_ring_stopsAt120sTimeout_butStickyCardSurvives() async {
        let sys = await ringingSystem()
        await sys.clock.advance(by: .seconds(120))        // the ring timeout
        XCTAssertFalse(sys.audio.ringing, "ring stops at 120s")
        XCTAssertEqual(sys.core.ordered.count, 1, "sticky card survives the timeout")
        XCTAssertEqual(sys.core.ordered[0].notification.presence, .sticky)
    }

    func test_ring_stopsWhenJoinFired_opensURL_andDismisses() async {
        let sys = await ringingSystem()
        await sys.core.fireAction(sys.cardID, at: 0)      // tap Join
        XCTAssertEqual(sys.opened.opened, [VideoLink.meet.url])  // core-run openURL
        XCTAssertFalse(sys.audio.ringing, "ring stops on action")
        XCTAssertTrue(sys.core.ordered.isEmpty, "dismissOnTap closes the card")
    }

    func test_ring_stopsWhenUserDismisses() async {
        let sys = await ringingSystem()
        await sys.core.dismiss(sys.cardID)
        XCTAssertFalse(sys.audio.ringing)
        XCTAssertTrue(sys.core.ordered.isEmpty)
    }

    func test_stickyCard_selfRevokesAtEndDate() async {
        let sys = await ringingSystem(durationMinutes: 30)
        await sys.clock.advance(by: .seconds(120))        // ring times out; card lingers
        XCTAssertEqual(sys.core.ordered.count, 1)
        // endDate = start + 30min. We are at start + 60s. Advance past endDate.
        await sys.clock.advance(by: .seconds(30 * 60))
        XCTAssertTrue(sys.core.ordered.isEmpty, "the leftover sticky card self-revokes at endDate")
    }

    func test_stickyCard_revokedWhenMeetingDeleted() async {
        let sys = await ringingSystem()
        XCTAssertEqual(sys.core.ordered.count, 1)
        sys.store.triggerChange(meetings: [])             // calendar edit: meeting vanished
        XCTAssertTrue(sys.core.ordered.isEmpty, "a vanished meeting's card is revoked")
        XCTAssertFalse(sys.audio.ringing, "and its ring stops with it")
    }

    // MARK: - Criterion 3: T-5 dismiss cancels the ring; expire lets it fire; Join opens URL

    func test_dismissingT5Warning_cancelsThePendingRing() async {
        let clock = TestClock()
        let start = clock.now().addingTimeInterval(600)
        let sys = makeSystem([.make(id: "vid", start: start, videoLink: VideoLink.meet)])
        await sys.store.awaitFetch()

        await sys.clock.advance(by: .seconds(300))        // T-5 warning
        XCTAssertEqual(cards(sys.core).count, 1)
        await sys.core.dismiss(calID("vid"))              // acknowledged early → cancel T-1
        await sys.store.awaitFetch()                      // (no-op; ensure dismiss reporting landed)

        await sys.clock.advance(by: .seconds(240))        // past T-1
        XCTAssertTrue(cards(sys.core).isEmpty, "no ring card posts")
        XCTAssertEqual(sys.audio.startCount, 0, "the pending ring was cancelled")
    }

    func test_lettingT5Expire_letsTheRingFire() async {
        let clock = TestClock()
        let start = clock.now().addingTimeInterval(600)
        let sys = makeSystem([.make(id: "vid", start: start, videoLink: VideoLink.meet)])
        await sys.store.awaitFetch()

        await sys.clock.advance(by: .seconds(300))        // T-5 warning
        await sys.clock.advance(by: .seconds(10))         // let it expire (ignored, not dismissed)
        XCTAssertTrue(cards(sys.core).isEmpty)

        await sys.clock.advance(by: .seconds(230))        // → T-1 (start − 60s)
        XCTAssertEqual(cards(sys.core).count, 1)
        XCTAssertEqual(cards(sys.core)[0].presence, .sticky)
        XCTAssertTrue(sys.audio.ringing, "the ring fires because the warning was ignored, not dismissed")
    }

    func test_joinAction_opensTheParsedVideoURL() async {
        let sys = await ringingSystem()
        XCTAssertEqual(sys.core.ordered[0].notification.actions[0].behavior, .openURL(VideoLink.meet.url))
        await sys.core.fireAction(sys.cardID, at: 0)
        XCTAssertEqual(sys.opened.opened, [VideoLink.meet.url])
    }

    // MARK: - Criterion 4: permissions — request on first launch; inert when denied

    func test_firstLaunch_requestsAccess_thenMonitors() async {
        let clock = TestClock()
        let start = clock.now().addingTimeInterval(600)
        let sys = makeSystem([.make(id: "m", start: start)], authorization: .notDetermined, grantOnRequest: true)
        await sys.store.awaitFetch()                      // request → granted → monitor → fetch

        XCTAssertEqual(sys.store.requestAccessCount, 1, "access is auto-requested on first launch")
        await sys.clock.advance(by: .seconds(300))
        XCTAssertEqual(cards(sys.core).count, 1, "once granted, meetings post")
    }

    func test_whenDenied_sourceIsInert_postsNothing() async {
        let clock = TestClock()
        let start = clock.now().addingTimeInterval(600)
        let sys = makeSystem([.make(id: "m", start: start)], authorization: .denied)
        await sys.store.awaitBootstrap()

        XCTAssertEqual(sys.store.requestAccessCount, 0, "already-decided denial isn't re-requested")
        XCTAssertEqual(sys.store.fetchCount, 0, "inert: no monitoring")
        await sys.clock.advance(by: .seconds(600))
        XCTAssertTrue(cards(sys.core).isEmpty, "the denied source produces zero notifications")
    }

    func test_whenNotDeterminedAndUserDenies_sourceStaysInert() async {
        let clock = TestClock()
        let start = clock.now().addingTimeInterval(600)
        let sys = makeSystem([.make(id: "m", start: start)], authorization: .notDetermined, grantOnRequest: false)
        await sys.store.awaitRequestAccess()

        XCTAssertEqual(sys.store.requestAccessCount, 1)
        XCTAssertEqual(sys.store.fetchCount, 0, "a denied request leaves the source inert")
        await sys.clock.advance(by: .seconds(600))
        XCTAssertTrue(cards(sys.core).isEmpty)
    }

    func test_deniedSource_doesNotAffectOtherSources() async {
        let clock = TestClock()
        let start = clock.now().addingTimeInterval(600)
        let sys = makeSystem([.make(id: "m", start: start)], authorization: .denied)
        await sys.store.awaitBootstrap()

        // A second, ordinary source still registers and posts — the core is unaffected.
        let other = SpySource("other")
        let handle = sys.core.register(other)
        XCTAssertNotNil(handle)
        handle?.post(Content(title: "hi"), value: "1", presence: .sticky)
        XCTAssertEqual(cards(sys.core).count, 1)
        XCTAssertEqual(cards(sys.core)[0].id.value, "1")
    }

    // MARK: - In-progress meetings: a Join card for a meeting already underway
    //
    // A meeting whose T-1 fired while the Mac slept is missed by the timer path (spec:
    // the missing-banner gap). So on any refresh — launch, calendar edit, or wake — a
    // meeting that is *currently underway* (startDate ≤ now < endDate) and joinable
    // (has a video link) gets a **silent, sticky Join card** so it can be joined without
    // hunting through Calendar. Surfaced at most once per meeting so a dismissal sticks
    // and repeated wakes don't nag.

    /// A meeting that began 10 minutes ago and runs another 20 — in progress at fetch.
    private func inProgressVideoMeeting(id: String = "live", title: String = "Design")
    -> MeetingEvent {
        let start = TestClock().now().addingTimeInterval(-600)   // started 10 min ago
        return .make(id: id, title: title, start: start, durationMinutes: 30, videoLink: VideoLink.meet)
    }

    func test_inProgressVideoMeeting_postsSilentStickyJoinCard() async {
        let sys = makeSystem([inProgressVideoMeeting()])
        await sys.store.awaitFetch()

        XCTAssertEqual(cards(sys.core).count, 1)
        let card = cards(sys.core)[0]
        XCTAssertEqual(card.id, calID("live"))
        XCTAssertEqual(card.content.title, "Design")
        XCTAssertEqual(card.content.body, "in progress · Work")
        XCTAssertEqual(card.content.icon, .symbol("video.fill"))
        XCTAssertEqual(card.presence, .sticky)
        XCTAssertEqual(card.alerting, .silent, "already-underway: appears, never rings")
        XCTAssertEqual(card.actions.count, 1)
        XCTAssertEqual(card.actions[0].label, "Join Meet")
        XCTAssertEqual(card.actions[0].behavior, .openURL(VideoLink.meet.url))
        XCTAssertTrue(card.actions[0].dismissOnTap)
        XCTAssertFalse(sys.audio.ringing)
        XCTAssertEqual(sys.audio.playOnceCount, 0, "silent: no arrival chime either")
    }

    func test_inProgressNonVideoMeeting_postsNothing() async {
        let start = TestClock().now().addingTimeInterval(-600)
        let sys = makeSystem([.make(id: "nv", start: start, durationMinutes: 30, videoLink: nil)])
        await sys.store.awaitFetch()

        XCTAssertTrue(cards(sys.core).isEmpty, "an underway meeting with no join link has nothing to show")
        XCTAssertEqual(sys.audio.startCount, 0)
    }

    func test_inProgressCard_notDuplicatedOrRealerted_onRepeatedRefresh() async {
        let sys = makeSystem([inProgressVideoMeeting()])
        await sys.store.awaitFetch()
        XCTAssertEqual(cards(sys.core).count, 1)

        // Two more refreshes (a calendar edit, then a wake) with the same live meeting.
        sys.store.triggerChange()
        sys.store.triggerChange()

        XCTAssertEqual(cards(sys.core).count, 1, "surfaced once — no duplicate on later refreshes")
        XCTAssertEqual(sys.audio.playOnceCount, 0)
        XCTAssertFalse(sys.audio.ringing)
    }

    func test_inProgressCard_dismissed_staysDismissedAcrossRefresh() async {
        let sys = makeSystem([inProgressVideoMeeting()])
        await sys.store.awaitFetch()
        XCTAssertEqual(cards(sys.core).count, 1)

        await sys.core.dismiss(calID("live"))
        XCTAssertTrue(cards(sys.core).isEmpty)

        // Another wake / calendar edit while the meeting is still underway.
        sys.store.triggerChange()

        XCTAssertTrue(cards(sys.core).isEmpty, "a dismissed in-progress card does not silently return")
    }

    func test_liveT1RingingCard_notDowngraded_byInProgressRefresh() async {
        // The awake path already rang the T-1 Join card at the meeting's start; a later
        // refresh must not replace that live ringing card with the silent in-progress one.
        let clock = TestClock()
        let start = clock.now().addingTimeInterval(600)
        let sys = makeSystem([.make(id: "vid", start: start, durationMinutes: 30, videoLink: VideoLink.meet)])
        await sys.store.awaitFetch()

        await sys.clock.advance(by: .seconds(540))   // → T-1: ringing "starting now"
        XCTAssertTrue(sys.audio.ringing)
        await sys.clock.advance(by: .seconds(90))     // → start + 30s: underway, still ringing

        sys.store.triggerChange()                     // wake/edit refresh while underway

        XCTAssertEqual(cards(sys.core).count, 1)
        let card = cards(sys.core)[0]
        XCTAssertEqual(card.content.body, "starting now", "the live T-1 card is left intact")
        XCTAssertEqual(card.alerting, .ringing())
        XCTAssertTrue(sys.audio.ringing, "its ring keeps going")
    }

    func test_inProgressCard_revokedWhenMeetingVanishes_andResurfacesIfItReturns() async {
        let live = inProgressVideoMeeting()
        let sys = makeSystem([live])
        await sys.store.awaitFetch()
        XCTAssertEqual(cards(sys.core).count, 1)

        sys.store.triggerChange(meetings: [])         // meeting removed from the calendar
        XCTAssertTrue(cards(sys.core).isEmpty, "a vanished in-progress meeting's card is revoked")

        // It comes back still underway → surfaces again (proof the id was cleared on revoke).
        sys.store.triggerChange(meetings: [live])
        XCTAssertEqual(cards(sys.core).count, 1, "a returned in-progress meeting resurfaces")
        XCTAssertEqual(cards(sys.core)[0].content.body, "in progress · Work")
    }
}
