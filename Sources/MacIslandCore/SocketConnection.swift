import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A `Connection` over one live Unix-domain-socket fd. The blocking `read`/`write`
/// syscalls run on private background queues; the `@MainActor` methods only *await*
/// their results, so the main actor — and the core it drives — is never blocked on
/// I/O. A blocked `read()` sitting off-actor is explicitly **not** idle cost (perf
/// spec §I-5), so a quiet connection keeps the app quiescent.
///
/// All Swift-level buffer state lives on the main actor (only the raw syscalls hop to
/// a queue), so there are no locks and no shared mutable state across threads.
@MainActor
final class SocketConnection: Connection {
    private let fd: Int32
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue

    /// Complete lines split out of `byteBuffer`, awaiting a `nextLine` reader.
    private var pendingLines: [String] = []
    /// Bytes read but not yet terminated by a newline.
    private var byteBuffer: [UInt8] = []
    private var reachedEOF = false
    private var isClosed = false
    /// The single in-flight `nextLine` continuation (one consumer: the read loop).
    private var lineWaiter: CheckedContinuation<String?, Never>?

    init(fd: Int32) {
        self.fd = fd
        self.readQueue = DispatchQueue(label: "com.macisland.ingress.read.\(fd)")
        self.writeQueue = DispatchQueue(label: "com.macisland.ingress.write.\(fd)")
    }

    func nextLine() async -> String? {
        if !pendingLines.isEmpty { return pendingLines.removeFirst() }
        if reachedEOF || isClosed { return nil }
        return await withCheckedContinuation { continuation in
            lineWaiter = continuation
            scheduleRead()
        }
    }

    func write(_ line: String) async {
        guard !isClosed else { return }
        let bytes = Array((line + "\n").utf8)                 // JSONL framing (spec §3)
        let fd = self.fd
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeQueue.async {                                // serial: acks and events never interleave
                UnixSocket.writeAll(fd, bytes)
                continuation.resume()
            }
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
        resumeWaiter(with: nil)                               // unblock a pending reader
    }

    // MARK: - Reading (off-actor syscall → main-actor buffer)

    private func scheduleRead() {
        let fd = self.fd
        readQueue.async { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            let bytes: [UInt8] = count > 0 ? Array(chunk[0..<count]) : []
            let eof = count <= 0                              // 0 = clean EOF, <0 = error (peer gone)
            Task { @MainActor in self?.ingest(bytes: bytes, eof: eof) }
        }
    }

    private func ingest(bytes: [UInt8], eof: Bool) {
        byteBuffer.append(contentsOf: bytes)
        while let newline = byteBuffer.firstIndex(of: 0x0A) {         // '\n'
            pendingLines.append(String(decoding: byteBuffer[..<newline], as: UTF8.self))
            byteBuffer.removeSubrange(...newline)
        }
        if eof {
            reachedEOF = true
            if !byteBuffer.isEmpty {                                  // a final un-terminated line still counts
                pendingLines.append(String(decoding: byteBuffer, as: UTF8.self))
                byteBuffer.removeAll()
            }
        }
        deliverToWaiter()
    }

    private func deliverToWaiter() {
        guard lineWaiter != nil else { return }                       // no one waiting → buffer it
        if !pendingLines.isEmpty {
            resumeWaiter(with: pendingLines.removeFirst())
        } else if reachedEOF || isClosed {
            resumeWaiter(with: nil)
        } else {
            scheduleRead()                                            // partial line, keep reading
        }
    }

    private func resumeWaiter(with line: String?) {
        guard let waiter = lineWaiter else { return }
        lineWaiter = nil
        waiter.resume(returning: line)
    }
}
