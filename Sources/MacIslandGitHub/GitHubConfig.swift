import Foundation

/// Which repository the GitHub module watches, and how to narrow the runs it shows.
/// A plain, serializable value — the App persists it (see `GitHubConfigStore`) and the
/// boot sequence feeds it to `GitHubDeployClient`. Nothing here is a secret: the auth
/// token is pulled live from the user's own `gh` login, never stored (`GitHubDeployClient`).
///
/// `workflowFilter` is a list of case-insensitive **name substrings** — the usable form
/// of "only these workflows" (opaque numeric workflow ids would force an API lookup).
/// Empty ⇒ watch every workflow on the branch.
public struct GitHubConfig: Codable, Equatable, Sendable {
    public var owner: String
    public var repo: String
    public var branch: String
    public var workflowFilter: [String]

    public init(owner: String, repo: String, branch: String = "main", workflowFilter: [String] = []) {
        self.owner = owner
        self.repo = repo
        self.branch = branch
        self.workflowFilter = workflowFilter
    }

    /// Usable only when owner and repo are both set — a half-filled form watches nothing.
    public var isComplete: Bool {
        !owner.trimmingCharacters(in: .whitespaces).isEmpty &&
        !repo.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Does a run's workflow name pass the filter? Empty filter ⇒ everything passes.
    public func matchesWorkflow(named name: String) -> Bool {
        workflowFilter.isEmpty ||
        workflowFilter.contains { name.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// Parse a user-typed repository reference into `(owner, repo)`. Forgiving on purpose —
    /// people paste a browser URL as readily as they type `owner/repo`. Accepts `owner/repo`,
    /// `https://github.com/owner/repo` (with an optional `.git` or trailing path), and the
    /// SSH form `git@github.com:owner/repo`. Returns nil if it can't find both parts.
    public static func parseRepository(_ input: String) -> (owner: String, repo: String)? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "github.com/", "git@github.com:"]
        where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)); break
        }
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return (owner, repo)
    }
}

/// The persistence seam for the GitHub module's `GitHubConfig` — injected like
/// `ModuleStore`/`Clock` so the wiring stays testable. `load()` returns `nil` until the
/// user has entered a real repo, which is how the module knows to park in a "needs setup"
/// state instead of polling nothing.
public protocol GitHubConfigStore {
    func load() -> GitHubConfig?
    func save(_ config: GitHubConfig?)
}

/// Production store — one `UserDefaults` key holding the JSON-encoded config. An
/// incomplete (or absent) config reads back as `nil` so callers never watch `owner/`.
public final class UserDefaultsGitHubConfigStore: GitHubConfigStore {
    private let defaults: UserDefaults
    private let key = "github.config"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> GitHubConfig? {
        guard let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(GitHubConfig.self, from: data),
              config.isComplete
        else { return nil }
        return config
    }

    public func save(_ config: GitHubConfig?) {
        guard let config, config.isComplete, let data = try? JSONEncoder().encode(config) else {
            defaults.removeObject(forKey: key)   // clearing / a half-filled form → unconfigured
            return
        }
        defaults.set(data, forKey: key)
    }
}
