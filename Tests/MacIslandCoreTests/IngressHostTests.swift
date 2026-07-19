import XCTest
import Darwin
@testable import MacIslandCore

private typealias Notification = MacIslandCore.Notification

/// The **one real-socket smoke test** the ticket calls for (criterion 4) — plus a few
/// end-to-end paths through a live Unix domain socket: an actual `IngressHost` bound to
/// a temp path, a real client fd talking JSONL to it. Everything else is proven at the
/// in-memory `Connection` seam (`SocketSourceTests`); this proves the wiring is real.
///
/// The host processes each connection on the **main actor**, so the client's blocking
/// `read()` must run on a background queue (bridged via a continuation) — a blocking
/// read on the main actor would deadlock the host it's waiting on.
@MainActor
final class IngressHostTests: XCTestCase {

    private func json(_ line: String?) throws -> [String: Any] {
        let line = try XCTUnwrap(line)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    /// A fresh socket path under a not-yet-existing subdirectory, so the host is the
    /// one that creates it (letting us assert the 0700 contract). Deliberately short —
    /// `NSTemporaryDirectory()` on macOS (`/var/folders/…`) overruns the ~104-byte
    /// `sun_path` limit, so we bind under `/tmp` instead.
    private func tempSocketPath() -> (dir: String, path: String) {
        let dir = "/tmp/mi-\(UUID().uuidString.prefix(8))/s"
        return (dir, dir + "/ingress.sock")
    }

    /// Write one JSONL line to a client fd (small, so this doesn't block meaningfully).
    private func writeLine(_ fd: Int32, _ line: String) {
        UnixSocket.writeAll(fd, Array((line + "\n").utf8))
    }

    /// Read one line from a client fd on a background queue, so the main actor stays
    /// free to run the host that will produce the reply.
    private func readLine(_ fd: Int32) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global().async {
                var buffer = [UInt8]()
                var byte: UInt8 = 0
                while true {
                    let n = read(fd, &byte, 1)
                    if n <= 0 { continuation.resume(returning: buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)); return }
                    if byte == 0x0A { continuation.resume(returning: String(decoding: buffer, as: UTF8.self)); return }
                    buffer.append(byte)
                }
            }
        }
    }

    // MARK: - The smoke test: raw JSONL to the socket posts a card and returns an ok ack

    func test_realSocket_notify_postsCard_andReturnsOkAck() async throws {
        let (dir, path) = tempSocketPath()
        let core = IslandCore(clock: TestClock())
        let host = IngressHost(core: core, path: path)
        try host.start()
        defer { host.stop(); try? FileManager.default.removeItem(atPath: dir) }

        let client = try UnixSocket.connect(path: path)
        defer { close(client) }

        writeLine(client, #"{"op":"notify","id":"smoke","title":"Build done"}"#)
        let ack = try json(await readLine(client))

        XCTAssertEqual(ack["ok"] as? Bool, true)
        XCTAssertEqual(ack["id"] as? String, "smoke")
        XCTAssertEqual(core.ordered.map(\.id.value), ["smoke"])
        // No hello → an anonymous per-connection source (spec §2).
        XCTAssertTrue(core.ordered.first?.id.source.raw.hasPrefix("ingress:anon-") ?? false)
    }

    // MARK: - Named hello → a durable `ingress:<name>` namespace (spec §2)

    func test_realSocket_namedHello_stampsTheSourceNamespace() async throws {
        let (dir, path) = tempSocketPath()
        let core = IslandCore(clock: TestClock())
        let host = IngressHost(core: core, path: path)
        try host.start()
        defer { host.stop(); try? FileManager.default.removeItem(atPath: dir) }

        let client = try UnixSocket.connect(path: path)
        defer { close(client) }

        writeLine(client, #"{"hello":{"source":"claude-pm"}}"#)   // silent handshake
        writeLine(client, #"{"op":"notify","id":"pr","title":"Review"}"#)
        let ack = try json(await readLine(client))                // the notify ack (hello is silent)

        XCTAssertEqual(ack["id"] as? String, "pr")
        XCTAssertEqual(core.ordered.first?.id.source.raw, "ingress:claude-pm")
    }

    // MARK: - Malformed line → error ack, connection survives (spec §3), over a real socket

    func test_realSocket_malformedLine_errorAck_thenNextLineWorks() async throws {
        let (dir, path) = tempSocketPath()
        let core = IslandCore(clock: TestClock())
        let host = IngressHost(core: core, path: path)
        try host.start()
        defer { host.stop(); try? FileManager.default.removeItem(atPath: dir) }

        let client = try UnixSocket.connect(path: path)
        defer { close(client) }

        writeLine(client, #"{not json"#)
        let errorAck = try json(await readLine(client))
        XCTAssertNotNil(errorAck["error"])

        writeLine(client, #"{"op":"notify","id":"after","title":"Still here"}"#)
        let okAck = try json(await readLine(client))
        XCTAssertEqual(okAck["ok"] as? Bool, true)
        XCTAssertEqual(core.ordered.map(\.id.value), ["after"])
    }

    // MARK: - Auth = filesystem perms only: the socket lives in a 0700 dir (spec §8)

    func test_socketDirectory_isUserOnly0700() throws {
        let (dir, path) = tempSocketPath()
        let host = IngressHost(core: IslandCore(clock: TestClock()), path: path)
        try host.start()
        defer { host.stop(); try? FileManager.default.removeItem(atPath: dir) }

        let perms = try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o700)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))   // the socket file is bound
    }
}
