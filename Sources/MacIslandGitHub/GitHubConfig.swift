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
