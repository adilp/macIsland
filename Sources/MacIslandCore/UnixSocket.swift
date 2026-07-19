import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The thin POSIX Unix-domain-socket layer the ingress is built on — shared by the
/// `IngressHost` (which `listen`s) and the `macisland` CLI (which `connect`s), so the
/// address/bind dance lives in exactly one place. Apple frameworks only (`Darwin`),
/// zero third-party deps (unified spec §6).
///
/// Security is filesystem-only (spec §8): the socket lives in a `0700` user-private
/// directory, so the trust boundary is "whoever can open the file" = the logged-in
/// user. No tokens, no network — a UDS never opens a port.
public enum UnixSocket {

    public enum Error: Swift.Error, Equatable {
        case pathTooLong(String)   // exceeds `sun_path` (~104 bytes on Darwin)
        case syscall(String, Int32) // (which, errno)
    }

    /// Bind a listening socket at `path`: ensure the parent dir exists `0700`, unlink
    /// any stale socket file (spec §8.4 step 5), `bind`, and `listen`. Returns the
    /// listening fd. The caller owns the accept loop and eventual `close`.
    public static func listen(path: String, backlog: Int32 = 16) throws -> Int32 {
        try ensurePrivateParentDirectory(of: path)
        unlink(path)                                    // remove a stale socket from a crash

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.syscall("socket", errno) }

        var address = try makeAddress(path: path)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0 else { let e = errno; close(fd); throw Error.syscall("bind", e) }

        guard Darwin.listen(fd, backlog) == 0 else {
            let e = errno; close(fd); throw Error.syscall("listen", e)
        }
        return fd
    }

    /// Connect a client socket to `path`. Returns the connected fd (caller closes).
    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.syscall("socket", errno) }

        var address = try makeAddress(path: path)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        guard connected == 0 else { let e = errno; close(fd); throw Error.syscall("connect", e) }
        return fd
    }

    /// Write all of `bytes` to `fd`, looping past short writes. The one framing-write
    /// loop every writer shares — the socket connection's write queue and the CLI
    /// client — so it isn't re-spelled at each call site.
    public static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let n = write(fd, base + offset, bytes.count - offset)
                if n <= 0 { break }                          // peer gone; caller surfaces EOF
                offset += n
            }
        }
    }

    // MARK: - Internals

    /// Pack `path` into a `sockaddr_un`, guarding the fixed `sun_path` capacity so a
    /// too-long path is a clear error, never a silent truncation.
    private static func makeAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)   // includes the NUL slot
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { throw Error.pathTooLong(path) }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
                for (index, byte) in bytes.enumerated() { dst[index] = byte }
                dst[bytes.count] = 0
            }
        }
        return address
    }

    /// Ensure the socket's parent directory exists and is user-only (`0700`, spec §8).
    /// Only *created* dirs are forced to `0700` — an existing directory a user pointed
    /// `$MACISLAND_SOCK` at is left as they set it (no surprise tightening of a shared dir).
    private static func ensurePrivateParentDirectory(of path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: directory) {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        }
    }
}
