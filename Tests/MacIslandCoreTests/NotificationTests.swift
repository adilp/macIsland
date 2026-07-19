import XCTest
@testable import MacIslandCore

/// `Notification` collides with `Foundation.Notification` (pulled in via XCTest);
/// pin the bare name to our value type for readable type-position use in tests.
private typealias Notification = MacIslandCore.Notification

/// Tests for the canonical `Notification` value type and its sub-types.
/// The value is pure, serializable, and illegal-state-proofed — no I/O, no UI.
/// Seam: the value's public initializers and its `Codable` conformance.
final class NotificationTests: XCTestCase {

    // MARK: - Defaults (ticket: "Only `title` is required; `.transient` defaults to ≈5s")

    func test_titleOnlyNotification_hasCalmDefaults() {
        let n = Notification(
            id: NotificationID(source: SourceID(raw: "dev"), value: "1"),
            content: Content(title: "Hello")
        )

        XCTAssertEqual(n.content.title, "Hello")
        XCTAssertNil(n.content.body)
        XCTAssertNil(n.content.icon)
        XCTAssertNil(n.content.tint)
        XCTAssertEqual(n.actions, [])
        XCTAssertEqual(n.presence, .transient(after: .seconds(5)))
        XCTAssertEqual(n.alerting, .silent)
    }

    func test_ringing_defaultsTo120sTimeout() {
        // A source that asks to ring "without a timeout" gets the core's 120s default.
        XCTAssertEqual(Alerting.ringing(), .ringing(timeout: .seconds(120)))
        XCTAssertEqual(Alerting.defaultRingTimeout, .seconds(120))
    }

    func test_action_dismissOnTap_defaultsTrue() {
        // Firing an action auto-dismisses by default; a source opts out per action.
        let act = Action(label: "Open", behavior: .callback("open"))
        XCTAssertTrue(act.dismissOnTap)

        let sticky = Action(label: "Snooze", behavior: .callback("snooze"), dismissOnTap: false)
        XCTAssertFalse(sticky.dismissOnTap)
    }

    // MARK: - Serializable, no closures/live objects (ticket: "are Codable/serializable")

    func test_fullyPopulatedNotification_codableRoundTrips() throws {
        // Exercises every case that carries payload — symbol/image icons, both
        // action behaviors, sticky presence, ringing alerting. That it round-trips
        // at all proves the value holds no closures or live objects.
        //
        // NB: this asserts closure-freedom and Swift-to-Swift losslessness only —
        // NOT a wire shape. Synthesized `Codable` emits opaque forms (e.g. a
        // `Duration` becomes a two-int array), so this JSON is not the ingress
        // format; the human-readable wire codec is ticket 04's separate layer.
        let original = Notification(
            id: NotificationID(source: SourceID(raw: "ingress:demo"), value: "abc"),
            content: Content(
                title: "Deploy finished",
                body: "web-api • 42s",
                icon: .symbol("checkmark.seal"),
                tint: "#34C759"
            ),
            actions: [
                Action(label: "Open", behavior: .openURL(URL(string: "https://example.com")!)),
                Action(label: "Snooze", behavior: .callback("snooze"), dismissOnTap: false),
            ],
            presence: .sticky,
            alerting: .ringing(timeout: .seconds(120))
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Notification.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func test_imageDataIcon_codableRoundTrips() throws {
        // The in-process `.data` raster path also serializes cleanly.
        let n = Notification(
            id: NotificationID(source: SourceID(raw: "swift"), value: "1"),
            content: Content(title: "Pic", icon: .image(.data(Data([0x89, 0x50, 0x4E, 0x47]))))
        )
        let decoded = try JSONDecoder().decode(
            Notification.self, from: try JSONEncoder().encode(n))
        XCTAssertEqual(decoded, n)
    }

    // MARK: - Illegal-state-proofing (ticket: "illegal states are unrepresentable")
    //
    // These are compile-time guarantees; the following simply *cannot* be written,
    // which is the proof — the tests below pin the legal shape and its invariants:
    //   • Presence.sticky(after: …)           — sticky carries no duration
    //   • Presence.transient                   — a transient without a duration
    //   • a second, separate "priority" field  — tier is derived from presence
    //   • Content()                            — a notification with no title

    func test_transientDuration_livesInsideTheCase_perCard() {
        // The duration is inseparable from `.transient` (no sticky-with-timer, no
        // transient-without-duration), and each card carries its own.
        guard case let .transient(after: short) = Presence.transient(after: .seconds(5)),
              case let .transient(after: long) = Presence.transient(after: .seconds(600))
        else { return XCTFail("expected transient cases") }

        XCTAssertEqual(short, .seconds(5))
        XCTAssertEqual(long, .seconds(600))
    }

    func test_tier_isDerivedFromPresence_notAStoredPriority() {
        // The only source of tier is the current presence — no priority-inflation.
        XCTAssertEqual(Presence.sticky.tier, .sticky)
        XCTAssertEqual(Presence.transient(after: .seconds(5)).tier, .transient)
        XCTAssertTrue(Tier.sticky < Tier.transient)  // sticky renders above transient
    }

    func test_presenceAndAlerting_areOrthogonal_everyComboRepresentable() {
        // No type rule couples lifetime and sound; the one natural coupling (a
        // ringing card shouldn't silently vanish) is the *source* choosing
        // `.sticky`, not the model. All six combinations are constructible.
        let presences: [Presence] = [.sticky, .transient(after: .seconds(5))]
        let alertings: [Alerting] = [.silent, .soundOnce, .ringing()]

        for p in presences {
            for a in alertings {
                let n = Notification(
                    id: NotificationID(source: SourceID(raw: "dev"), value: "x"),
                    content: Content(title: "t"),
                    presence: p,
                    alerting: a
                )
                XCTAssertEqual(n.presence, p)
                XCTAssertEqual(n.alerting, a)
            }
        }
    }
}
