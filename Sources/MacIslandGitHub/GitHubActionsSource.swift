import Foundation
import MacIslandCore
#if canImport(AppKit)
import AppKit
#endif

/// A `NotificationSource` that surfaces GitHub Actions deploys on the island. It
/// polls a `GitHubClient` and translates run-status transitions into the two-layer
/// model (design doc 2026-07-20):
///
/// - an **active** run (queued/in-progress) owns a pill *activity* — a compact
///   glyph + live clock that expands into its stack row on hover;
/// - **success** flashes the activity green for ~2s, then it auto-collapses;
/// - **failure / timed-out** hands the card off to the existing notification layer:
///   it becomes a sticky **ringing** card (with "Open run"), leaving the pill;
/// - **cancelled / skipped** resolves silently.
///
/// The core owns all sound and rendering — this source only ever `post`/`revoke`s,
/// exactly like `CalendarSource`. `@MainActor` because it drives the `@MainActor`
/// core through its handle and its poll state stays race-free on one actor.
@MainActor
public final class GitHubActionsSource: NotificationSource {
    public let id = SourceID(raw: "github")

    /// Tuning — cadence and the wake/stale-failure freshness window. Defaults match
    /// the design doc; overridable for tests.
    public struct Config: Sendable {
        /// Poll interval while any deploy is active.
        public var activeInterval: Duration = .seconds(15)
        /// Idle floor — the fastest we poll when nothing is running.
        public var idleFloor: Duration = .seconds(60)
        /// Idle ceiling — the backoff cap after a long quiet stretch.
        public var idleCeiling: Duration = .seconds(300)
        /// A completed failure older than this (e.g. finished while asleep) resolves
        /// *silently* — a sticky card with no ring — instead of ringing on catch-up.
        public var freshness: Duration = .seconds(600)
        public init() {}
    }

    /// The module's health, for the (future) Modules settings panel and to gate the
    /// one auth info card. Exposed now for forward-compat.
    public enum Status: Equatable, Sendable {
        case starting
        case ok
        case needsAuth(String)
        case error(String)
    }

    private let client: any GitHubClient
    private let clock: any Clock
    private let config: Config
    /// When set, the source watches this file; a `touch` (the local `pre-push` hook)
    /// snaps polling to fast and fires immediately. `nil` in tests — no file IO.
    private let nudgeFile: URL?

    private var handle: SourceHandle?
    /// Runs we're actively showing as pill activities: `run id → last-seen status`.
    /// A terminal run is *removed* — so a re-run (same id back to active) is naturally
    /// re-adopted as a fresh activity, and completed runs we've already handled (or
    /// that finished before we started) are ignored.
    private var active: [Int: RunStatus] = [:]
    /// The body of the one "something's wrong" card currently shown (auth or repo-not-found),
    /// or nil when healthy. Tracked so an unchanged problem never re-posts (no idle churn),
    /// and a recovered fetch clears whichever problem was up.
    private var shownProblemBody: String?

    public private(set) var status: Status = .starting
    /// The interval the next poll is scheduled at — the observable output of the
    /// cadence/backoff logic (assertable without driving the clock).
    public private(set) var nextPollInterval: Duration
    /// Total polls completed — lets a test await a deterministic number of polls.
    public private(set) var pollCount = 0

    private var currentIdleBackoff: Duration
    private var loop: Scheduled?
    private var pollWaiters: [(count: Int, cont: CheckedContinuation<Void, Never>)] = []
    #if canImport(AppKit)
    private var wakeObserver: NSObjectProtocol?
    #endif
    private var nudgeSource: (any DispatchSourceFileSystemObject)?

    private static let problemCardValue = "status"

    public init(
        client: any GitHubClient,
        clock: any Clock,
        config: Config = Config(),
        nudgeFile: URL? = nil
    ) {
        self.client = client
        self.clock = clock
        self.config = config
        self.nudgeFile = nudgeFile
        self.currentIdleBackoff = config.idleFloor
        self.nextPollInterval = config.idleFloor
    }

    // MARK: - NotificationSource

    public func start(_ handle: SourceHandle) async throws {
        self.handle = handle
        installWakeObserver()
        installNudgeWatcher()
        await pollNow()          // first poll — the cold-start guard falls out of reconcile
        scheduleNextPoll()
    }

    public func stop() async throws {
        loop?.cancel()
        loop = nil
        removeWakeObserver()
        nudgeSource?.cancel()
        nudgeSource = nil
        handle?.revokeAll()
        active.removeAll()
    }

    // MARK: - Polling

    /// Do exactly one poll + reconcile. The single entrypoint for both the timer loop
    /// and the local `pre-push` nudge (a file-watch shim calls this). Never throws —
    /// a transport failure is swallowed as a no-op (completions are only ever inferred
    /// from a *successful* fetch).
    public func pollNow() async {
        defer { pollCount += 1; signalPolled() }
        let runs: [RunSnapshot]
        do {
            runs = try await client.fetchDeployRuns()
        } catch GitHubClientError.notAuthenticated {
            onAuthFailure()
            return
        } catch GitHubClientError.repositoryNotFound {
            onRepoNotFound()
            return
        } catch {
            // Transport failure: silent no-op. Keep all state; do NOT revoke or infer
            // a completion. Status is left as-is so a blip doesn't flip us to error.
            return
        }
        onFetchSucceeded()
        reconcile(runs, now: clock.now())
    }

    /// Snap the loop back to fast polling and fire immediately — the nudge path and
    /// the wake path both use this.
    public func poke() {
        Task { [weak self] in
            guard let self else { return }
            await self.pollNow()
            self.scheduleNextPoll()
        }
    }

    private func scheduleNextPoll() {
        loop?.cancel()
        let interval = active.isEmpty ? currentIdleBackoff : config.activeInterval
        nextPollInterval = interval
        loop = clock.schedule(after: interval) { [weak self] in
            guard let self else { return }
            await self.pollNow()
            self.scheduleNextPoll()
        }
        // Advance the idle backoff *after* scheduling this one, so each successive idle
        // poll waits longer — up to the ceiling. Active polling resets it to the floor.
        if active.isEmpty {
            currentIdleBackoff = min(config.idleCeiling, currentIdleBackoff * 2)
        } else {
            currentIdleBackoff = config.idleFloor
        }
    }

    // MARK: - Reconcile (the state machine — pure over its inputs)

    private func reconcile(_ runs: [RunSnapshot], now: Date) {
        let seen = Set(runs.map(\.id))

        for run in runs {
            switch run.status {
            case .active:
                if active[run.id] == nil { postActivity(run) }  // new → adopt
                active[run.id] = .active                         // still running → no re-post
            case .completed:
                // Only a run we were actively showing terminates here. A completed run
                // we don't track is either already handled or pre-existed our launch
                // (the cold-start baseline) — ignore it.
                guard active[run.id] != nil else { continue }
                resolveTerminal(run, now: now)
                active[run.id] = nil
            }
        }

        // A tracked-active run that fell off the (successful) recent list — never seen
        // its completion — is revoked quietly so the pill can't get stuck.
        for id in active.keys where !seen.contains(id) {
            handle?.revoke(value(runID: id))
            active[id] = nil
        }
    }

    private func resolveTerminal(_ run: RunSnapshot, now: Date) {
        switch run.conclusion {
        case .success:
            postSuccessCard(run)
        case .failure:
            postFailureCard(run, now: now)
        case .quiet, .none:
            handle?.revoke(value(runID: run.id))   // cancelled / skipped → silent
        }
    }

    // MARK: - Card mapping

    /// A running deploy → a pill activity: glyph + live clock, tappable "Open run".
    /// The action is `dismissOnTap: false` so opening the run in the browser doesn't
    /// dismiss the activity — it keeps tracking until the deploy actually finishes.
    private func postActivity(_ run: RunSnapshot) {
        handle?.post(
            Content(title: run.workflowName, body: "\(run.branch) · \(run.shortSHA)",
                    icon: .symbol(Self.runningGlyph)),
            value: value(runID: run.id),
            actions: [Action(label: "Open run", behavior: .openURL(run.htmlURL), dismissOnTap: false)],
            presence: .sticky,
            alerting: .silent,
            activity: ActivityStyle(
                glyph: .symbol(Self.runningGlyph),
                since: run.startedAt ?? clock.now()
                // relevance defaults to 0 — deploys don't claim priority over, say, an
                // imminent meeting that later emits a higher-relevance peek.
            )
        )
    }

    /// Success → a **persistent** completion card: it leaves the pill (no activity
    /// style → enters the stack), turns green, and stays until you dismiss it — so a
    /// finished deploy is still there when you come back. Silent (success isn't urgent;
    /// failure is the one that rings). "Open run" is `dismissOnTap: false`; only the ✕
    /// removes it.
    private func postSuccessCard(_ run: RunSnapshot) {
        handle?.post(
            Content(title: "\(run.workflowName) deployed", body: "\(run.branch) · \(run.shortSHA)",
                    icon: .symbol(Self.successGlyph), tint: Self.successTint),
            value: value(runID: run.id),
            actions: [Action(label: "Open run", behavior: .openURL(run.htmlURL), dismissOnTap: false)],
            presence: .sticky,
            alerting: .silent
        )
    }

    /// Failure → the same persistent hand-off to the notification layer: an upsert to a
    /// sticky card with **no** activity style (leaves the pill, enters the stack), a red
    /// tint, "Open run" (`dismissOnTap: false`), and a ring — unless the failure is
    /// stale (finished long ago, e.g. while asleep), in which case it lands silently.
    private func postFailureCard(_ run: RunSnapshot, now: Date) {
        let stale = run.completedAt.map { now.timeIntervalSince($0) > config.freshness.timeInterval } ?? false
        handle?.post(
            Content(title: "\(run.workflowName) failed", body: "\(run.branch) · \(run.shortSHA)",
                    icon: .symbol(Self.failureGlyph), tint: Self.failureTint),
            value: value(runID: run.id),
            actions: [Action(label: "Open run", behavior: .openURL(run.htmlURL), dismissOnTap: false)],
            presence: .sticky,
            alerting: stale ? .silent : .ringing()
        )
    }

    // MARK: - Auth / status

    private func onAuthFailure() {
        status = .needsAuth("Run `gh auth login`")
        showProblem("Run `gh auth login` to watch deploys")
    }

    private func onRepoNotFound() {
        status = .error("Repository not found")
        showProblem("Repository not found — check it in Settings")
    }

    /// Show the single "Deploy watch off" info card, upserted by id. Guarded on the body so
    /// an unchanged problem never re-posts (no idle churn); switching problems updates it.
    private func showProblem(_ body: String) {
        guard shownProblemBody != body else { return }
        shownProblemBody = body
        handle?.post(
            Content(title: "Deploy watch off", body: body,
                    icon: .symbol("exclamationmark.triangle.fill")),
            value: Self.problemCardValue,
            presence: .sticky,
            alerting: .silent
        )
    }

    private func onFetchSucceeded() {
        status = .ok
        if shownProblemBody != nil {             // self-healed → clear the info card
            handle?.revoke(Self.problemCardValue)
            shownProblemBody = nil
        }
    }

    // MARK: - Wake

    private func installWakeObserver() {
        #if canImport(AppKit)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Timers don't fire while asleep — catch up immediately. A stale completed
            // failure resolves silently via the freshness check in `postFailureCard`.
            Task { @MainActor in self?.poke() }
        }
        #endif
    }

    private func removeWakeObserver() {
        #if canImport(AppKit)
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        #endif
    }

    // MARK: - Push nudge (local pre-push hook → file → fast poll)

    /// Watch the nudge file for a `touch`. The local `pre-push` git hook touches it the
    /// instant you push, so *your* deploys are caught immediately even while idle
    /// polling has backed off. Best-effort: any failure just leaves the timer loop.
    private func installNudgeWatcher() {
        guard let nudgeFile else { return }
        let path = nudgeFile.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .attrib, .extend], queue: .main
        )
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.poke() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        nudgeSource = src
    }

    // MARK: - Helpers

    private func value(runID: Int) -> String { "run-\(runID)" }

    /// Await until at least `count` polls have completed — deterministic test hook.
    public func awaitPoll(count: Int) async {
        if pollCount >= count { return }
        await withCheckedContinuation { pollWaiters.append((count, $0)) }
    }

    private func signalPolled() {
        pollWaiters.removeAll { if pollCount >= $0.count { $0.cont.resume(); return true }; return false }
    }

    // MARK: - Glyphs / tints

    private static let runningGlyph = "shippingbox.fill"
    private static let successGlyph = "checkmark.circle.fill"
    private static let failureGlyph = "xmark.octagon.fill"
    private static let successTint = "#30D158"
    private static let failureTint = "#FF453A"
}
