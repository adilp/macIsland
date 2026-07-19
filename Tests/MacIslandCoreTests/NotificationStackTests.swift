import XCTest
@testable import MacIslandCore

/// `Notification` collides with `Foundation.Notification` (pulled in via XCTest);
/// pin the bare name to our value type for readable type-position use in tests.
private typealias Notification = MacIslandCore.Notification

/// Tests for `NotificationStack` — the pure, two-tier stack-ordering logic.
/// No actor, no clock, no timers, no I/O: the caller supplies each card's
/// core-owned `receivedAt`. Ordering, update-in-place, and revoke/dismiss are
/// verified purely. Seam: the stack's public mutating API + its `ordered` output.
final class NotificationStackTests: XCTestCase {

    // MARK: - Helpers

    private let source = SourceID(raw: "dev")

    /// A card with the given id-value and presence; content is just a title.
    private func card(_ value: String, _ presence: Presence) -> Notification {
        Notification(
            id: NotificationID(source: source, value: value),
            content: Content(title: value),
            presence: presence
        )
    }

    /// A deterministic receipt stamp, `s` seconds past the reference date.
    private func at(_ s: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: s) }

    private func orderedValues(_ stack: NotificationStack) -> [String] {
        stack.ordered.map { $0.notification.id.value }
    }

    // MARK: - Ordering (ticket: "sticky tier above transient tier, newest-first within each")

    func test_ordering_stickyAboveTransient_newestFirstWithinTier() {
        var stack = NotificationStack()
        stack.post(card("s1", .sticky), receivedAt: at(1))
        stack.post(card("t2", .transient(after: .seconds(5))), receivedAt: at(2))
        stack.post(card("s3", .sticky), receivedAt: at(3))
        stack.post(card("t4", .transient(after: .seconds(5))), receivedAt: at(4))

        // sticky tier newest-first (s3, s1) sits above transient tier newest-first (t4, t2).
        XCTAssertEqual(orderedValues(stack), ["s3", "s1", "t4", "t2"])
    }

    func test_ordering_isByReceivedAt_notInsertionOrder() {
        var stack = NotificationStack()
        // Insert out of receipt order: the later stamp must still sort nearest the notch.
        stack.post(card("a", .transient(after: .seconds(5))), receivedAt: at(10))
        stack.post(card("b", .transient(after: .seconds(5))), receivedAt: at(20))
        stack.post(card("c", .transient(after: .seconds(5))), receivedAt: at(5))

        XCTAssertEqual(orderedValues(stack), ["b", "a", "c"])
    }

    func test_ordering_equalReceivedAt_laterPostedSitsNearerNotch() {
        // Identical stamps are a genuine tie; the ordering must still be
        // deterministic (not left to sort-stability luck). The later-posted card
        // is the "newer" one, so it sits nearest the notch.
        var stack = NotificationStack()
        stack.post(card("first", .transient(after: .seconds(5))), receivedAt: at(5))
        stack.post(card("second", .transient(after: .seconds(5))), receivedAt: at(5))

        XCTAssertEqual(orderedValues(stack), ["second", "first"])
    }

    // MARK: - Update-in-place (ticket: "full replace preserving receivedAt + position")

    func test_repostSameId_fullyReplacesContent_holdingReceivedAt() {
        var stack = NotificationStack()
        stack.post(card("x", .transient(after: .seconds(5))), receivedAt: at(1))

        // Re-post the same id later, with changed content — a full replace.
        var updated = card("x", .transient(after: .seconds(5)))
        updated.content = Content(title: "x", body: "now with a body")
        stack.post(updated, receivedAt: at(99))

        let placed = stack.placed(for: NotificationID(source: source, value: "x"))
        XCTAssertEqual(stack.ordered.count, 1)                          // no duplicate entry
        XCTAssertEqual(placed?.notification.content.body, "now with a body") // content replaced
        XCTAssertEqual(placed?.receivedAt, at(1))                       // original stamp held
    }

    func test_update_holdsStackPosition_noResortOnRepost() {
        var stack = NotificationStack()
        stack.post(card("old", .transient(after: .seconds(5))), receivedAt: at(1))
        stack.post(card("new", .transient(after: .seconds(5))), receivedAt: at(2))
        XCTAssertEqual(orderedValues(stack), ["new", "old"])

        // Re-post "old" with a late stamp; because the update holds the ORIGINAL
        // receivedAt, it must NOT jump ahead of "new".
        stack.post(card("old", .transient(after: .seconds(5))), receivedAt: at(100))
        XCTAssertEqual(orderedValues(stack), ["new", "old"])
    }

    func test_presenceChange_relocatesTier_butKeepsPositionByReceivedAt() {
        var stack = NotificationStack()
        stack.post(card("a", .sticky), receivedAt: at(1))
        stack.post(card("b", .transient(after: .seconds(5))), receivedAt: at(2))
        stack.post(card("c", .sticky), receivedAt: at(3))
        // sticky: c,a ; transient: b
        XCTAssertEqual(orderedValues(stack), ["c", "a", "b"])

        // Update "b" to sticky (same id). It relocates to the sticky tier but keeps
        // its receivedAt=at(2), so it sits between c(3) and a(1).
        stack.post(card("b", .sticky), receivedAt: at(999))
        XCTAssertEqual(orderedValues(stack), ["c", "b", "a"])
    }

    // MARK: - Revoke vs dismiss (ticket: "revoke removes by id, distinct from dismiss")

    func test_revoke_removesById_andReturnsRemoved() {
        var stack = NotificationStack()
        stack.post(card("keep", .sticky), receivedAt: at(1))
        stack.post(card("gone", .sticky), receivedAt: at(2))

        let removed = stack.revoke(NotificationID(source: source, value: "gone"))
        XCTAssertEqual(removed?.id.value, "gone")
        XCTAssertEqual(orderedValues(stack), ["keep"])
    }

    func test_dismiss_removesById_viaItsOwnEntryPoint() {
        // `dismiss` and `revoke` are separate operations (the user-vs-source
        // distinction). At this pure layer both simply remove by id; the
        // observable difference — which `CloseReason` is reported — is asserted in
        // the next ticket, where the reporting seam exists.
        var stack = NotificationStack()
        stack.post(card("keep", .sticky), receivedAt: at(1))
        stack.post(card("gone", .sticky), receivedAt: at(2))

        let removed = stack.dismiss(NotificationID(source: source, value: "gone"))
        XCTAssertEqual(removed?.id.value, "gone")
        XCTAssertEqual(orderedValues(stack), ["keep"])
    }

    func test_revoke_unknownId_isNoOp() {
        var stack = NotificationStack()
        stack.post(card("a", .sticky), receivedAt: at(1))

        XCTAssertNil(stack.revoke(NotificationID(source: source, value: "nope")))
        XCTAssertEqual(orderedValues(stack), ["a"])
    }
}
