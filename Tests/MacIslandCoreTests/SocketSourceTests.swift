import XCTest
@testable import MacIslandCore

private typealias Notification = MacIslandCore.Notification

/// Tests for `SocketSource` driven at the in-memory `Connection` seam against a real
/// `IslandCore` (ticket criterion 4) — no socket, no wall-clock. Each block is one
/// acceptance criterion of the Local-JSON-ingress ticket.
@MainActor
final class SocketSourceTests: XCTestCase {

    private let pm = SourceID(raw: "ingress:pm")

    // Decode a written line back to JSON so assertions read the wire contract.
    private func json(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    /// Register a fresh SocketSource for `pm` on a fresh connection against `core`,
    /// wiring the disconnect hook to `unregister` exactly as the host does (so a
    /// dropped connection runs the core's uniform teardown).
    private func makeSource(core: IslandCore, revokeOnDisconnect: Bool = false, firstLine: String? = nil) -> TestConnection {
        let conn = TestConnection()
        let source = SocketSource(
            id: pm, connection: conn, revokeOnDisconnect: revokeOnDisconnect, firstLine: firstLine,
            onDisconnect: { [weak core] id in await core?.unregister(id) }
        )
        core.register(source)
        return conn
    }

    // MARK: - Criterion 1: notify posts a card + ok ack; same id upserts in place

    func test_notify_postsCard_andAcksWithId() async throws {
        let core = IslandCore(clock: TestClock())
        let conn = makeSource(core: core)

        conn.feed(#"{"op":"notify","id":"build","title":"Build done"}"#)
        await conn.awaitOutgoing(count: 1)

        // The card is in the core's stack, stamped under this connection's source.
        XCTAssertEqual(core.ordered.map(\.id.value), ["build"])
        XCTAssertEqual(core.ordered.first?.id.source, pm)
        XCTAssertEqual(core.ordered.first?.notification.content.title, "Build done")
        // …and the ack carries the id.
        let ack = try json(conn.outgoing[0])
        XCTAssertEqual(ack["ok"] as? Bool, true)
        XCTAssertEqual(ack["id"] as? String, "build")
    }

    func test_notify_withoutId_acksACoreAssignedUUID() async throws {
        let core = IslandCore(clock: TestClock())
        let conn = makeSource(core: core)

        conn.feed(#"{"op":"notify","title":"Anon"}"#)
        await conn.awaitOutgoing(count: 1)

        let assigned = try XCTUnwrap(try json(conn.outgoing[0])["id"] as? String)
        XCTAssertFalse(assigned.isEmpty)
        XCTAssertEqual(core.ordered.map(\.id.value), [assigned])   // the ack's id is the card's id
    }

    func test_notify_sameId_upsertsInPlace() async throws {
        let core = IslandCore(clock: TestClock())
        let conn = makeSource(core: core)

        conn.feed(#"{"op":"notify","id":"x","title":"First","presence":"sticky"}"#)
        await conn.awaitOutgoing(count: 1)
        conn.feed(#"{"op":"notify","id":"x","title":"Second","presence":"sticky"}"#)
        await conn.awaitOutgoing(count: 2)

        XCTAssertEqual(core.ordered.map(\.id.value), ["x"])                    // one card, not two
        XCTAssertEqual(core.ordered.first?.notification.content.title, "Second")
    }

    // MARK: - Criterion 2: a malformed line returns an error ack and the connection survives

    func test_malformedLine_errorAck_thenConnectionKeepsWorking() async throws {
        let core = IslandCore(clock: TestClock())
        let conn = makeSource(core: core)

        conn.feed(#"{not valid json"#)
        await conn.awaitOutgoing(count: 1)
        XCTAssertNotNil(try json(conn.outgoing[0])["error"])       // an error ack, not a drop
        XCTAssertTrue(core.ordered.isEmpty)

        // The very next valid line on the SAME connection still posts.
        conn.feed(#"{"op":"notify","id":"ok","title":"Still alive"}"#)
        await conn.awaitOutgoing(count: 2)
        XCTAssertEqual(core.ordered.map(\.id.value), ["ok"])
        XCTAssertEqual(try json(conn.outgoing[1])["ok"] as? Bool, true)
    }

    func test_firstLine_isProcessedBeforeTheReadLoop() async throws {
        // A no-hello connection: the host already read line 1 (a notify) while peeking,
        // and hands it in as `firstLine`; it must still post.
        let core = IslandCore(clock: TestClock())
        let conn = makeSource(core: core, firstLine: #"{"op":"notify","id":"first","title":"Peeked"}"#)

        await conn.awaitOutgoing(count: 1)
        XCTAssertEqual(core.ordered.map(\.id.value), ["first"])
    }

    // MARK: - Criterion 4: revoke idempotent; revoke --all scoped to this source

    // A successful revoke emits *two* lines — the ack and a `closed` self-echo
    // (reason "revoked", spec §5/§6) — which interleave in an unspecified order, so
    // these helpers read the stream by content the way a real client does.
    private func acks(_ conn: TestConnection) throws -> [[String: Any]] {
        try conn.outgoing.map(json).filter { $0["ok"] != nil || $0["error"] != nil }
    }
    private func events(_ conn: TestConnection) throws -> [[String: Any]] {
        try conn.outgoing.map(json).filter { $0["event"] != nil }
    }

    func test_revoke_known_true_unknown_false() async throws {
        let core = IslandCore(clock: TestClock())
        let conn = makeSource(core: core)

        conn.feed(#"{"op":"notify","id":"card","title":"x","presence":"sticky"}"#)
        await conn.awaitOutgoing(count: 1)

        // Revoking a live card: an ok/revoked:true ack + a closed(.revoked) echo.
        conn.feed(#"{"op":"revoke","id":"card"}"#)
        await conn.awaitOutgoing(count: 3)
        let firstRevokeAck = try XCTUnwrap(acks(conn).first { $0["revoked"] != nil })
        XCTAssertEqual(firstRevokeAck["revoked"] as? Bool, true)
        XCTAssertTrue(try events(conn).contains { $0["event"] as? String == "closed" && $0["reason"] as? String == "revoked" })
        XCTAssertTrue(core.ordered.isEmpty)

        // Revoking again (now gone) is still success, revoked:false, and — since nothing
        // was removed — no second closed echo (idempotent, spec §7).
        conn.feed(#"{"op":"revoke","id":"card"}"#)
        await conn.awaitOutgoing(count: 4)
        let secondRevokeAck = try XCTUnwrap(acks(conn).last)
        XCTAssertEqual(secondRevokeAck["ok"] as? Bool, true)
        XCTAssertEqual(secondRevokeAck["revoked"] as? Bool, false)
    }

    func test_revokeAll_clearsOnlyThisSourcesCards() async throws {
        let core = IslandCore(clock: TestClock())
        let conn = makeSource(core: core)
        // A second, unrelated source with its own card.
        let other = core.register(SpySource("other"))!
        other.post(Content(title: "keep me"), value: "o1", presence: .sticky)

        conn.feed(#"{"op":"notify","id":"a","title":"a","presence":"sticky"}"#)
        await conn.awaitOutgoing(count: 1)
        conn.feed(#"{"op":"notify","id":"b","title":"b","presence":"sticky"}"#)
        await conn.awaitOutgoing(count: 2)

        // revoke-all → one ok ack + a closed echo per removed card (2 here) = 3 lines.
        conn.feed(#"{"op":"revoke","all":true}"#)
        await conn.awaitOutgoing(count: 5)
        XCTAssertTrue(try acks(conn).contains { $0["ok"] as? Bool == true })

        // Only the ingress source's cards are gone; the other source's card remains.
        XCTAssertEqual(core.ordered.map(\.id.source.raw), ["other"])
        XCTAssertEqual(core.ordered.map(\.id.value), ["o1"])
    }

    func test_reAdoptedSource_revokesInheritedCard_withAccurateAck() async throws {
        let core = IslandCore(clock: TestClock())

        // A first connection posts a sticky card, then drops — the card is left in place.
        let first = makeSource(core: core)
        first.feed(#"{"op":"notify","id":"live","title":"Recording…","presence":"sticky"}"#)
        await first.awaitOutgoing(count: 1)
        first.peerClose()
        await first.awaitClosed()
        XCTAssertEqual(core.ordered.map(\.id.value), ["live"])

        // A new connection re-adopts the same (now vacated) source id (spec §3) and
        // revokes the inherited card. The ack must be revoked:true — read from the core,
        // not from this fresh instance's own history (the re-adoption accuracy fix).
        let second = makeSource(core: core)
        second.feed(#"{"op":"revoke","id":"live"}"#)
        await second.awaitOutgoing(count: 2)
        let ack = try XCTUnwrap(acks(second).first { $0["revoked"] != nil })
        XCTAssertEqual(ack["revoked"] as? Bool, true)
        XCTAssertTrue(core.ordered.isEmpty)
    }

    // MARK: - Criterion 3: action/closed stream to the connection; dropped after disconnect

    func test_actionThenClosed_serializeBackToTheConnection() async throws {
        let core = IslandCore(clock: TestClock())
        let conn = makeSource(core: core)

        conn.feed(#"{"op":"notify","id":"deploy","title":"Deploy?","presence":"sticky","actions":[{"label":"Ship","callback":"ship"}]}"#)
        await conn.awaitOutgoing(count: 1)

        // The user taps the callback action → onAction (a wire `action`), then the card
        // dismisses (default) → onClosed(.acted) (a wire `closed`).
        await core.fireAction(NotificationID(source: pm, value: "deploy"), at: 0)
        await conn.awaitOutgoing(count: 3)

        let action = try json(conn.outgoing[1])
        XCTAssertEqual(action["event"] as? String, "action")
        XCTAssertEqual(action["id"] as? String, "deploy")
        XCTAssertEqual(action["action"] as? String, "ship")

        let closed = try json(conn.outgoing[2])
        XCTAssertEqual(closed["event"] as? String, "closed")
        XCTAssertEqual(closed["reason"] as? String, "acted")
    }

    func test_callbackAfterDisconnect_isDroppedNotQueued() async throws {
        let core = IslandCore(clock: TestClock())
        let conn = makeSource(core: core)

        conn.feed(#"{"op":"notify","id":"pr","title":"Review?","presence":"sticky","actions":[{"label":"Approve","callback":"approve"}]}"#)
        await conn.awaitOutgoing(count: 1)

        // The tool disconnects → uniform teardown → stop() closes the connection.
        conn.peerClose()
        await conn.awaitClosed()

        // The card is left in place (orphan policy), but firing its callback now routes
        // into a vanished source: no event is written — dropped, not queued (spec §6).
        await core.fireAction(NotificationID(source: pm, value: "pr"), at: 0)
        XCTAssertEqual(conn.outgoing.count, 1)          // still just the original ok ack
        XCTAssertEqual(conn.closeCount, 1)
    }

    // MARK: - revokeOnDisconnect (hello flag → source-level, unified spec R1)

    func test_revokeOnDisconnect_autoRevokesCardsOnTeardown() async throws {
        let core = IslandCore(clock: TestClock())
        let conn = makeSource(core: core, revokeOnDisconnect: true)

        conn.feed(#"{"op":"notify","id":"live","title":"Recording…","presence":"sticky"}"#)
        await conn.awaitOutgoing(count: 1)
        XCTAssertEqual(core.ordered.count, 1)

        conn.peerClose()
        await conn.awaitClosed()
        XCTAssertTrue(core.ordered.isEmpty)             // its cards auto-revoked on disconnect
    }
}
