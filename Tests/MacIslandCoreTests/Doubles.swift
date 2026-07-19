import Foundation
@testable import MacIslandCore

private typealias Notification = MacIslandCore.Notification

// MARK: - TestClock

/// A hand-advanced fake `Clock`: virtual time only moves when a test calls
/// `advance(by:)`, which runs every now-due one-shot fire to completion **inline**.
/// So the whole suite is deterministic and there are no wall-clock sleeps (ticket
/// "verified … with a fake clock").
@MainActor
final class TestClock: Clock {
    private(set) var current: Date
    private var pending: [Pending] = []

    init(now: Date = Date(timeIntervalSinceReferenceDate: 0)) { self.current = now }

    func now() -> Date { current }

    func schedule(after interval: Duration, _ fire: @escaping @MainActor () async -> Void) -> Scheduled {
        let p = Pending(deadline: current.addingTimeInterval(interval.timeInterval), fire: fire)
        pending.append(p)
        return p
    }

    /// Move virtual time forward by `interval`, firing every scheduled action whose
    /// deadline is now due — in chronological order, awaiting each (so downstream
    /// `onClosed` reporting has landed by the time this returns). Fires scheduled
    /// *during* a fire are picked up too.
    func advance(by interval: Duration) async {
        let target = current.addingTimeInterval(interval.timeInterval)
        while let next = pending
            .filter({ !$0.cancelled && $0.deadline <= target })
            .min(by: { $0.deadline < $1.deadline }) {
            current = next.deadline
            next.cancelled = true                      // one-shot: consume before firing
            await next.fire()
        }
        current = target
        pending.removeAll { $0.cancelled }
    }

    /// How many fires are still armed (test introspection — e.g. "quiescent at idle").
    var armedCount: Int { pending.filter { !$0.cancelled }.count }

    final class Pending: Scheduled {
        let deadline: Date
        let fire: @MainActor () async -> Void
        var cancelled = false
        init(deadline: Date, fire: @escaping @MainActor () async -> Void) {
            self.deadline = deadline
            self.fire = fire
        }
        func cancel() { cancelled = true }
    }
}

// MARK: - SpySource

enum SpyError: Error { case boom }

/// A `NotificationSource` that records every core→source callback and lets a test
/// await them deterministically. `@MainActor` (so it's `Sendable` and its records
/// are race-free); flags make any callback throw, to exercise fault containment.
@MainActor
final class SpySource: NotificationSource {
    let id: SourceID
    let revokeOnDisconnect: Bool

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var closed: [(value: String, reason: CloseReason)] = []
    private(set) var actions: [(value: String, actionID: String)] = []

    var throwOnStart = false
    var throwOnClosed = false
    var throwOnAction = false
    var throwOnStop = false

    private var closedWaiters: [(count: Int, cont: CheckedContinuation<Void, Never>)] = []
    private var actionWaiters: [(count: Int, cont: CheckedContinuation<Void, Never>)] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ id: String, revokeOnDisconnect: Bool = false) {
        self.id = SourceID(raw: id)
        self.revokeOnDisconnect = revokeOnDisconnect
    }

    func start(_ handle: SourceHandle) async throws {
        startCount += 1
        if throwOnStart { throw SpyError.boom }
    }

    func onAction(_ value: String, _ actionID: String) async throws {
        actions.append((value, actionID))
        signalActions()
        if throwOnAction { throw SpyError.boom }
    }

    func onClosed(_ value: String, reason: CloseReason) async throws {
        closed.append((value, reason))
        signalClosed()
        if throwOnClosed { throw SpyError.boom }
    }

    func stop() async throws {
        stopCount += 1
        signalStop()
        if throwOnStop { throw SpyError.boom }
    }

    // Deterministic awaiters — return once the target count of events has landed.
    func awaitClosed(count: Int) async {
        if closed.count >= count { return }
        await withCheckedContinuation { closedWaiters.append((count, $0)) }
    }

    func awaitActions(count: Int) async {
        if actions.count >= count { return }
        await withCheckedContinuation { actionWaiters.append((count, $0)) }
    }

    func awaitStopped() async {
        if stopCount > 0 { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }

    private func signalClosed() {
        closedWaiters.removeAll { if closed.count >= $0.count { $0.cont.resume(); return true }; return false }
    }
    private func signalActions() {
        actionWaiters.removeAll { if actions.count >= $0.count { $0.cont.resume(); return true }; return false }
    }
    private func signalStop() {
        stopWaiters.forEach { $0.resume() }
        stopWaiters = []
    }
}

// MARK: - TestConnection

/// The in-memory `Connection` seam (ticket criterion 4): a test drives client→core
/// lines with `feed`/`peerClose` and observes the core→client acks/events in
/// `outgoing` — the wire codec + `SocketSource` are exercised with **no real socket**.
/// `@MainActor` like everything it wires to; deterministic awaiters (`awaitOutgoing`,
/// `awaitClosed`) mean no wall-clock waits.
@MainActor
final class TestConnection: Connection {
    private var pendingIncoming: [String] = []
    private var lineWaiter: CheckedContinuation<String?, Never>?
    private var peerClosed = false
    private var localClosed = false

    /// Every core→client line written back, in order (acks then async events).
    private(set) var outgoing: [String] = []
    private var outgoingWaiters: [(count: Int, cont: CheckedContinuation<Void, Never>)] = []
    private(set) var closeCount = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    // --- Test drivers ---

    /// Queue a client→core line for the source's read loop (delivered immediately if
    /// the loop is already waiting, else buffered until it reads).
    func feed(_ line: String) {
        if let waiter = lineWaiter { lineWaiter = nil; waiter.resume(returning: line) }
        else { pendingIncoming.append(line) }
    }

    /// Simulate the peer dropping the connection (EOF) → `nextLine` returns nil → the
    /// source's read loop ends → uniform teardown (spec §5).
    func peerClose() {
        peerClosed = true
        if let waiter = lineWaiter { lineWaiter = nil; waiter.resume(returning: nil) }
    }

    /// Await until at least `count` lines have been written back.
    func awaitOutgoing(count: Int) async {
        if outgoing.count >= count { return }
        await withCheckedContinuation { outgoingWaiters.append((count, $0)) }
    }

    /// Await until the source has closed the connection (its `stop()` ran).
    func awaitClosed() async {
        if closeCount > 0 { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    // --- Connection ---

    func nextLine() async -> String? {
        if !pendingIncoming.isEmpty { return pendingIncoming.removeFirst() }
        if peerClosed || localClosed { return nil }
        return await withCheckedContinuation { lineWaiter = $0 }
    }

    func write(_ line: String) async {
        outgoing.append(line)
        outgoingWaiters.removeAll { if outgoing.count >= $0.count { $0.cont.resume(); return true }; return false }
    }

    func close() async {
        closeCount += 1
        localClosed = true
        if let waiter = lineWaiter { lineWaiter = nil; waiter.resume(returning: nil) }
        closeWaiters.forEach { $0.resume() }
        closeWaiters = []
    }
}

// MARK: - OpenSpy

/// Records the URLs an `openURL` action asks the core to open — the spy-audio-style
/// seam for action routing, so no real `NSWorkspace` call happens in tests.
@MainActor
final class OpenSpy {
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

// MARK: - SpyAudio

/// The spy-audio seam: an `AudioOutput` that records every call instead of touching
/// `NSSound`, so the whole alerting layer is asserted with **no real audio and no
/// wall-clock waits** (ticket criterion 4). `ringing` tracks the net channel state so
/// a test can assert "exactly one active ring" directly.
@MainActor
final class SpyAudio: AudioOutput {
    private(set) var playOnceCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    /// Whether a ring is currently playing — start sets it, stop clears it. The
    /// single-channel invariant is "this never needs to represent more than one ring".
    private(set) var ringing = false

    func playOnce() { playOnceCount += 1 }
    func startRinging() { startCount += 1; ringing = true }
    func stopRinging() { stopCount += 1; ringing = false }
}
