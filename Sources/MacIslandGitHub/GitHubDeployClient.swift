import Foundation

/// The production `GitHubClient`: reads the token from the user's existing `gh` login
/// (`gh auth token`, cached in memory) and lists recent runs via the REST API with
/// `URLSession`. No PAT to create, no external runtime dependency beyond `gh` for the
/// one-time token pull. IO, so it's verified by build + manual run, not headless tests
/// (those drive the source with a scripted fake instead).
///
/// `actor` for safe token caching across concurrent fetches; the token is re-pulled
/// only on first use and after a 401 (rotation).
public actor GitHubDeployClient: GitHubClient {
    /// Which repo/branch to watch and how to narrow the runs — a user value (see
    /// `GitHubConfig`), so the same client serves any repo the user points it at.
    private let config: GitHubConfig
    private let session: URLSession

    private var cachedToken: String?

    public init(config: GitHubConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func fetchDeployRuns() async throws -> [RunSnapshot] {
        do {
            return try await listRuns(token: try currentToken())
        } catch GitHubClientError.notAuthenticated {
            // Token may have rotated — pull a fresh one once and retry.
            cachedToken = nil
            return try await listRuns(token: try currentToken())
        }
    }

    // MARK: - Token (gh auth token, cached)

    private func currentToken() throws -> String {
        if let cachedToken { return cachedToken }
        let token = try Self.ghAuthToken()
        cachedToken = token
        return token
    }

    /// Shell out to `gh auth token` exactly once (and after a 401). Throws
    /// `.notAuthenticated` if `gh` is missing or logged out.
    private static func ghAuthToken() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh", "auth", "token"]
        // `gh` is typically in a Homebrew dir not on a GUI agent's inherited PATH.
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = env["PATH"].map { "\($0):\(extra)" } ?? extra
        process.environment = env

        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { throw GitHubClientError.notAuthenticated }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { throw GitHubClientError.notAuthenticated }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GitHubClientError.notAuthenticated }
        return token
    }

    // MARK: - REST

    private func listRuns(token: String) async throws -> [RunSnapshot] {
        var components = URLComponents(string: "https://api.github.com/repos/\(config.owner)/\(config.repo)/actions/runs")!
        components.queryItems = [
            URLQueryItem(name: "branch", value: config.branch),
            URLQueryItem(name: "per_page", value: "40")
        ]
        guard let url = components.url else { throw GitHubClientError.transport("bad url") }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("macIsland", forHTTPHeaderField: "User-Agent")

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw GitHubClientError.transport(error.localizedDescription) }

        guard let http = response as? HTTPURLResponse else {
            throw GitHubClientError.transport("no HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw GitHubClientError.notAuthenticated
        }
        if http.statusCode == 404 {
            throw GitHubClientError.repositoryNotFound   // bad owner/repo, or no access
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubClientError.transport("HTTP \(http.statusCode)")
        }

        let decoded: RunsEnvelope
        do { decoded = try Self.decoder.decode(RunsEnvelope.self, from: data) }
        catch { throw GitHubClientError.transport("decode: \(error)") }

        return decoded.workflow_runs.compactMap { $0.snapshot(matching: config) }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Wire shapes (GitHub's JSON)

    private struct RunsEnvelope: Decodable { let workflow_runs: [WireRun] }

    private struct WireRun: Decodable {
        let id: Int
        let name: String?
        let status: String?
        let conclusion: String?
        let head_branch: String?
        let head_sha: String?
        let run_started_at: Date?
        let updated_at: Date?
        let html_url: String
        let actor: Actor?

        struct Actor: Decodable { let login: String }

        func snapshot(matching config: GitHubConfig) -> RunSnapshot? {
            guard let url = URL(string: html_url) else { return nil }
            let workflowName = name ?? "Workflow"
            guard config.matchesWorkflow(named: workflowName) else { return nil }
            let status = RunStatus(githubStatus: status ?? "")
            return RunSnapshot(
                id: id,
                workflowName: workflowName,
                status: status,
                conclusion: status == .completed ? RunConclusion(githubConclusion: conclusion ?? "") : nil,
                branch: head_branch ?? "",
                sha: head_sha ?? "",
                startedAt: run_started_at,
                completedAt: status == .completed ? updated_at : nil,
                htmlURL: url,
                actor: actor?.login ?? ""
            )
        }
    }
}
