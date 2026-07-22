import os

/// Unified logging — one subsystem, per-area categories (unified spec §8.3). No
/// `print()`, no file logging: Console / `log stream` is the store. The containment
/// boundary logs faulting sources here before tearing them down. `public` because the
/// categories span both targets — `stack`/`registry`/`ingress` are core-side, while
/// `lifecycle` (boot/shutdown) and the panel live in the app.
public enum Log {
    /// The single subsystem all categories share.
    public static let subsystem = "com.macisland.core"

    /// Source registration, routing, teardown, and fault containment.
    public static let registry = Logger(subsystem: subsystem, category: "registry")
    /// The stack controller — post/upsert/revoke/expire and timer arming.
    public static let stack = Logger(subsystem: subsystem, category: "stack")
    /// Process lifetime — single-instance acquisition/refusal, startup, shutdown.
    public static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    /// The local JSON ingress — socket bind/accept, per-connection sources, wire faults.
    public static let ingress = Logger(subsystem: subsystem, category: "ingress")
    /// The built-in Calendar source — EventKit access, meeting scheduling, self-revoke.
    public static let calendar = Logger(subsystem: subsystem, category: "calendar")
    /// The GitHub Actions source — polling, backoff, auth-state transitions.
    public static let github = Logger(subsystem: subsystem, category: "github")
}
