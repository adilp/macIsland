import os

/// Unified logging for the core — one subsystem, per-area categories (unified spec
/// §8.3). No `print()`, no file logging: Console / `log stream` is the store. The
/// containment boundary logs faulting sources here before tearing them down.
enum Log {
    /// The single subsystem all categories share.
    static let subsystem = "com.macisland.core"

    /// Source registration, routing, teardown, and fault containment.
    static let registry = Logger(subsystem: subsystem, category: "registry")
    /// The stack controller — post/upsert/revoke/expire and timer arming.
    static let stack = Logger(subsystem: subsystem, category: "stack")
    /// Process lifetime — single-instance acquisition/refusal, startup, shutdown.
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}
