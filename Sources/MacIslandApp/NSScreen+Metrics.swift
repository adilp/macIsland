import AppKit
import MacIslandCore

/// The thin production adapter from a live `NSScreen` to the pure, testable
/// `ScreenMetrics` (notch/window spec §1). All the geometry decisions live in
/// `MacIslandCore` over `ScreenMetrics`; this file only reads the public `NSScreen`
/// API — no private APIs, no hard-coded pixel constants.
extension NSScreen {
    /// This display's notch metrics as a plain value. `auxiliaryTop{Left,Right}Area`
    /// surface in Swift as `NSRect?`, yielding `nil` on non-notched/external screens —
    /// that nil is the no-notch signal `ScreenMetrics.hasNotch` reads.
    var metrics: ScreenMetrics {
        ScreenMetrics(
            frame: frame,                                    // frame, never visibleFrame
            safeAreaTop: safeAreaInsets.top,
            auxiliaryTopLeft: auxiliaryTopLeftArea,
            auxiliaryTopRight: auxiliaryTopRightArea
        )
    }
}

/// The island's home display and its metrics, resolved fresh on every anchor:
/// the notched screen, else the menu-bar screen (index 0) — the built-in display
/// only, never an external monitor (spec §4). Returns `nil` only if there are no
/// screens (never at runtime).
@MainActor
func currentTargetScreen() -> (screen: NSScreen, metrics: ScreenMetrics)? {
    let screens = NSScreen.screens
    let metrics = screens.map(\.metrics)
    guard let i = targetScreenIndex(in: metrics) else { return nil }
    return (screens[i], metrics[i])
}
