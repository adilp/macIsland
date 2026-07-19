import Foundation
import MacIslandCore
#if canImport(Darwin)
import Darwin
#endif

/// `macisland` — the thin CLI that is **derived sugar** over the ingress socket
/// (ingress spec §9), never a second mechanism. Each subcommand is a small
/// translation to the JSONL wire protocol: connect to the UDS, optionally send a
/// `hello`, send one request, and read acks/events back. A tool that prefers to speak
/// JSONL straight to the socket needs none of it.
///
///     macisland notify [--source NAME] [--wait [--timeout N]]   # JSON on stdin
///     macisland revoke <id> | --all      [--source NAME]
///     macisland listen                   [--source NAME]
///
/// `$MACISLAND_SOCK` overrides the socket path.

// A write to a peer that has gone away must fail the syscall, not kill us with SIGPIPE.
signal(SIGPIPE, SIG_IGN)

exit(CLI.run(Array(CommandLine.arguments.dropFirst())))

// MARK: - Command dispatch

enum CLI {
    static func run(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first else { printUsage(to: FileHandle.standardError); return 2 }
        let rest = Array(arguments.dropFirst())
        do {
            switch command {
            case "notify":               return try notify(rest)
            case "revoke":               return try revoke(rest)
            case "listen":               return try listen(rest)
            case "-h", "--help", "help": printUsage(to: FileHandle.standardOutput); return 0
            default:
                errorLine("macisland: unknown command '\(command)'")
                printUsage(to: FileHandle.standardError)
                return 2
            }
        } catch let error as CLIError {
            errorLine(error.message)
            return error.code
        } catch {
            errorLine("macisland: \(error)")
            return 1
        }
    }

    // MARK: notify — JSON on stdin, upsert-by-id, optional wait for the answer

    static func notify(_ arguments: [String]) throws -> Int32 {
        let options = Options(arguments)
        let waiting = options.flag("--wait")
        let timeout = options.value("--timeout").flatMap(Double.init)

        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else {
            throw CLIError("macisland notify: expected a JSON object on stdin", code: 2)
        }

        let socket = try connect(
            source: options.value("--source"),
            revokeOnDisconnect: options.flag("--revoke-on-disconnect")
        )
        defer { close(socket.fd) }
        socket.send(IngressWire.notifyLine(from: object))         // the codec fixes the op

        guard let ackLine = socket.reader.next() else {
            throw CLIError("macisland notify: no response from macIsland", code: 3)
        }
        let ack = decode(ackLine)
        if ack["error"] != nil { errorLine(ackLine); return 1 }   // bad input fails loudly

        guard waiting else {
            print(ackLine)                                        // fire-and-forget: emit the ok ack (carries the id)
            return 0
        }

        // --wait: block, streaming this notification's action/closed lines to stdout
        // until it closes or times out (spec §6, the one-shot posture).
        if let timeout { socket.setReadTimeout(seconds: timeout) }
        while let event = socket.reader.next() {
            print(event)
            if decode(event)["event"] as? String == "closed" { return 0 }
        }
        return socket.reader.timedOut ? 4 : 0
    }

    // MARK: revoke — by id or --all, scoped to this source

    static func revoke(_ arguments: [String]) throws -> Int32 {
        let options = Options(arguments)
        let line: String
        if options.flag("--all") {
            line = IngressWire.revokeAllLine()
        } else if let id = options.positional.first {
            line = IngressWire.revokeLine(id: id)
        } else {
            throw CLIError("macisland revoke: need an <id> or --all", code: 2)
        }

        let socket = try connect(source: options.value("--source"))
        defer { close(socket.fd) }
        socket.send(line)

        guard let ackLine = socket.reader.next() else {
            throw CLIError("macisland revoke: no response from macIsland", code: 3)
        }
        print(ackLine)
        return decode(ackLine)["error"] == nil ? 0 : 1
    }

    // MARK: listen — hold the connection open, stream all of this source's events

    static func listen(_ arguments: [String]) throws -> Int32 {
        let options = Options(arguments)
        let socket = try connect(
            source: options.value("--source"),
            revokeOnDisconnect: options.flag("--revoke-on-disconnect")
        )
        defer { close(socket.fd) }
        while let event = socket.reader.next() { print(event) }   // until the connection drops
        return 0
    }

    // MARK: - Socket plumbing

    private static func connect(source: String?, revokeOnDisconnect: Bool = false) throws -> ClientSocket {
        let path = AppSupport.socketPath
        let fd: Int32
        do {
            fd = try UnixSocket.connect(path: path)
        } catch {
            throw CLIError("macisland: cannot reach macIsland at \(path) — is it running? (\(error))", code: 3)
        }
        let socket = ClientSocket(fd: fd)
        // A hello is sent to name a durable source or opt into revoke-on-disconnect (spec
        // §2 / unified R1); a nameless fire-and-forget caller sends none.
        let named = (source?.isEmpty == false)
        if named || revokeOnDisconnect {
            socket.send(IngressWire.helloLine(source: named ? source : nil, revokeOnDisconnect: revokeOnDisconnect))
        }
        return socket
    }

    static func printUsage(to handle: FileHandle) {
        let usage = """
        usage:
          macisland notify [--source NAME] [--revoke-on-disconnect] [--wait [--timeout N]]   # JSON on stdin
          macisland revoke <id> | --all    [--source NAME]
          macisland listen                 [--source NAME] [--revoke-on-disconnect]

        $MACISLAND_SOCK overrides the socket path.
        """
        handle.write(Data((usage + "\n").utf8))
    }
}

// MARK: - Supporting types

/// A CLI failure carrying the process exit code to surface (`2` bad usage, `3` can't
/// reach the app, `4` --wait timed out).
struct CLIError: Error {
    let message: String
    let code: Int32
    init(_ message: String, code: Int32) {
        self.message = message
        self.code = code
    }
}

/// A connected client socket with a buffered line reader. Blocking I/O is fine here —
/// the CLI is a short-lived synchronous process talking to a *separate* app process,
/// so nothing on this side would deadlock.
final class ClientSocket {
    let fd: Int32
    let reader: LineReader
    init(fd: Int32) { self.fd = fd; self.reader = LineReader(fd: fd) }

    func send(_ line: String) {
        UnixSocket.writeAll(fd, Array((line + "\n").utf8))       // JSONL framing (spec §3)
    }

    /// Bound the `--wait` read so a caller isn't blocked forever (spec §6 timeout).
    func setReadTimeout(seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// Blocking newline reader over a socket fd, distinguishing a timeout (`SO_RCVTIMEO`
/// → `EAGAIN`) from a real EOF so `--wait` can report the difference.
final class LineReader {
    private let fd: Int32
    private var buffer = [UInt8]()
    private(set) var timedOut = false

    init(fd: Int32) { self.fd = fd }

    func next() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                continue
            }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { timedOut = true }
            guard !buffer.isEmpty else { return nil }             // EOF/timeout with nothing buffered
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            return line
        }
    }
}

/// A minimal flag/value/positional argument scanner. `--wait`/`--all` are booleans;
/// every other `--key` takes the following token as its value.
struct Options {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []
    private(set) var positional: [String] = []

    init(_ arguments: [String]) {
        let booleans: Set<String> = ["--wait", "--all", "--revoke-on-disconnect"]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if booleans.contains(argument) {
                flags.insert(argument)
            } else if argument.hasPrefix("--") {
                if index + 1 < arguments.count { values[argument] = arguments[index + 1]; index += 1 }
                else { flags.insert(argument) }
            } else {
                positional.append(argument)
            }
            index += 1
        }
    }

    func value(_ key: String) -> String? { values[key] }
    func flag(_ key: String) -> Bool { flags.contains(key) }
}

// MARK: - Free helpers

/// Minimal inspection of an ack/event line — the CLI only needs to tell `ok` from
/// `error` and spot a `closed` event; full typed decoding stays in the core codec.
private func decode(_ line: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
}

/// The CLI's product is its stdout/stderr (acks to stdout, diagnostics to stderr), so
/// it writes there directly rather than through the core's `os.Logger` — a CLI's
/// output is meant for the caller's pipe, not the unified log store.
private func errorLine(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
