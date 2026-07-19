import Foundation

/// The bidirectional, line-oriented transport a `SocketSource` reads and writes —
/// the seam that lets the wire codec + `SocketSource` be exercised with **no real
/// socket** (ticket criterion 4). One conformer wraps a live Unix-domain-socket
/// connection (`SocketConnection`); the test double is an in-memory pair.
///
/// **Pull-based** on purpose: the `IngressHost` must *peek* the first line — the
/// optional `hello` handshake that fixes the source's identity (spec §2) — before it
/// can mint and register the `SocketSource`. A pull (`nextLine`) makes that peek a
/// single read the source then continues from, with no push-back machinery.
///
/// `@MainActor` because everything it talks to — the core, the `SourceHandle`, the
/// `SocketSource` — is `@MainActor`; a conformer offloads the actual blocking
/// syscalls to a background queue and only hops back here to hand over a line, so the
/// main actor is never blocked on I/O (perf spec: a blocked `read()` is not idle cost).
@MainActor
public protocol Connection: AnyObject {
    /// The next client→core line (newline-stripped, UTF-8), or `nil` once the peer
    /// has closed **and** no buffered lines remain. Awaiting it suspends without
    /// blocking — the blocking read lives off the main actor in the conformer.
    func nextLine() async -> String?

    /// Write one core→client line. The conformer appends the framing newline and
    /// serializes concurrent writes, so a request ack and an async event line can
    /// never interleave on the wire (spec §3: one object per line).
    func write(_ line: String) async

    /// Close the connection. Idempotent — teardown may call it after the peer already
    /// dropped (spec §5: a stopped source ≡ a dropped connection).
    func close() async
}
