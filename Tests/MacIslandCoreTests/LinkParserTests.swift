import XCTest
@testable import MacIslandCore

/// Tests for the ported `LinkParser` — the pure Google Meet + Zoom regex, decoupled
/// from EventKit so it runs headless (the reference searched an `EKEvent`; the port
/// takes the notes/location/url text fields directly). Calendar spec §7: "ported
/// as-is … searches notes/location/url".
final class LinkParserTests: XCTestCase {

    func test_parsesGoogleMeetFromNotes() {
        let link = LinkParser.extractVideoLink(
            notes: "Join here: https://meet.google.com/abc-defg-hij see you",
            location: nil, url: nil)
        XCTAssertEqual(link?.type, .googleMeet)
        XCTAssertEqual(link?.url.absoluteString, "https://meet.google.com/abc-defg-hij")
    }

    func test_parsesZoomFromLocation() {
        let link = LinkParser.extractVideoLink(
            notes: nil,
            location: "https://company.zoom.us/j/123456789?pwd=abc-DEF",
            url: nil)
        XCTAssertEqual(link?.type, .zoom)
        XCTAssertEqual(link?.url.absoluteString, "https://company.zoom.us/j/123456789?pwd=abc-DEF")
    }

    func test_parsesZoomFromUrlField() {
        let link = LinkParser.extractVideoLink(
            notes: nil, location: nil,
            url: "https://zoom.us/j/987654321")
        XCTAssertEqual(link?.type, .zoom)
    }

    func test_prefersGoogleMeetWhenBothPresent() {
        let link = LinkParser.extractVideoLink(
            notes: "https://zoom.us/j/1 and https://meet.google.com/abc-defg-hij",
            location: nil, url: nil)
        XCTAssertEqual(link?.type, .googleMeet)
    }

    func test_noLinkWhenNoneMatches() {
        XCTAssertNil(LinkParser.extractVideoLink(
            notes: "phone call, no video", location: "Room 4", url: "https://example.com"))
    }

    func test_noLinkWhenAllFieldsNil() {
        XCTAssertNil(LinkParser.extractVideoLink(notes: nil, location: nil, url: nil))
    }

    func test_displayNames() {
        XCTAssertEqual(VideoLinkType.googleMeet.displayName, "Meet")
        XCTAssertEqual(VideoLinkType.zoom.displayName, "Zoom")
    }
}
