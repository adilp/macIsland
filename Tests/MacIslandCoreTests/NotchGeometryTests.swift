import XCTest
import CoreGraphics
@testable import MacIslandCore

/// Tests for the pure notch geometry — `ScreenMetrics` and the anchor/target math
/// extracted from `NSScreen` so the walking-skeleton ticket's criterion 5 ("pure
/// notch-geometry/anchor functions are unit-tested against notched, non-notched, and
/// external-screen rects") holds without a live display. Bottom-left origin, points.
final class NotchGeometryTests: XCTestCase {

    // MARK: - Fixtures (realistic 14" MacBook + a couple of externals)

    /// A notched built-in: 1512×982, ~200 pt notch centered, 37 pt band.
    private func notchedBuiltIn() -> ScreenMetrics {
        ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 37,
            auxiliaryTopLeft: CGRect(x: 0, y: 948, width: 656, height: 34),
            auxiliaryTopRight: CGRect(x: 856, y: 948, width: 656, height: 34)
        )
    }

    /// A non-notched built-in (older MacBook / iMac): band height 0, no aux areas.
    private func nonNotchedBuiltIn() -> ScreenMetrics {
        ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            safeAreaTop: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil
        )
    }

    /// An external monitor placed to the right of the built-in (non-zero origin.x).
    private func externalRight() -> ScreenMetrics {
        ScreenMetrics(
            frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            safeAreaTop: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil
        )
    }

    // MARK: - hasNotch / notchWidth / notchCenterX

    func test_hasNotch_trueOnlyWhenBothAuxAreasPresent() {
        XCTAssertTrue(notchedBuiltIn().hasNotch)
        XCTAssertFalse(nonNotchedBuiltIn().hasNotch)
        XCTAssertFalse(externalRight().hasNotch)
    }

    func test_notchWidth_isGapBetweenAuxAreas_nilWhenNoNotch() {
        XCTAssertEqual(notchedBuiltIn().notchWidth, 200)          // 856 - 656
        XCTAssertNil(nonNotchedBuiltIn().notchWidth)
        XCTAssertNil(externalRight().notchWidth)
    }

    func test_notchHeight_isSafeAreaTop() {
        XCTAssertEqual(notchedBuiltIn().notchHeight, 37)
        XCTAssertEqual(nonNotchedBuiltIn().notchHeight, 0)
    }

    func test_notchCenterX_isFrameMidX_respectingOrigin() {
        XCTAssertEqual(notchedBuiltIn().notchCenterX, 756)        // 1512/2
        XCTAssertEqual(externalRight().notchCenterX, 2472)        // 1512 + 1920/2
    }

    // MARK: - anchorFrame: top-pinned, grows downward, 72% cap

    func test_anchorFrame_isTopCenteredAndGrowsDownward() {
        let m = notchedBuiltIn()
        let f = anchorFrame(islandSize: CGSize(width: 220, height: 100), on: m)
        XCTAssertEqual(f.width, 220)
        XCTAssertEqual(f.height, 100)
        XCTAssertEqual(f.midX, m.notchCenterX, accuracy: 0.001)   // centered under the notch
        XCTAssertEqual(f.maxY, m.frame.maxY, accuracy: 0.001)     // top edge pinned to screen top
        XCTAssertEqual(f.origin.y, 882, accuracy: 0.001)          // 982 - 100 (grows downward)
    }

    func test_anchorFrame_capsHeightAt72PercentOfScreen() {
        let m = notchedBuiltIn()
        let tall = anchorFrame(islandSize: CGSize(width: 220, height: 5000), on: m)
        XCTAssertEqual(tall.height, 982 * 0.72, accuracy: 0.001)  // capped, not 5000
        XCTAssertEqual(tall.maxY, m.frame.maxY, accuracy: 0.001)  // still pinned at the top
    }

    func test_anchorFrame_onExternalOriginIsInThatScreensSpace() {
        let m = externalRight()
        let f = anchorFrame(islandSize: CGSize(width: 300, height: 80), on: m)
        XCTAssertEqual(f.midX, 2472, accuracy: 0.001)             // centered on the external screen
        XCTAssertEqual(f.origin.y, 1000, accuracy: 0.001)        // 1080 - 80
    }

    // MARK: - targetScreenIndex: notched, else built-in (index 0); never external

    func test_targetScreen_prefersNotchedScreen() {
        // Menu bar (index 0) on an external, notched built-in at index 1 → still pick the notch.
        XCTAssertEqual(targetScreenIndex(in: [externalRight(), notchedBuiltIn()]), 1)
        XCTAssertEqual(targetScreenIndex(in: [notchedBuiltIn(), externalRight()]), 0)
    }

    func test_targetScreen_fallsBackToMenuBarScreenWhenNoNotch() {
        // No notch anywhere → index 0 (the built-in/menu-bar screen), never the external.
        XCTAssertEqual(targetScreenIndex(in: [nonNotchedBuiltIn(), externalRight()]), 0)
        XCTAssertEqual(targetScreenIndex(in: [nonNotchedBuiltIn()]), 0)
    }

    func test_targetScreen_nilWhenNoScreens() {
        XCTAssertNil(targetScreenIndex(in: []))
    }
}
