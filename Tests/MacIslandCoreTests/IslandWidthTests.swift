import XCTest
import CoreGraphics
@testable import MacIslandCore

/// `Notification` collides with `Foundation.Notification` (via XCTest); pin the bare
/// name to our value type.
private typealias Notification = MacIslandCore.Notification

/// Tests for the island's **width regime** — the pure decision of how wide the panel
/// should be given what's on it. Three postures: `bare` hugs the notch exactly (so the
/// idle island reads as the notch, not a fat pill), `peek` widens modestly for a
/// running activity, and `expanded` opens to the full downward sheet. The regime is a
/// total function of the same inputs the view branches on (cards + hover), so the
/// controller sizes the window and the view lays out to one agreed width.
final class IslandWidthTests: XCTestCase {

    // MARK: - Fixtures

    private func placed(value: String, activity: ActivityStyle?) -> PlacedNotification {
        let n = Notification(
            id: NotificationID(source: SourceID(raw: "gh"), value: value),
            content: Content(title: value),
            presence: .sticky,
            alerting: .silent,
            activity: activity
        )
        return PlacedNotification(notification: n, receivedAt: Date(timeIntervalSinceReferenceDate: 0))
    }

    private func activityCard(_ value: String) -> PlacedNotification {
        placed(value: value, activity: ActivityStyle(glyph: .symbol("hammer.fill")))
    }

    private func plainCard(_ value: String) -> PlacedNotification {
        placed(value: value, activity: nil)
    }

    /// A notched built-in: ~200 pt notch centered, 37 pt band.
    private func notched() -> ScreenMetrics {
        ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 37,
            auxiliaryTopLeft: CGRect(x: 0, y: 948, width: 656, height: 34),
            auxiliaryTopRight: CGRect(x: 856, y: 948, width: 656, height: 34)
        )
    }

    private func nonNotched() -> ScreenMetrics {
        ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                      safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
    }

    // MARK: - Regime: mirrors the view's bare / peek / content branching

    func test_nothing_isBare() {
        XCTAssertEqual(islandWidthRegime(cards: [], isHovering: false), .bare)
        XCTAssertEqual(islandWidthRegime(cards: [], isHovering: true), .bare)
    }

    func test_runningActivityAlone_collapsedIsPeek() {
        let cards = [activityCard("run-1")]
        XCTAssertEqual(islandWidthRegime(cards: cards, isHovering: false), .peek)
    }

    func test_manyActivities_collapsedStillPeek() {
        let cards = [activityCard("r1"), activityCard("r2")]
        XCTAssertEqual(islandWidthRegime(cards: cards, isHovering: false), .peek)
    }

    func test_activityOnHover_expandsToFullSheet() {
        // Hovering unrolls the activity into a full card row → expanded.
        let cards = [activityCard("run-1")]
        XCTAssertEqual(islandWidthRegime(cards: cards, isHovering: true), .expanded)
    }

    func test_plainCard_isExpanded_evenCollapsed() {
        // A toast / failure card is not pill-resident; it shows as a card → expanded.
        let cards = [plainCard("toast")]
        XCTAssertEqual(islandWidthRegime(cards: cards, isHovering: false), .expanded)
    }

    func test_activityPlusPlainCard_isExpanded() {
        // The plain card is visible in the sheet even while collapsed → expanded.
        let cards = [activityCard("run-1"), plainCard("toast")]
        XCTAssertEqual(islandWidthRegime(cards: cards, isHovering: false), .expanded)
    }

    // MARK: - Width: bare hugs the notch, peek widens modestly, expanded is the sheet

    func test_bare_hugsNotchWidthExactly() {
        XCTAssertEqual(islandWidth(for: .bare, on: notched()), 200)          // == notch width
    }

    func test_bare_fallsBackToCompactPillWithoutNotch() {
        XCTAssertEqual(islandWidth(for: .bare, on: nonNotched()), floatingPillWidth)
    }

    func test_peek_widensModestlyPastNotch_notTheFullSheet() {
        let peek = islandWidth(for: .peek, on: notched())
        XCTAssertEqual(peek, 200 + peekWideningPastNotch)
        XCTAssertLessThan(peek, expandedIslandWidth)                          // not obnoxious
        XCTAssertGreaterThan(peek, islandWidth(for: .bare, on: notched()))    // wider than idle
    }

    func test_expanded_isTheFullSheet_onATypicalNotch() {
        XCTAssertEqual(islandWidth(for: .expanded, on: notched()), expandedIslandWidth)  // 200+40 < 440
        XCTAssertEqual(islandWidth(for: .expanded, on: nonNotched()), expandedIslandWidth)
    }

    func test_expanded_hugsAnUnusuallyWideNotch() {
        // A hypothetical notch wider than the base sheet still gets a hug margin.
        let wide = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 37,
            auxiliaryTopLeft: CGRect(x: 0, y: 948, width: 500, height: 34),
            auxiliaryTopRight: CGRect(x: 1012, y: 948, width: 500, height: 34)   // 512 pt notch
        )
        XCTAssertEqual(islandWidth(for: .expanded, on: wide), 512 + expandedNotchHugMargin)
    }
}
