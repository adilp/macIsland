import Foundation
@testable import MacIslandGitHub
import MacIslandCore

// MARK: - FakeGitHubClient

/// A scripted `GitHubClient`: each `fetchDeployRuns()` pops the next queued response
/// (runs or an error), so a test drives the source's state machine deterministically
/// with no network. Exhausting the script falls back to `defaultResponse`.
@MainActor
final class FakeGitHubClient: GitHubClient {
    enum Response { case runs([RunSnapshot]); case fail(GitHubClientError) }

    private var scripted: [Response]
    var defaultResponse: Response = .runs([])
    private(set) var callCount = 0

    init(_ scripted: [Response] = []) { self.scripted = scripted }

    func push(_ r: Response) { scripted.append(r) }

    func fetchDeployRuns() async throws -> [RunSnapshot] {
        callCount += 1
        let r = scripted.isEmpty ? defaultResponse : scripted.removeFirst()
        switch r {
        case .runs(let runs): return runs
        case .fail(let error): throw error
        }
    }
}

// MARK: - RunSnapshot builder

@MainActor
func ghRun(
    _ id: Int,
    _ status: RunStatus,
    _ conclusion: RunConclusion? = nil,
    workflow: String = "Deploy Web",
    startedAt: Date? = nil,
    completedAt: Date? = nil
) -> RunSnapshot {
    RunSnapshot(
        id: id,
        workflowName: workflow,
        status: status,
        conclusion: conclusion,
        branch: "main",
        sha: "abcdef1234567890",
        startedAt: startedAt,
        completedAt: completedAt,
        htmlURL: URL(string: "https://github.com/octocat/Hello-World/actions/runs/\(id)")!,
        actor: "octocat"
    )
}

// MARK: - TestClock (minimal, hand-advanced)

/// A hand-advanced fake `Clock` for this target (the Core test target's copy isn't
/// visible here). Virtual time only moves on `advance(by:)`, which runs every due
/// one-shot to completion inline — deterministic, no wall-clock sleeps.
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

    func advance(by interval: Duration) async {
        let target = current.addingTimeInterval(interval.timeInterval)
        while let next = pending
            .filter({ !$0.cancelled && $0.deadline <= target })
            .min(by: { $0.deadline < $1.deadline }) {
            current = next.deadline
            next.cancelled = true
            await next.fire()
        }
        current = target
        pending.removeAll { $0.cancelled }
    }

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

// MARK: - SpyAudio

/// Records ring/chime calls instead of touching `NSSound`, so the alerting layer is
/// asserted with no real audio. `ringing` tracks the net channel state.
@MainActor
final class SpyAudio: AudioOutput {
    private(set) var playOnceCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var ringing = false

    func playOnce() { playOnceCount += 1 }
    func startRinging() { startCount += 1; ringing = true }
    func stopRinging() { stopCount += 1; ringing = false }
}
