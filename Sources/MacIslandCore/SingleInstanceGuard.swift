import Foundation

/// Enforces "only one macIsland runs at a time" at runtime (walking-skeleton ticket,
/// criterion 5). The spec's primary mechanism is `LSMultipleInstancesProhibited` in
/// the app bundle's Info.plist (unified spec §8.4), but a SwiftPM binary has no
/// bundle, so we also hold an **exclusive advisory `flock`** on a lock file: the
/// first instance acquires it, any later instance is refused and exits, and the OS
/// releases the lock the moment the holder's file descriptor closes — on `deinit` or
/// process death, crash included (no stale lock to clean up).
///
/// `flock` locks attach to the open file description, so two guards opened in one
/// process contend exactly as two processes would — which is also how the unit tests
/// exercise the contention path without spawning a second process.
public final class SingleInstanceGuard {
    private let fd: Int32

    /// Acquire the lock at `path`, creating the file if needed. Returns `nil` when
    /// another instance already holds it (or the file can't be opened) — the caller
    /// should then exit.
    public init?(path: String) {
        // O_CREAT so the first run makes the file; the flock, not the file, is the lock.
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            // A real fault (bad path / permissions), distinct from a live sibling below.
            Log.lifecycle.error("single-instance lock could not open '\(path, privacy: .public)' (errno \(errno))")
            return nil
        }
        // LOCK_NB: fail fast instead of blocking when the lock is already held.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Log.lifecycle.notice("single-instance lock already held — another macIsland is running")
            close(fd)
            return nil
        }
        self.fd = fd
    }

    /// The default lock-file path, in macIsland's Application Support directory
    /// (`AppSupport.directory`). A pure helper (no filesystem side effects) so it
    /// composes with the app's directory bootstrap.
    public static func defaultPath(appSupport: URL = AppSupport.directory) -> String {
        appSupport.appendingPathComponent("macisland.lock", isDirectory: false).path
    }

    deinit {
        // Closing the fd drops the flock. `flock(fd, LOCK_UN)` first is belt-and-braces.
        flock(fd, LOCK_UN)
        close(fd)
    }
}
