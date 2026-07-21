import XCTest
@testable import MacIslandCore

/// `Notification` collides with `Foundation.Notification` (via XCTest); pin the bare
/// name to our value type.
private typealias Notification = MacIslandCore.Notification

/// Tests for the source-agnostic pill/activity summary — the island's ambient
/// (in-pill) layer, orthogonal to the downward card stack. Pure: no core, no clock,
/// no UI. Seam: the `derivePillState` free function over the render order. Models the
/// Dynamic Island: one activity leads, the rest collapse to a minimal "+N".
final class PillStateTests: XCTestCase {

    private func placed(
        source: String = "gh",
        value: String,
        activity: ActivityStyle?,
        tint: String? = nil,
        alerting: Alerting = .silent,
        receivedAt t: TimeInterval = 0
    ) -> PlacedNotification {
        let n = Notification(
            id: NotificationID(source: SourceID(raw: source), value: value),
            content: Content(title: value, tint: tint),
            presence: .sticky,
            alerting: alerting,
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
        let cards = [placed(value: "a", activity: nil), placed(value: "b", activity: nil)]
        XCTAssertEqual(derivePillState(from: cards), .bare)
    }

    // MARK: - 1 activity → single (carries glyph, tint, trailing)

    func test_singleActivity_withSince_showsLiveClock() {
        let a = placed(value: "run-1",
                       activity: ActivityStyle(glyph: .symbol("hammer.fill"), since: at(100)))
        XCTAssertEqual(
            derivePillState(from: [a]),
            .single(glyph: .symbol("hammer.fill"), tint: nil, trailing: .clock(since: at(100)))
        )
    }

    func test_singleActivity_carriesTint() {
        let a = placed(value: "run-1",
                       activity: ActivityStyle(glyph: .symbol("checkmark.circle.fill"), trailing: "done"),
                       tint: "#30D158")
        XCTAssertEqual(
            derivePillState(from: [a]),
            .single(glyph: .symbol("checkmark.circle.fill"), tint: "#30D158", trailing: .text("done"))
        )
    }

    // MARK: - ≥2 activities → leader + minimal "+N"

    func test_twoActivities_leadPlusMinimal() {
        // Equal relevance → the first in render order (nearest the notch) leads.
        let a = placed(value: "run-1", activity: ActivityStyle(glyph: .symbol("shippingbox.fill"), since: at(200)))
        let b = placed(value: "run-2", activity: ActivityStyle(glyph: .symbol("shippingbox.fill"), since: at(150)))
        XCTAssertEqual(
            derivePillState(from: [a, b]),
            .leadingPlusMinimal(glyph: .symbol("shippingbox.fill"), tint: nil,
                                trailing: .clock(since: at(200)), extra: 1)
        )
    }

    func test_threeActivities_extraCountIsTwo() {
        let a = placed(value: "r1", activity: ActivityStyle(glyph: .symbol("x"), since: at(300)))
        let b = placed(value: "r2", activity: ActivityStyle(glyph: .symbol("x"), since: at(200)))
        let c = placed(value: "r3", activity: ActivityStyle(glyph: .symbol("x"), since: at(100)))
        guard case let .leadingPlusMinimal(_, _, _, extra) = derivePillState(from: [a, b, c]) else {
            return XCTFail("expected leader + minimal")
        }
        XCTAssertEqual(extra, 2)
    }

    // MARK: - relevance decides the leader (Apple's relevanceScore)

    func test_higherRelevanceLeads_evenIfNotFirstInOrder() {
        // A build (relevance 0) sits nearest the notch; a meeting-style peek (relevance 1)
        // is further down — the higher-relevance one must still lead the pill.
        let build = placed(source: "github", value: "run-1",
                           activity: ActivityStyle(glyph: .symbol("shippingbox.fill"), since: at(50)))
        let meeting = placed(source: "calendar", value: "m1",
                             activity: ActivityStyle(glyph: .symbol("video.fill"), since: at(80), relevance: 1))
        XCTAssertEqual(
            derivePillState(from: [build, meeting]),   // build is first in order…
            .leadingPlusMinimal(glyph: .symbol("video.fill"), tint: nil,   // …but the meeting leads
                                trailing: .clock(since: at(80)), extra: 1)
        )
    }

    func test_equalRelevance_firstInOrderLeads() {
        let first = placed(value: "r1", activity: ActivityStyle(glyph: .symbol("a"), since: at(10)))
        let second = placed(value: "r2", activity: ActivityStyle(glyph: .symbol("b"), since: at(20)))
        guard case let .leadingPlusMinimal(glyph, _, _, _) = derivePillState(from: [first, second]) else {
            return XCTFail("expected leader + minimal")
        }
        XCTAssertEqual(glyph, .symbol("a"))   // render-order tie-break
    }

    // MARK: - cross-source merge (the whole point of putting this in Core)

    func test_activitiesFromDifferentSources_mergeIntoOnePill() {
        let gh = placed(source: "gh", value: "r1", activity: ActivityStyle(glyph: .symbol("x"), since: at(200)))
        let cal = placed(source: "calendar", value: "m1", activity: ActivityStyle(glyph: .symbol("video"), since: at(150)))
        guard case let .leadingPlusMinimal(_, _, _, extra) = derivePillState(from: [gh, cal]) else {
            return XCTFail("expected a merged pill across sources")
        }
        XCTAssertEqual(extra, 1)
    }
}
