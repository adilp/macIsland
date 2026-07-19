import Foundation

/// The video-conferencing providers macIsland recognizes. Ported from the reference's
/// `LinkParser` (Calendar spec §7 — "Google Meet + Zoom … Teams/Webex a later parser
/// addition, out of scope now"). `displayName` labels the **Join** button per provider
/// ("Join Meet" / "Join Zoom").
public enum VideoLinkType: Equatable, Sendable {
    case googleMeet
    case zoom

    /// The provider name used in the Join action label.
    public var displayName: String {
        switch self {
        case .googleMeet: return "Meet"
        case .zoom: return "Zoom"
        }
    }
}

/// A parsed video-conference link: the URL the core opens on **Join** and the provider
/// it belongs to. A plain value — no EventKit — so it serializes cleanly into an
/// `Action.openURL` and is testable headless.
public struct VideoLink: Equatable, Sendable {
    public let url: URL
    public let type: VideoLinkType

    public init(url: URL, type: VideoLinkType) {
        self.url = url
        self.type = type
    }
}

/// Extracts a video-conference link from a meeting's text fields. **Ported as-is** from
/// the reference (Calendar spec §7): the same Google Meet + Zoom regexes, searching
/// notes/location/url — but decoupled from `EKEvent` so it's a pure function over the
/// text fields (the EventKit adapter supplies them). Google Meet is preferred when both
/// are present.
enum LinkParser {
    /// Search `notes`, `location`, and `url` (in that joined order) for a known link.
    /// The patterns are built as locals rather than shared statics — a `Regex` isn't
    /// `Sendable`, and parsing runs at fetch time (not a hot path), so per-call compile
    /// is fine and keeps the type free of global mutable state.
    static func extractVideoLink(notes: String?, location: String?, url: String?) -> VideoLink? {
        // Google Meet: https://meet.google.com/abc-defg-hij
        let meetPattern = #/https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}/#
        // Zoom: https://zoom.us/j/123456789 or https://company.zoom.us/j/123456789?pwd=xxx
        let zoomPattern = #/https://[\w-]*\.?zoom\.us/j/\d+(\?pwd=[\w-]+)?/#

        let searchText = [notes, location, url]
            .compactMap { $0 }
            .joined(separator: " ")

        // Google Meet first.
        if let match = searchText.firstMatch(of: meetPattern),
           let url = URL(string: String(match.output)) {
            return VideoLink(url: url, type: .googleMeet)
        }
        // Then Zoom (the regex has a capture group, so `.output.0` is the full match).
        if let match = searchText.firstMatch(of: zoomPattern),
           let url = URL(string: String(match.output.0)) {
            return VideoLink(url: url, type: .zoom)
        }
        return nil
    }
}
