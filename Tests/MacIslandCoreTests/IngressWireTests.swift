import XCTest
@testable import MacIslandCore

private typealias Notification = MacIslandCore.Notification

/// Tests for `IngressWire` — the pure JSONL ↔ domain-value codec (ingress spec
/// §3–§7). Parsing is asserted directly; encoded lines are decoded back into JSON
/// and asserted field-by-field, so the tests pin the *contract* (which keys/values)
/// rather than a brittle byte layout.
final class IngressWireTests: XCTestCase {

    // Decode an encoded line back to a JSON object so assertions read the contract.
    private func json(_ line: String) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try XCTUnwrap(obj as? [String: Any])
    }

    private func parseNotify(_ line: String, file: StaticString = #filePath, line ln: UInt = #line) throws -> NotifyPayload {
        let req = try IngressWire.parse(line)
        guard case .notify(let p) = req else {
            XCTFail("expected .notify, got \(req)", file: file, line: ln)
            throw IngressError("not notify")
        }
        return p
    }

    // MARK: - Parse: notify

    func test_parse_minimalNotify_isTitleOnlyWithCalmDefaults() throws {
        let p = try parseNotify(#"{"op":"notify","title":"Build done"}"#)
        XCTAssertNil(p.id)                                   // omit → core assigns a UUID
        XCTAssertEqual(p.content.title, "Build done")
        XCTAssertNil(p.content.body)
        XCTAssertNil(p.content.icon)
        XCTAssertEqual(p.presence, .transient(after: .seconds(5)))   // default ≈5s
        XCTAssertEqual(p.alerting, .silent)                          // default silent
        XCTAssertTrue(p.actions.isEmpty)
    }

    func test_parse_fullNotify_mapsEveryFieldOntoTheValue() throws {
        // The complete hand-written example from spec §5.
        let line = ##"{"op":"notify","id":"standup","title":"Standup in 5 min","body":"Daily sync · Zoom","icon":"calendar","tint":"#34C759","presence":"sticky","alerting":"ringing","actions":[{"label":"Join","url":"https://zoom.us/j/123"},{"label":"Snooze","callback":"snooze","dismissOnTap":false}]}"##
        let p = try parseNotify(line)
        XCTAssertEqual(p.id, "standup")
        XCTAssertEqual(p.content.title, "Standup in 5 min")
        XCTAssertEqual(p.content.body, "Daily sync · Zoom")
        XCTAssertEqual(p.content.icon, .symbol("calendar"))
        XCTAssertEqual(p.content.tint, "#34C759")
        XCTAssertEqual(p.presence, .sticky)
        XCTAssertEqual(p.alerting, .ringing())               // core owns the 120s timeout
        XCTAssertEqual(p.actions.count, 2)
        XCTAssertEqual(p.actions[0], Action(label: "Join", behavior: .openURL(URL(string: "https://zoom.us/j/123")!)))
        XCTAssertEqual(p.actions[1], Action(label: "Snooze", behavior: .callback("snooze"), dismissOnTap: false))
    }

    func test_parse_presenceNumber_isTransientSeconds() throws {
        let p = try parseNotify(#"{"op":"notify","title":"x","presence":30}"#)
        XCTAssertEqual(p.presence, .transient(after: .seconds(30)))
    }

    func test_parse_alertingOnce_isSoundOnce() throws {
        let p = try parseNotify(#"{"op":"notify","title":"x","alerting":"once"}"#)
        XCTAssertEqual(p.alerting, .soundOnce)
    }

    func test_parse_iconFileObject_isImageFile() throws {
        let p = try parseNotify(#"{"op":"notify","title":"x","icon":{"file":"/tmp/a.png"}}"#)
        XCTAssertEqual(p.content.icon, .image(.file(URL(fileURLWithPath: "/tmp/a.png"))))
    }

    // MARK: - Parse: hello / revoke

    func test_parse_hello_named_withRevokeOnDisconnect() throws {
        let req = try IngressWire.parse(#"{"hello":{"source":"claude-pm","revokeOnDisconnect":true}}"#)
        XCTAssertEqual(req, .hello(Hello(source: "claude-pm", revokeOnDisconnect: true)))
    }

    func test_parse_hello_anonymousDefault() throws {
        let req = try IngressWire.parse(#"{"hello":{}}"#)
        XCTAssertEqual(req, .hello(Hello(source: nil, revokeOnDisconnect: false)))
    }

    func test_parse_revokeById() throws {
        XCTAssertEqual(try IngressWire.parse(#"{"op":"revoke","id":"standup"}"#), .revoke(value: "standup"))
    }

    func test_parse_revokeAll() throws {
        XCTAssertEqual(try IngressWire.parse(#"{"op":"revoke","all":true}"#), .revokeAll)
    }

    // MARK: - Parse: rejections (spec §5) — each carries the op when known

    private func assertRejected(_ line: String, message: String, op: String?, file: StaticString = #filePath, ln: UInt = #line) {
        XCTAssertThrowsError(try IngressWire.parse(line), file: file, line: ln) { error in
            let e = error as? IngressError
            XCTAssertEqual(e?.message, message, file: file, line: ln)
            XCTAssertEqual(e?.op, op, file: file, line: ln)
        }
    }

    func test_parse_malformedJSON_rejectedWithNoOp() {
        assertRejected(#"{not json"#, message: "malformed JSON", op: nil)
    }

    func test_parse_missingTitle_rejectedAsNotify() {
        assertRejected(#"{"op":"notify","body":"no title"}"#, message: "missing title", op: "notify")
    }

    func test_parse_tooManyActions_rejectedAsNotify() {
        let line = #"{"op":"notify","title":"x","actions":[{"label":"a","callback":"a"},{"label":"b","callback":"b"},{"label":"c","callback":"c"}]}"#
        assertRejected(line, message: "max 2 actions", op: "notify")
    }

    func test_parse_unknownOp_rejected() {
        assertRejected(#"{"op":"frobnicate","title":"x"}"#, message: "unknown op", op: "frobnicate")
    }

    func test_parse_actionWithoutUrlOrCallback_rejected() {
        assertRejected(#"{"op":"notify","title":"x","actions":[{"label":"a"}]}"#,
                       message: "action needs url or callback", op: "notify")
    }

    // MARK: - Encode: acks (spec §5) & events (spec §6)

    func test_encode_okNotify_carriesTheId() throws {
        let j = try json(IngressWire.okNotify(id: "standup"))
        XCTAssertEqual(j["ok"] as? Bool, true)
        XCTAssertEqual(j["id"] as? String, "standup")
    }

    func test_encode_okRevoke_true_and_false() throws {
        XCTAssertEqual(try json(IngressWire.okRevoke(revoked: true))["revoked"] as? Bool, true)
        let gone = try json(IngressWire.okRevoke(revoked: false))
        XCTAssertEqual(gone["ok"] as? Bool, true)
        XCTAssertEqual(gone["revoked"] as? Bool, false)      // unknown/already-gone id (spec §7)
    }

    func test_encode_error_withOp() throws {
        let j = try json(IngressWire.error(IngressError("max 2 actions", op: "notify")))
        XCTAssertEqual(j["error"] as? String, "max 2 actions")
        XCTAssertEqual(j["op"] as? String, "notify")
    }

    func test_encode_error_withoutOp_omitsTheKey() throws {
        let j = try json(IngressWire.error(IngressError("malformed JSON")))
        XCTAssertEqual(j["error"] as? String, "malformed JSON")
        XCTAssertNil(j["op"])                                 // no op known → key absent
    }

    func test_encode_actionEvent() throws {
        let j = try json(IngressWire.actionEvent(id: "standup", action: "snooze"))
        XCTAssertEqual(j["event"] as? String, "action")
        XCTAssertEqual(j["id"] as? String, "standup")
        XCTAssertEqual(j["action"] as? String, "snooze")
    }

    func test_encode_closedEvent_reasonStrings() throws {
        let cases: [(CloseReason, String)] = [
            (.acted, "acted"), (.dismissed, "dismissed"), (.expired, "expired"), (.revoked, "revoked"),
        ]
        for (reason, expected) in cases {
            let j = try json(IngressWire.closedEvent(id: "x", reason: reason))
            XCTAssertEqual(j["event"] as? String, "closed")
            XCTAssertEqual(j["id"] as? String, "x")
            XCTAssertEqual(j["reason"] as? String, expected)
        }
    }

    func test_encode_producesSingleCompactLine() {
        // The wire is one compact JSON object per line, no embedded newline (spec §3).
        let line = IngressWire.closedEvent(id: "x", reason: .acted)
        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("  "))
    }
}
