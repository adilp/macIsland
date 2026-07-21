import XCTest
@testable import MacIslandGitHub
import MacIslandCore

/// State-machine tests for `GitHubActionsSource`, driven at the `NotificationSource`
/// seam through a real `IslandCore` with a scripted fake client, an injected
/// `TestClock`, and a `SpyAudio` — no network, no real `gh`, no wall-clock waits.
@MainActor
final class GitHubActionsSourceTests: XCTestCase {

    private struct Harness {
        let core: IslandCore
        let source: GitHubActionsSource
        let audio: SpyAudio
        let clock: TestClock
        let fake: FakeGitHubClient
    }

    /// `now` sits well after the fixtures' timestamps so "recent vs stale" is easy to
    /// arrange around the freshness window.
    private func makeHarness(
        _ script: [FakeGitHubClient.Response],
        config: GitHubActionsSource.Config = .init(),
        now: Date = Date(timeIntervalSinceReferenceDate: 10_000)
    ) -> Harness {
        let clock = TestClock(now: now)
        let audio = SpyAudio()
        let core = IslandCore(clock: clock, alerter: Alerter(audio: audio, clock: clock), openURL: { _ in })
        let fake = FakeGitHubClient(script)
        let source = GitHubActionsSource(client: fake, clock: clock, config: config)
        core.register(source)
        return Harness(core: core, source: source, audio: audio, clock: clock, fake: fake)
    }

    private func card(_ core: IslandCore, _ value: String) -> PlacedNotification? {
        core.ordered.first { $0.id.value == value }
    }

    // 1 — a new active run becomes a pill activity.
    func test_newActiveRun_postsPillActivity() async {
        let t = Date(timeIntervalSinceReferenceDate: 9_000)
        let h = makeHarness([.runs([ghRun(1, .active, startedAt: t)])])
        await h.source.awaitPoll(count: 1)

        let c = card(h.core, "run-1")
        XCTAssertNotNil(c?.notification.activity)
        XCTAssertEqual(c?.notification.presence, .sticky)
        XCTAssertEqual(c?.notification.actions.count, 1)          // "Open run"
        XCTAssertEqual(h.audio.startCount, 0)                     // silent while running
        XCTAssertEqual(derivePillState(from: h.core.ordered),
                       .single(glyph: .symbol("shippingbox.fill"), tint: nil, trailing: .clock(since: t)))
    }

    // 2 — a still-running run on a later poll must not re-post (no render churn).
    func test_stillRunning_doesNotRepost() async {
        let t = Date(timeIntervalSinceReferenceDate: 9_000)
        let h = makeHarness([.runs([ghRun(1, .active, startedAt: t)]),
                             .runs([ghRun(1, .active, startedAt: t)])])
        await h.source.awaitPoll(count: 1)
        var changes = 0
        h.core.onChange = { changes += 1 }

        await h.source.pollNow()                                 // poll 2 — still running

        XCTAssertEqual(h.fake.callCount, 2)                      // we did poll again
        XCTAssertEqual(changes, 0)                               // but nothing re-posted
        XCTAssertEqual(h.core.ordered.count, 1)
    }

    // 3 — success posts a persistent completion card (chime, no ring); it leaves the
    // pill, stays sticky, and does not auto-collapse.
    func test_success_postsPersistentCard() async {
        let t = Date(timeIntervalSinceReferenceDate: 9_000)
        let h = makeHarness([.runs([ghRun(1, .active, startedAt: t)]),
                             .runs([ghRun(1, .completed, .success, startedAt: t)])])
        await h.source.awaitPoll(count: 1)
        await h.source.pollNow()                                 // poll 2 — success

        let c = card(h.core, "run-1")
        XCTAssertNotNil(c)
        XCTAssertNil(c?.notification.activity)                   // left the pill → a stack card
        XCTAssertEqual(c?.notification.presence, .sticky)        // persistent, no auto-collapse
        XCTAssertTrue(c?.notification.content.title.contains("deployed") ?? false)
        XCTAssertEqual(h.audio.startCount, 0)                    // success never rings
        XCTAssertEqual(h.audio.playOnceCount, 0)                 // …and stays silent (calm)
        XCTAssertEqual(derivePillState(from: h.core.ordered), .bare)  // pill clear

        await h.clock.advance(by: .seconds(5))                   // time passes…
        XCTAssertNotNil(card(h.core, "run-1"))                   // …and it's still there
    }

    // 4 — failure leaves the pill and lands a sticky ringing card in the stack.
    func test_failure_leavesPill_postsRingingCard() async {
        let t = Date(timeIntervalSinceReferenceDate: 9_000)
        let done = Date(timeIntervalSinceReferenceDate: 9_990)   // ~10s before now → fresh
        let h = makeHarness([.runs([ghRun(1, .active, startedAt: t)]),
                             .runs([ghRun(1, .completed, .failure, startedAt: t, completedAt: done)])])
        await h.source.awaitPoll(count: 1)
        await h.source.pollNow()

        let c = card(h.core, "run-1")
        XCTAssertNil(c?.notification.activity)                   // no longer pill-resident
        XCTAssertEqual(c?.notification.presence, .sticky)
        XCTAssertTrue(c?.notification.content.title.contains("failed") ?? false)
        guard case .ringing = c?.notification.alerting else { return XCTFail("failure should ring") }
        XCTAssertEqual(h.audio.startCount, 1)
        XCTAssertTrue(h.audio.ringing)
        XCTAssertEqual(derivePillState(from: h.core.ordered), .bare)
    }

    // 5 — cancelled/skipped resolves silently.
    func test_cancelled_resolvesSilently() async {
        let t = Date(timeIntervalSinceReferenceDate: 9_000)
        let done = Date(timeIntervalSinceReferenceDate: 9_990)
        let h = makeHarness([.runs([ghRun(1, .active, startedAt: t)]),
                             .runs([ghRun(1, .completed, .quiet, startedAt: t, completedAt: done)])])
        await h.source.awaitPoll(count: 1)
        await h.source.pollNow()

        XCTAssertNil(card(h.core, "run-1"))
        XCTAssertEqual(h.audio.startCount, 0)
        XCTAssertEqual(derivePillState(from: h.core.ordered), .bare)
    }

    // 6 — cold-start guard: runs already completed before we launched are baseline.
    func test_coldStart_ignoresAlreadyCompletedRuns() async {
        let done = Date(timeIntervalSinceReferenceDate: 9_990)
        let h = makeHarness([.runs([ghRun(1, .completed, .failure, completedAt: done)])])
        await h.source.awaitPoll(count: 1)

        XCTAssertNil(card(h.core, "run-1"))                      // not adopted
        XCTAssertEqual(h.audio.startCount, 0)                    // and no ring on launch
    }

    // 7 — a transport failure is a no-op; a completion is never inferred from it.
    func test_transportFailure_neverInfersCompletion() async {
        let t = Date(timeIntervalSinceReferenceDate: 9_000)
        let h = makeHarness([.runs([ghRun(1, .active, startedAt: t)]),
                             .fail(.transport("offline")),
                             .runs([ghRun(1, .completed, .success, startedAt: t)])])
        await h.source.awaitPoll(count: 1)
        XCTAssertNotNil(card(h.core, "run-1")?.notification.activity)

        await h.source.pollNow()                                 // poll 2 — transport error
        XCTAssertNotNil(card(h.core, "run-1")?.notification.activity)  // still present
        XCTAssertEqual(h.audio.startCount, 0)
        XCTAssertEqual(h.source.status, .ok)                     // a blip doesn't flip status

        await h.source.pollNow()                                 // poll 3 — success resolves it
        let c = card(h.core, "run-1")
        XCTAssertEqual(c?.notification.presence, .sticky)        // persistent completion card
        XCTAssertNil(c?.notification.activity)                   // left the pill
    }

    // 8 — a run that vanishes from a *successful* list is revoked quietly.
    func test_vanishedFromSuccessfulList_revokesQuietly() async {
        let t = Date(timeIntervalSinceReferenceDate: 9_000)
        let h = makeHarness([.runs([ghRun(1, .active, startedAt: t)]),
                             .runs([])])
        await h.source.awaitPoll(count: 1)
        XCTAssertNotNil(card(h.core, "run-1"))

        await h.source.pollNow()
        XCTAssertNil(card(h.core, "run-1"))
        XCTAssertEqual(h.audio.startCount, 0)
        XCTAssertEqual(derivePillState(from: h.core.ordered), .bare)
    }

    // 9 — a re-run (same id back to active) is re-adopted as a fresh activity.
    func test_rerun_reAdoptsActivity() async {
        let t = Date(timeIntervalSinceReferenceDate: 9_000)
        let t2 = Date(timeIntervalSinceReferenceDate: 9_500)
        let h = makeHarness([.runs([ghRun(1, .active, startedAt: t)]),
                             .runs([ghRun(1, .completed, .success, startedAt: t)]),
                             .runs([ghRun(1, .active, startedAt: t2)])])
        await h.source.awaitPoll(count: 1)
        await h.source.pollNow()                                 // success → removed from tracked
        await h.source.pollNow()                                 // re-run → active again

        let c = card(h.core, "run-1")
        XCTAssertEqual(c?.notification.activity?.since, t2)      // running again, new start
        XCTAssertEqual(c?.notification.presence, .sticky)
    }

    // 10 — cadence: idle backs off floor→ceiling; a new deploy snaps back to fast.
    func test_cadence_idleBacksOff_activeSnapsBack() async {
        var cfg = GitHubActionsSource.Config()
        cfg.activeInterval = .seconds(15)
        cfg.idleFloor = .seconds(60)
        cfg.idleCeiling = .seconds(300)
        let h = makeHarness([], config: cfg)                     // idle (default empty)
        await h.source.awaitPoll(count: 1)
        XCTAssertEqual(h.source.nextPollInterval, .seconds(60))  // first idle → floor

        await h.clock.advance(by: .seconds(60))                  // loop fires → poll 2
        XCTAssertEqual(h.source.nextPollInterval, .seconds(120))
        await h.clock.advance(by: .seconds(120))                 // poll 3
        XCTAssertEqual(h.source.nextPollInterval, .seconds(240))
        await h.clock.advance(by: .seconds(240))                 // poll 4
        XCTAssertEqual(h.source.nextPollInterval, .seconds(300)) // capped at ceiling

        h.fake.defaultResponse = .runs([ghRun(9, .active, startedAt: h.clock.now())])
        await h.clock.advance(by: .seconds(300))                 // poll 5 — a deploy appears
        XCTAssertEqual(h.source.nextPollInterval, .seconds(15))  // snaps to active cadence
    }

    // 11 — a failure that finished long ago (e.g. while asleep) lands silently on wake.
    func test_staleFailure_resolvesSilently() async {
        let t = Date(timeIntervalSinceReferenceDate: 9_000)
        let stale = Date(timeIntervalSinceReferenceDate: 9_000)  // ~1000s before now > freshness
        let h = makeHarness([.runs([ghRun(1, .active, startedAt: t)]),
                             .runs([ghRun(1, .completed, .failure, startedAt: t, completedAt: stale)])])
        await h.source.awaitPoll(count: 1)
        await h.source.pollNow()

        XCTAssertEqual(card(h.core, "run-1")?.notification.alerting, .silent)
        XCTAssertEqual(h.audio.startCount, 0)
    }

    // 12 — auth failure posts exactly one info card, then self-heals on success.
    func test_authFailure_postsOneCard_thenSelfHeals() async {
        let t = Date(timeIntervalSinceReferenceDate: 9_000)
        let h = makeHarness([.fail(.notAuthenticated),
                             .fail(.notAuthenticated),
                             .runs([ghRun(1, .active, startedAt: t)])])
        await h.source.awaitPoll(count: 1)
        XCTAssertEqual(h.source.status, .needsAuth("Run `gh auth login`"))
        XCTAssertNotNil(card(h.core, "auth"))

        await h.source.pollNow()                                 // still not authed
        XCTAssertEqual(h.core.ordered.filter { $0.id.value == "auth" }.count, 1)  // no second card

        await h.source.pollNow()                                 // authed → clears + adopts run
        XCTAssertNil(card(h.core, "auth"))
        XCTAssertEqual(h.source.status, .ok)
        XCTAssertNotNil(card(h.core, "run-1"))
    }
}
