import Foundation

/// One GitHub Actions run, reduced to exactly what the deploy-activity source needs.
/// A plain value so the reconcile logic and its tests never touch the network.
public struct RunSnapshot: Equatable, Sendable {
    public let id: Int
    public let workflowName: String
    public let status: RunStatus
    /// Non-nil iff `status == .completed`.
    public let conclusion: RunConclusion?
    public let branch: String
    public let sha: String
    public let startedAt: Date?
    public let completedAt: Date?
    public let htmlURL: URL
    public let actor: String

    public init(
        id: Int,
        workflowName: String,
        status: RunStatus,
        conclusion: RunConclusion?,
        branch: String,
        sha: String,
        startedAt: Date?,
        completedAt: Date?,
        htmlURL: URL,
        actor: String
    ) {
        self.id = id
        self.workflowName = workflowName
        self.status = status
        self.conclusion = conclusion
        self.branch = branch
        self.sha = sha
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.htmlURL = htmlURL
        self.actor = actor
    }

    /// The first 7 of the commit SHA — the human-readable form for a card body.
    public var shortSHA: String { String(sha.prefix(7)) }
}

/// A run's lifecycle phase (GitHub's `status`). We collapse GitHub's several
/// in-flight values (`queued`, `waiting`, `pending`, `requested`, `in_progress`)
/// into two: not-yet-done vs done.
public enum RunStatus: Sendable, Equatable {
    /// Queued or actively running — an *active* run that owns a pill activity.
    case active
    /// Finished — carries a `conclusion`.
    case completed

    /// Map GitHub's raw `status` string. Anything not explicitly terminal is treated
    /// as active (fail-safe: we'd rather show a spurious activity than miss a deploy).
    public init(githubStatus raw: String) {
        self = (raw == "completed") ? .completed : .active
    }
}

/// A completed run's outcome (GitHub's `conclusion`), reduced to the three the pill
/// cares about: success (green-flash), failure (ring), or quiet (cancelled/skipped/…).
public enum RunConclusion: Sendable, Equatable {
    case success
    /// A real failure worth ringing about — `failure` or `timed_out`.
    case failure
    /// Not a failure and not a success — cancelled, skipped, neutral, stale, … —
    /// resolved silently (no ring, no red).
    case quiet

    public init(githubConclusion raw: String) {
        switch raw {
        case "success": self = .success
        case "failure", "timed_out", "startup_failure": self = .failure
        default: self = .quiet   // cancelled, skipped, neutral, action_required, stale, …
        }
    }
}

/// Why a fetch failed. The source treats these very differently: `notAuthenticated`
/// surfaces a status + one info card and keeps retrying; `transport` is a **silent
/// no-op** — a completion is *never* inferred from a failed request.
public enum GitHubClientError: Error, Equatable {
    /// `gh` is missing / logged out, or the API rejected the token (401/403).
    case notAuthenticated
    /// The configured repo doesn't exist or the token can't see it (404) — a config
    /// problem the user must fix in Settings, surfaced (not a silent blip).
    case repositoryNotFound
    /// Network down, DNS, timeout, 5xx, or an unparseable body. Retry next tick.
    case transport(String)
}

/// The one seam the source depends on: fetch the recent deploy runs. Throws
/// `GitHubClientError`; a throw is never read as "a run finished". A protocol so the
/// source is driven by a scripted fake in tests and the real URLSession client in
/// production.
public protocol GitHubClient: Sendable {
    /// Recent runs on the watched branch, already filtered to the deploy workflows.
    func fetchDeployRuns() async throws -> [RunSnapshot]
}
