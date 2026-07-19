import Foundation

/// One calendar meeting, reshaped from the reference's `MeetingEvent` into an
/// **internal, SwiftUI-decoupled value** (Calendar spec §7). The reference's
/// `calendarColor: Color` is dropped: this carries the calendar tint as a `"#RRGGBB"`
/// hex string (converted from the event's `CGColor` at the EventKit boundary), so the
/// whole type is a plain value with **no EventKit and no SwiftUI** — constructible in
/// tests and mappable straight onto a domain `Notification`.
///
/// It is no longer `Identifiable`-for-rendering / `View`-bound: a meeting renders as a
/// generic `Notification` card, so this is purely the source's internal fact-carrier.
public struct MeetingEvent: Equatable, Sendable, Identifiable {
    /// The EventKit `eventIdentifier` — also the notification `value`, so T-5 and T-1
    /// share one id and T-1 updates the T-5 in place (spec §4).
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let calendarName: String
    /// The calendar's color as `"#RRGGBB"`, or nil for the theme default. Feeds
    /// `Content.tint`.
    public let tint: String?
    /// The parsed video link, if any. Its presence gates the T-1 ring (spec §3).
    public let videoLink: VideoLink?

    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        calendarName: String,
        tint: String?,
        videoLink: VideoLink?
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.calendarName = calendarName
        self.tint = tint
        self.videoLink = videoLink
    }

    /// Whether this meeting has a joinable video link — the T-1/ring gate.
    public var hasVideoLink: Bool { videoLink != nil }

    /// Static relative-time text for `Content.body` (spec §4: "static relative-time
    /// text, never a live countdown"). Computed once at post time from the injected
    /// clock's `now`, so it costs nothing and never re-posts per tick. Ported from the
    /// reference's `relativeTimeDescription`.
    public func relativeTimeDescription(now: Date) -> String {
        let minutes = Int(startDate.timeIntervalSince(now) / 60)
        if minutes <= 0 {
            return "starting now"
        } else if minutes == 1 {
            return "in 1 minute"
        } else if minutes < 60 {
            return "in \(minutes) minutes"
        } else {
            let hours = minutes / 60
            return hours == 1 ? "in 1 hour" : "in \(hours) hours"
        }
    }
}
