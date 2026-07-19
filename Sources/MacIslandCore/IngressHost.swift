import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The local JSON ingress listener. It is **not** a source — it is a *host* that
/// mints one `SocketSource` per accepted connection (source-API §3), so the core's
/// registry sees N ordinary sources and cannot tell which are socket-backed. Booted
/// **last** (unified spec §8.4 step 5): the socket only accepts once the core can
/// render.
///
/// `@MainActor` because it registers sources on the core; the blocking `accept()`
/// runs on a private background queue and only hops here to wire up each connection.
@MainActor
public final class IngressHost {
    private let core: IslandCore
    private let path: String
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "com.macisland.ingress.accept")

    /// - Parameters:
    ///   - core: the registry each connection's source is registered on.
    ///   - path: the UDS path; defaults to `AppSupport.socketPath` (`$MACISLAND_SOCK`
    ///     override or the app-support default).
    public init(core: IslandCore, path: String = AppSupport.socketPath) {
        self.core = core
        self.path = path
    }

    /// Resolve the path → unlink any stale socket → `bind` → `listen` → spawn the
    /// accept loop (spec §8.4 step 5). Throws if the socket can't be bound.
    public func start() throws {
        let fd = try UnixSocket.listen(path: path)
        listenFD = fd
        Log.ingress.info("ingress listening at '\(self.path, privacy: .public)'")
        acceptLoop(on: fd)
    }

    /// Clean shutdown (spec §8.4): close the listener and unlink the socket file. The
    /// per-connection sources are torn down by the core (each dropped socket ≡ a
    /// stopped source); the OS reclaims their fds on exit.
    public func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
        Log.ingress.info("ingress stopped")
    }

    // MARK: - Accept loop (off the main actor)

    private func acceptLoop(on listenFD: Int32) {
        acceptQueue.async { [weak self] in
            while true {
                let connectionFD = accept(listenFD, nil, nil)
                if connectionFD < 0 {
                    if errno == EINTR { continue }       // interrupted syscall — retry
                    break                                // listener closed (stop) or fatal error
                }
                // Hop to the main actor to build + register this connection's source.
                Task { @MainActor [weak self] in await self?.handleConnection(fd: connectionFD) }
            }
        }
    }

    // MARK: - Per-connection wiring (main actor)

    private func handleConnection(fd: Int32) async {
        let connection = SocketConnection(fd: fd)

        // Peek the optional first line: a `hello` fixes identity (durable name +
        // reconnect re-adoption + `revokeOnDisconnect`, spec §2 / unified R1); anything
        // else is a request the source must still process — hand it in as `firstLine`.
        var name: String?
        var revokeOnDisconnect = false
        var firstLine: String?
        if let first = await connection.nextLine() {
            if case .hello(let hello)? = try? IngressWire.parse(first) {
                name = hello.source
                revokeOnDisconnect = hello.revokeOnDisconnect
            } else {
                firstLine = first
            }
        }

        // Named → durable `ingress:<name>` namespace; no name → an isolated anonymous
        // per-connection source (spec §2).
        let id = name.map { SourceID(raw: "ingress:\($0)") }
            ?? SourceID(raw: "ingress:anon-\(UUID().uuidString)")

        let core = self.core
        let source = SocketSource(
            id: id, connection: connection,
            revokeOnDisconnect: revokeOnDisconnect, firstLine: firstLine,
            onDisconnect: { [weak core] id in await core?.unregister(id) }
        )

        // Collision rule (spec §3): a still-live id → reject the newcomer (no silent
        // hijack); a vacated id → `register` succeeds and re-adopts its cards.
        if core.register(source) == nil {
            await connection.write(IngressWire.error(IngressError("source id in use", op: "hello")))
            await connection.close()
            Log.ingress.error("rejected connection for already-live source '\(id.raw, privacy: .public)'")
        }
    }
}
