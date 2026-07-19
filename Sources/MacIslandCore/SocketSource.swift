import Foundation

/// One connection's `NotificationSource`. The ingress is **N conformers, not a
/// special case** (source-API §3): the `IngressHost` mints one `SocketSource` per
/// accepted connection, and the core's registry cannot tell it from an EventKit-backed
/// source. Its read loop translates the wire (spec §4) into `handle` calls, and its
/// `onAction`/`onClosed` serialize the core's callbacks back onto the same connection
/// — the two ends of one bidirectional stream (spec §6).
///
/// `@MainActor`: it only ever touches the `@MainActor` core through its handle, and
/// its own state (the handle, the live-value set) stays race-free without locks. The
/// blocking socket I/O lives in the `Connection` conformer, off the main actor.
@MainActor
public final class SocketSource: NotificationSource {
    public let id: SourceID
    public let revokeOnDisconnect: Bool

    private let connection: any Connection
    /// The line the host already read while peeking for a `hello` but that turned out
    /// to be a request (no handshake) — processed first, before the read loop resumes.
    private let firstLine: String?
    /// Called once when the read loop ends — the socket dropped, so this source has
    /// gone away (spec §5: a dropped connection ≡ a stopped source). The core can't
    /// infer this from `start` merely returning (a post-and-retain-handle source like
    /// Calendar returns from `start` yet stays live), so the disconnect is signalled
    /// explicitly here; the host wires it to `core.unregister(id)`, which then runs the
    /// uniform teardown (orphan policy → `stop()`). Default no-op keeps the floor clean.
    private let onDisconnect: @MainActor (SourceID) async -> Void
    private var handle: SourceHandle?

    public init(
        id: SourceID,
        connection: any Connection,
        revokeOnDisconnect: Bool = false,
        firstLine: String? = nil,
        onDisconnect: @escaping @MainActor (SourceID) async -> Void = { _ in }
    ) {
        self.id = id
        self.revokeOnDisconnect = revokeOnDisconnect
        self.connection = connection
        self.firstLine = firstLine
        self.onDisconnect = onDisconnect
    }

    // MARK: Lifecycle — the read loop (WIRE → protocol)

    public func start(_ handle: SourceHandle) async throws {
        self.handle = handle
        // A no-hello connection's first request was already read by the host while it
        // peeked for a handshake; process it before resuming the socket read.
        if let firstLine { await process(firstLine) }
        while let line = await connection.nextLine() {
            await process(line)
        }
        // The loop ends when the peer drops the socket. Signal the disconnect so the
        // host unregisters this source and the core runs uniform teardown — orphan
        // policy, then `stop()` closes the connection (spec §5).
        await onDisconnect(id)
    }

    // MARK: Callbacks (protocol → WIRE) — serialized back onto this connection (spec §6)

    public func onAction(_ value: String, _ actionID: String) async throws {
        await connection.write(IngressWire.actionEvent(id: value, action: actionID))
    }

    public func onClosed(_ value: String, reason: CloseReason) async throws {
        await connection.write(IngressWire.closedEvent(id: value, reason: reason))
    }

    public func stop() async throws {
        await connection.close()
    }

    // MARK: Request handling

    /// Translate one client→core line into `handle` calls and write its single ack.
    /// A malformed line earns an `error` ack but never drops the connection (spec §3).
    private func process(_ line: String) async {
        let request: IngressRequest
        do {
            request = try IngressWire.parse(line)
        } catch let error as IngressError {
            await connection.write(IngressWire.error(error))
            return
        } catch {
            await connection.write(IngressWire.error(IngressError("malformed JSON")))
            return
        }

        switch request {
        case .hello:
            // Identity is fixed at connect time by the host, which strips the leading
            // handshake; a `hello` arriving mid-stream is out of place.
            await connection.write(IngressWire.error(IngressError("unexpected hello", op: "hello")))
        case .notify(let payload):
            await applyNotify(payload)
        case .revoke(let value):
            // Idempotent: `revoked` reflects whether the card was live, read from the
            // core (the truth even for a re-adopted source's cards, spec §7) — checked
            // before the revoke removes it.
            let existed = handle?.hasCard(value) ?? false
            handle?.revoke(value)
            await connection.write(IngressWire.okRevoke(revoked: existed))
        case .revokeAll:
            handle?.revokeAll()
            await connection.write(IngressWire.okRevokeAll())
        }
    }

    private func applyNotify(_ payload: NotifyPayload) async {
        // Omitted id → assign the UUID here (not inside the handle) so the ack carries
        // the exact value the core keys the card under.
        let value = payload.id ?? UUID().uuidString
        let notification = Notification(
            id: NotificationID(source: id, value: value),
            content: payload.content,
            actions: payload.actions,
            presence: payload.presence,
            alerting: payload.alerting
        )
        handle?.post(notification)          // id.source is re-stamped to `id` by the handle
        await connection.write(IngressWire.okNotify(id: value))
    }
}
