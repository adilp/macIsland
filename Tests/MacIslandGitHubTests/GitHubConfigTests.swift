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
