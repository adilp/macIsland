import CoreGraphics

/// The pure, testable geometry of one display — the notch metrics and the island's
/// anchor math, lifted out of `NSScreen` so they can be unit-tested without a live
/// display (walking-skeleton ticket, criterion 5). Production builds one of these
/// from an `NSScreen` (see the app's `NSScreen` adapter); tests construct rects by
/// hand. Everything here is in **points**, **bottom-left origin** (y-up), read from
/// `frame` (never `visibleFrame`) — the notch overlaps the menu-bar band, which
/// lives in `frame` (notch/window spec §1).
public struct ScreenMetrics: Equatable, Sendable {
    /// The full display frame — `NSScreen.frame`, bottom-left origin. External
    /// screens carry a non-zero origin, so `midX`/`maxY` are already in the global
    /// screen-coordinate space `NSWindow.setFrame` expects.
    public let frame: CGRect
    /// `safeAreaInsets.top` — the notch/menu-bar band height; 0 on non-notched and
    /// external displays.
    public let safeAreaTop: CGFloat
    /// The unobscured strip left of the notch (`auxiliaryTopLeftArea`); `nil` when
    /// there is no notch — that nil is the no-notch signal (spec §1).
    public let auxiliaryTopLeft: CGRect?
    /// The unobscured strip right of the notch (`auxiliaryTopRightArea`); `nil` when
    /// there is no notch.
    public let auxiliaryTopRight: CGRect?

    public init(
        frame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?
    ) {
        self.frame = frame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
    }

    /// A notched built-in display exposes **both** auxiliary top areas; external and
    /// older screens expose neither.
    public var hasNotch: Bool {
        auxiliaryTopLeft != nil && auxiliaryTopRight != nil
    }

    /// Notch height in points; 0 on non-notched / external displays.
    public var notchHeight: CGFloat { safeAreaTop }

    /// Notch width in points — the gap between the two aux rects — or `nil` when
    /// there is no notch.
    public var notchWidth: CGFloat? {
        guard let l = auxiliaryTopLeft, let r = auxiliaryTopRight else { return nil }
        return r.minX - l.maxX
    }

    /// Horizontal center of the notch, in the global coordinate space (== the
    /// screen's own center; on the built-in display that is also the notch center).
    public var notchCenterX: CGFloat { frame.midX }
}

/// The island's fraction-of-screen height ceiling: past this the panel stops
/// growing and the stack scrolls internally (unified spec R3 / ticket "height
/// capped at `min(content, ~72% screen)`").
public let defaultMaxHeightFraction: CGFloat = 0.72

/// The top-center anchor frame for an island of `islandSize` on `metrics`.
///
/// Bottom-left origin: the island is pinned to the **top** of the screen
/// (`frame.maxY`) and **grows downward** — as height grows, `origin.y` shrinks. The
/// height is capped at `min(islandSize.height, maxHeightFraction · screenHeight)`;
/// beyond the cap the panel holds its size and the stack scrolls inside it.
public func anchorFrame(
    islandSize: CGSize,
    on metrics: ScreenMetrics,
    maxHeightFraction: CGFloat = defaultMaxHeightFraction
) -> CGRect {
    let cappedHeight = min(islandSize.height, metrics.frame.height * maxHeightFraction)
    let x = metrics.notchCenterX - islandSize.width / 2
    let y = metrics.frame.maxY - cappedHeight            // top-pinned; grows downward
    return CGRect(x: x, y: y, width: islandSize.width, height: cappedHeight)
}

/// Pick the island's home display from `screens` (in `NSScreen.screens` order):
/// the notched screen if one exists, else the menu-bar screen (index 0). Returns
/// `nil` only when there are no screens.
///
/// The island lives on the **built-in display only** and never migrates to an
/// external monitor (spec §4): searching for the notch first (rather than assuming
/// index 0) keeps it on the built-in even when the user has moved the menu bar to an
/// external display, and the index-0 fallback is the menu-bar/built-in screen —
/// never an external one. We deliberately do **not** use `NSScreen.main` (the
/// key-window screen) or follow the mouse.
public func targetScreenIndex(in screens: [ScreenMetrics]) -> Int? {
    if let notched = screens.firstIndex(where: { $0.hasNotch }) { return notched }
    return screens.isEmpty ? nil : 0
}
