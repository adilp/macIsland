// Identity of a notification: the composite `(source, value)` key.
//
// Many sources coexist, so a bare `"1"` isn't unique. A source can only ever
// update or revoke its *own* notifications — the `source` half is stamped by the
// core-owned `SourceHandle` (ticket 05), so touching another source's card is
// structurally impossible. See the domain-model spec §Identity.

/// Which source emitted a notification. Source-chosen, unique among registered
/// sources (e.g. `"calendar"`, `"ingress:claude-pm"`, `"ingress:anon-7f3…"`).
///
/// Conceptually owned by the source API (ticket 05); defined here because the
/// domain model deferred it and `NotificationID` needs it.
public struct SourceID: Hashable, Codable, Sendable {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

/// Stable, composite identity: `source` (who emitted it) + `value` (unique within
/// that source). A source supplies only `value`; the core stamps `source`.
public struct NotificationID: Hashable, Codable, Sendable {
    public let source: SourceID
    public let value: String

    public init(source: SourceID, value: String) {
        self.source = source
        self.value = value
    }
}
