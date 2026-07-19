import Foundation

/// The one on-disk home for macIsland's runtime files — the single source of truth
/// for `~/Library/Application Support/macIsland/`. Today it holds the
/// single-instance lock; the ingress socket (`ingress.sock`) lands here in a later
/// ticket. Centralized so the directory is defined once, not re-spelled at each use.
public enum AppSupport {
    /// `~/Library/Application Support/macIsland/`. A computed value (not a stored
    /// constant) because the home directory is read at call time.
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/macIsland", isDirectory: true)
    }
}
