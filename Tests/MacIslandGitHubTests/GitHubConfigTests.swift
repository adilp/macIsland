import XCTest
@testable import MacIslandGitHub

/// Unit tests for the GitHub module's repo config: the workflow-name filter (pure) and
/// the `UserDefaults` store round-trip (with a throwaway suite — no shared state).
final class GitHubConfigTests: XCTestCase {

    // MARK: - Workflow filter

    func test_emptyFilter_matchesEverything() {
        let cfg = GitHubConfig(owner: "o", repo: "r")
        XCTAssertTrue(cfg.matchesWorkflow(named: "Deploy Web"))
        XCTAssertTrue(cfg.matchesWorkflow(named: "CI"))
    }

    func test_filter_matchesBySubstring_caseInsensitively() {
        let cfg = GitHubConfig(owner: "o", repo: "r", workflowFilter: ["deploy"])
        XCTAssertTrue(cfg.matchesWorkflow(named: "Deploy Web"))
        XCTAssertTrue(cfg.matchesWorkflow(named: "API DEPLOY"))
        XCTAssertFalse(cfg.matchesWorkflow(named: "Unit Tests"))
    }

    func test_filter_matchesAnyOfSeveral() {
        let cfg = GitHubConfig(owner: "o", repo: "r", workflowFilter: ["deploy", "release"])
        XCTAssertTrue(cfg.matchesWorkflow(named: "Release Mobile"))
        XCTAssertFalse(cfg.matchesWorkflow(named: "Lint"))
    }

    // MARK: - Repository parsing

    func test_parseRepository_ownerSlashRepo() {
        let r = GitHubConfig.parseRepository("SignalVote/SignalVote")
        XCTAssertEqual(r?.owner, "SignalVote")
        XCTAssertEqual(r?.repo, "SignalVote")
    }

    func test_parseRepository_fullHTTPSURL() {
        let r = GitHubConfig.parseRepository("https://github.com/octocat/Hello-World")
        XCTAssertEqual(r?.owner, "octocat")
        XCTAssertEqual(r?.repo, "Hello-World")
    }

    func test_parseRepository_stripsDotGitAndTrailingPath() {
        XCTAssertEqual(GitHubConfig.parseRepository("https://github.com/octocat/Hello-World.git")?.repo, "Hello-World")
        let deep = GitHubConfig.parseRepository("https://github.com/octocat/Hello-World/actions/runs")
        XCTAssertEqual(deep?.owner, "octocat")
        XCTAssertEqual(deep?.repo, "Hello-World")
    }

    func test_parseRepository_sshForm() {
        let r = GitHubConfig.parseRepository("git@github.com:octocat/Hello-World.git")
        XCTAssertEqual(r?.owner, "octocat")
        XCTAssertEqual(r?.repo, "Hello-World")
    }

    func test_parseRepository_trimsWhitespace() {
        XCTAssertEqual(GitHubConfig.parseRepository("  octocat/Hello-World  ")?.owner, "octocat")
    }

    func test_parseRepository_rejectsIncomplete() {
        XCTAssertNil(GitHubConfig.parseRepository("octocat"))
        XCTAssertNil(GitHubConfig.parseRepository(""))
        XCTAssertNil(GitHubConfig.parseRepository("https://github.com/octocat"))
    }

    // MARK: - isComplete

    func test_isComplete_requiresOwnerAndRepo() {
        XCTAssertTrue(GitHubConfig(owner: "o", repo: "r").isComplete)
        XCTAssertFalse(GitHubConfig(owner: "", repo: "r").isComplete)
        XCTAssertFalse(GitHubConfig(owner: "o", repo: "  ").isComplete)
    }

    // MARK: - Store round-trip

    private func throwawayStore() -> (UserDefaultsGitHubConfigStore, UserDefaults) {
        let suite = "github.config.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (UserDefaultsGitHubConfigStore(defaults: defaults), defaults)
    }

    func test_store_roundTripsConfig() {
        let (store, _) = throwawayStore()
        let cfg = GitHubConfig(owner: "octocat", repo: "Hello-World", branch: "trunk",
                               workflowFilter: ["deploy"])
        store.save(cfg)
        XCTAssertEqual(store.load(), cfg)
    }

    func test_store_loadsNil_whenNeverSaved() {
        let (store, _) = throwawayStore()
        XCTAssertNil(store.load())
    }

    func test_store_incompleteConfig_readsBackAsNil() {
        let (store, _) = throwawayStore()
        store.save(GitHubConfig(owner: "octocat", repo: ""))   // half-filled → unconfigured
        XCTAssertNil(store.load())
    }

    func test_store_saveNil_clears() {
        let (store, _) = throwawayStore()
        store.save(GitHubConfig(owner: "octocat", repo: "Hello-World"))
        XCTAssertNotNil(store.load())
        store.save(nil)
        XCTAssertNil(store.load())
    }
}
