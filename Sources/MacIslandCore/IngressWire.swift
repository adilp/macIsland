import Foundation

/// The **pure** JSONL wire codec — the newline-delimited-JSON ↔ domain-value
/// translation that the ingress is built on (ingress spec §3–§7). It knows nothing
/// of sockets, connections, or the core; it only parses a client→core line into an
/// `IngressRequest` and encodes core→client acks/events into lines. That purity is
/// exactly what lets it (and the `SocketSource` above it) be tested at an in-memory
/// seam with no I/O (ticket criterion 4).
///
/// Direction of the vocabulary (spec §4):
/// - **up** (client→core): `hello` · `notify` (create-or-replace) · `revoke`.
/// - **down** (core→client): `ok`/`error` acks · `action`/`closed` events.

// MARK: - Parsed request (client → core)

/// One decoded client→core line. `notify`'s `id.source` is deliberately absent —
/// the owning `SourceHandle` stamps it, so a wire line can never name another
/// source's namespace (spec §2 / source-API §1, "isolation is structural").
public enum IngressRequest: Equatable {
    case hello(Hello)
    case notify(NotifyPayload)
    case revoke(value: String)
    case revokeAll
}

/// The optional first-line handshake (spec §2, extended by unified spec R1 to carry
/// `revokeOnDisconnect`). A `nil`/empty `source` names an anonymous session.
public struct Hello: Equatable {
    public var source: String?
    public var revokeOnDisconnect: Bool
    public init(source: String? = nil, revokeOnDisconnect: Bool = false) {
        self.source = source
        self.revokeOnDisconnect = revokeOnDisconnect
    }
}

/// A decoded `notify` line (spec §5). Everything the wire carries, mapped onto the
/// domain value — except identity's `source` half (stamped by the handle) and the
/// ring `timeout` (core-owned, off the wire). `id == nil` → the core assigns a UUID.
public struct NotifyPayload: Equatable {
    public var id: String?
    public var content: Content
    public var actions: [Action]
    public var presence: Presence
    public var alerting: Alerting
}

/// A rejected line (spec §5 "Ack"): malformed JSON, unknown op, missing `title`, or
/// `>2` actions. Serialized down as `{"error":…,"op":…}`; `op` is present when the
/// line named one (so `{"error":"max 2 actions","op":"notify"}`), absent when the
/// JSON was too broken to read an op from.
public struct IngressError: Error, Equatable {
    public let message: String
    public let op: String?
    public init(_ message: String, op: String? = nil) {
        self.message = message
        self.op = op
    }
}

// MARK: - The codec

public enum IngressWire {
    /// Parse one client→core JSONL line into a request, or throw an `IngressError`
    /// describing why it was rejected (the connection survives — the caller acks the
    /// error and reads on, spec §3).
    public static func parse(_ line: String) throws -> IngressRequest {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let dict = object as? [String: Any] else {
            throw IngressError("malformed JSON")          // op unknown → no op in the ack
        }
        // Dispatch on the vocabulary (spec §4): a `hello` key is the handshake; every
        // other request names an `op`. Nothing else is valid.
        if let hello = dict["hello"] {
            return .hello(try parseHello(hello))
        }
        switch dict["op"] as? String {
        case "notify":  return .notify(try parseNotify(dict))
        case "revoke":  return try parseRevoke(dict)
        case let other?: throw IngressError("unknown op", op: other)
        case nil:        throw IngressError("missing op")
        }
    }

    private static func parseHello(_ value: Any) throws -> Hello {
        // `{"hello":{…}}`; a bare/empty object is a valid anonymous handshake.
        let dict = value as? [String: Any] ?? [:]
        let source = (dict["source"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Hello(source: source, revokeOnDisconnect: dict["revokeOnDisconnect"] as? Bool ?? false)
    }

    private static func parseRevoke(_ dict: [String: Any]) throws -> IngressRequest {
        if dict["all"] as? Bool == true { return .revokeAll }   // scoped to this source (spec §7)
        guard let id = dict["id"] as? String else {
            throw IngressError("revoke needs id or all", op: "revoke")
        }
        return .revoke(value: id)
    }

    private static func parseNotify(_ dict: [String: Any]) throws -> NotifyPayload {
        guard let title = dict["title"] as? String else {
            throw IngressError("missing title", op: "notify")      // the one required field
        }
        let content = Content(
            title: title,
            body: dict["body"] as? String,
            icon: parseIcon(dict["icon"]),
            tint: dict["tint"] as? String
        )
        return NotifyPayload(
            id: dict["id"] as? String,
            content: content,
            actions: try parseActions(dict["actions"]),
            presence: try parsePresence(dict["presence"]),
            alerting: try parseAlerting(dict["alerting"])
        )
    }

    /// A bare string is an SF Symbol; `{"file":"…"}` is a raster; base64 `.data` is
    /// deliberately wire-absent (spec §5). Anything else is fail-soft → no icon
    /// (rendering is fail-soft too, unified spec §8.3), never a rejected line.
    private static func parseIcon(_ value: Any?) -> Icon? {
        if let name = value as? String { return .symbol(name) }
        if let dict = value as? [String: Any], let path = dict["file"] as? String {
            return .image(.file(URL(fileURLWithPath: path)))
        }
        return nil
    }

    /// `"sticky"` | seconds | omit (→ default ≈5s transient). One field, so
    /// sticky-with-timer is unrepresentable (spec §5, mirrors the model).
    private static func parsePresence(_ value: Any?) throws -> Presence {
        switch value {
        case nil:
            return .transient(after: Notification.defaultTransientDuration)
        case let s as String where s == "sticky":
            return .sticky
        case let n as NSNumber where !isBool(n):
            let seconds = n.doubleValue
            guard seconds >= 0 else { throw IngressError("invalid presence", op: "notify") }
            return .transient(after: .seconds(seconds))
        default:
            throw IngressError("invalid presence", op: "notify")
        }
    }

    /// `"silent"` | `"once"` | `"ringing"` | omit (→ silent). The ring timeout is
    /// core-owned, never on the wire (spec §5).
    private static func parseAlerting(_ value: Any?) throws -> Alerting {
        switch value as? String {
        case nil, "silent": return .silent
        case "once":        return .soundOnce
        case "ringing":     return .ringing()
        default:            throw IngressError("invalid alerting", op: "notify")
        }
    }

    /// 0…2 actions; each is `label` + **either** `url` (→ core-run `openURL`) **xor**
    /// `callback` (→ routed to the source). `dismissOnTap` defaults true (spec §5).
    private static func parseActions(_ value: Any?) throws -> [Action] {
        guard let raw = value else { return [] }
        guard let array = raw as? [[String: Any]] else {
            throw IngressError("actions must be an array", op: "notify")
        }
        guard array.count <= 2 else { throw IngressError("max 2 actions", op: "notify") }
        return try array.map { try parseAction($0) }
    }

    private static func parseAction(_ dict: [String: Any]) throws -> Action {
        guard let label = dict["label"] as? String else {
            throw IngressError("action needs a label", op: "notify")
        }
        let url = dict["url"] as? String
        let callback = dict["callback"] as? String
        let behavior: ActionBehavior
        switch (url, callback) {
        case let (urlString?, nil):
            guard let parsed = URL(string: urlString) else {
                throw IngressError("invalid url", op: "notify")
            }
            behavior = .openURL(parsed)
        case let (nil, callbackID?):
            behavior = .callback(callbackID)
        default:
            // both or neither — the wire's url-xor-callback rule (spec §5).
            throw IngressError("action needs url or callback", op: "notify")
        }
        return Action(label: label, behavior: behavior, dismissOnTap: dict["dismissOnTap"] as? Bool ?? true)
    }

    /// `JSONSerialization` bridges JSON booleans to `NSNumber` too; distinguish them
    /// so `presence: true` isn't misread as `1` second.
    private static func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    // MARK: Request lines (client → core) — the CLI and any Swift client build here

    /// `{"hello":{"source":…,"revokeOnDisconnect":…}}` — the optional handshake (spec
    /// §2 / unified R1). `source == nil` names an anonymous session.
    public static func helloLine(source: String?, revokeOnDisconnect: Bool = false) -> String {
        var hello: [String: Any] = [:]
        if let source { hello["source"] = source }
        if revokeOnDisconnect { hello["revokeOnDisconnect"] = true }
        return line(["hello": hello])
    }

    /// Turn a caller-supplied JSON object into a `notify` line by fixing its `op`
    /// (spec §5). The CLI passes stdin JSON straight through this, so op-injection —
    /// the one transformation — lives in the codec, not in each client.
    public static func notifyLine(from object: [String: Any]) -> String {
        var payload = object
        payload["op"] = "notify"
        return line(payload)
    }

    /// `{"op":"revoke","id":…}` — revoke one card (spec §7).
    public static func revokeLine(id: String) -> String {
        line(["op": "revoke", "id": id])
    }

    /// `{"op":"revoke","all":true}` — revoke every card this source posted (spec §7).
    public static func revokeAllLine() -> String {
        line(["op": "revoke", "all": true])
    }

    // MARK: Acks (core → client) — one per request (spec §5)

    /// `{"ok":true,"id":"<value>"}` — the notify ack, carrying the (possibly
    /// core-assigned) id so a fire-and-forget caller learns the UUID.
    public static func okNotify(id: String) -> String {
        line(["ok": true, "id": id])
    }

    /// `{"ok":true,"revoked":<bool>}` — the revoke ack; `revoked` is false for an
    /// unknown/already-gone id (idempotent success, spec §7).
    public static func okRevoke(revoked: Bool) -> String {
        line(["ok": true, "revoked": revoked])
    }

    /// `{"ok":true}` — the revoke-all ack.
    public static func okRevokeAll() -> String {
        line(["ok": true])
    }

    /// `{"error":…,"op":…}` — a rejected request (spec §5). `op` is present only when
    /// the line named one.
    public static func error(_ error: IngressError) -> String {
        var object: [String: Any] = ["error": error.message]
        if let op = error.op { object["op"] = op }
        return line(object)
    }

    // MARK: Events (core → client) — streamed to the owning connection (spec §6)

    /// `{"event":"action","id":"<value>","action":"<actionID>"}` — a `callback` tap.
    public static func actionEvent(id: String, action: String) -> String {
        line(["event": "action", "id": id, "action": action])
    }

    /// `{"event":"closed","id":"<value>","reason":"<reason>"}` — the card went away.
    public static func closedEvent(id: String, reason: CloseReason) -> String {
        line(["event": "closed", "id": id, "reason": reasonString(reason)])
    }

    /// The four `CloseReason`s on the wire (spec §6): `acted|dismissed|expired|revoked`.
    private static func reasonString(_ reason: CloseReason) -> String {
        switch reason {
        case .acted:     return "acted"
        case .dismissed: return "dismissed"
        case .expired:   return "expired"
        case .revoked:   return "revoked"
        }
    }

    /// One compact, single-line JSON object (spec §3: UTF-8, no embedded newline).
    /// Keys are sorted for a stable, reproducible wire (the reader is field-based, so
    /// order is cosmetic — but a deterministic line is easier to log and diff).
    private static func line(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
