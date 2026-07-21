import XCTest
@testable import MacIslandCore

/// `Notification` collides with `Foundation.Notification` (via XCTest); pin the bare
/// name to our value type.
private typealias Notification = MacIslandCore.Notification

/// Tests for the source-agnostic pill/activity summary — the island's ambient
/// (in-pill) layer, orthogonal to the downward card stack. Pure: no core, no clock,
/// no UI. Seam: the `derivePillState` free function over the render order.
final class PillStateTests: XCTestCase {

    private func placed(
        source: String = "gh",
        value: String,
        activity: ActivityStyle?,
        receivedAt t: TimeInterval = 0
    ) -> PlacedNotification {
        let n = Notification(
            id: NotificationID(source: SourceID(raw: source), value: value),
            content: Content(title: value),
            presence: .sticky,
            activity: activity
        )
        return PlacedNotification(notification: n, receivedAt: at(t))
    }

    private func at(_ t: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: t) }

    // MARK: - 0 activities → bare

    func test_empty_isBare() {
        XCTAssertEqual(derivePillState(from: []), .bare)
    }

    func test_nonActivityCardsOnly_isBare() {
        // Regular cards (no ActivityStyle) live only in the downward stack, never the pill.
        let cards = [placed(value: "a", activity: nil), placed(value: "b", activity: nil)]
        XCTAssertEqual(derivePillState(from: cards), .bare)
    }

    // MARK: - 1 activity → single

    func test_singleActivity_withSince_showsLiveClock() {
        let a = placed(value: "run-1",
                       activity: ActivityStyle(glyph: .symbol("hammer.fill"), since: at(100), noun: "deploy"))
        XCTAssertEqual(
            derivePillState(from: [a]),
            .single(glyph: .symbol("hammer.fill"), trailing: .clock(since: at(100)))
        )
    }

    func test_singleActivity_withoutSince_showsStaticText() {
        let a = placed(value: "run-1",
                       activity: ActivityStyle(glyph: .symbol("hammer.fill"), trailing: "queued"))
        XCTAssertEqual(
            derivePillState(from: [a]),
            .single(glyph: .symbol("hammer.fill"), trailing: .text("queued"))
        )
    }

    // MARK: - ≥2 activities → many

    func test_twoActivities_sameNoun_summarizesWithSharedNoun() {
        let a = placed(value: "run-1",
                       activity: ActivityStyle(glyph: .symbol("hammer.fill"), since: at(200), noun: "deploy"))
        let b = placed(value: "run-2",
                       activity: ActivityStyle(glyph: .symbol("hammer.fill"), since: at(150), noun: "deploy"))
        // Earliest `since` (150) = the longest-running deploy → that clock leads the summary.
        XCTAssertEqual(
            derivePillState(from: [a, b]),
            .many(count: 2, noun: "deploy", trailing: .clock(since: at(150)))
        )
    }

    func test_manyActivities_clockTracksLongestRunning() {
        let a = placed(value: "r1", activity: ActivityStyle(glyph: .symbol("x"), since: at(300), noun: "deploy"))
        let b = placed(value: "r2", activity: ActivityStyle(glyph: .symbol("x"), since: at(90), noun: "deploy"))
        let c = placed(value: "r3", activity: ActivityStyle(glyph: .symbol("x"), since: at(180), noun: "deploy"))
        guard case let .many(count, _, trailing) = derivePillState(from: [a, b, c]) else {
            return XCTFail("expected .many")
        }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(trailing, .clock(since: at(90)))  // earliest start = longest elapsed
    }

    func test_mixedNouns_fallBackToNeutral() {
        let a = placed(value: "r1", activity: ActivityStyle(glyph: .symbol("x"), since: at(200), noun: "deploy"))
        let b = placed(value: "r2", activity: ActivityStyle(glyph: .symbol("y"), since: at(150), noun: "download"))
        XCTAssertEqual(
            derivePillState(from: [a, b]),
            .many(count: 2, noun: nil, trailing: .clock(since: at(150)))
        )
    }

    // MARK: - cross-source merge (the whole point of putting this in Core)

    func test_activitiesFromDifferentSources_mergeIntoOnePill() {
        let gh = placed(source: "gh", value: "r1",
                        activity: ActivityStyle(glyph: .symbol("x"), since: at(200), noun: "deploy"))
        let cal = placed(source: "calendar", value: "m1",
                         activity: ActivityStyle(glyph: .symbol("video"), since: at(150), noun: "meeting"))
        guard case let .many(count, noun, trailing) = derivePillState(from: [gh, cal]) else {
            return XCTFail("expected .many across sources")
        }
        XCTAssertEqual(count, 2)
        XCTAssertNil(noun)                              // different nouns → neutral summary
        XCTAssertEqual(trailing, .clock(since: at(150)))
    }
}
