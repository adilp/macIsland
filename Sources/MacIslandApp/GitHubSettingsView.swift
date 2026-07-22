import SwiftUI
import MacIslandCore
import MacIslandGitHub

/// The GitHub module's settings panel — the reference example of the `ModuleSettingsPanels`
/// opt-in hook. Point the module at *your* repo: owner, repo, branch, and an optional
/// workflow-name filter. Saving persists the config and `reload`s the module so a fresh
/// `GitHubActionsSource` starts watching the new target immediately.
///
/// No token field: auth comes from the user's own `gh` login (`gh auth token`), pulled
/// live and never stored — so nothing secret lives here or on disk.
struct GitHubSettingsView: View {
    let registry: ModuleRegistry

    @State private var owner = ""
    @State private var repo = ""
    @State private var branch = "main"
    @State private var filter = ""          // comma-separated workflow-name substrings
    @State private var saved = false

    private let store = UserDefaultsGitHubConfigStore()

    var body: some View {
        Form {
            Section {
                TextField("Owner", text: $owner, prompt: Text("octocat"))
                TextField("Repository", text: $repo, prompt: Text("Hello-World"))
                TextField("Branch", text: $branch, prompt: Text("main"))
            } header: {
                Text("Repository")
            } footer: {
                Text("The GitHub repo whose Actions runs appear on the island.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Only workflows matching", text: $filter, prompt: Text("deploy, release"))
            } footer: {
                Text("Comma-separated names (case-insensitive). Leave empty to watch every workflow.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isComplete)
                    if saved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                    }
                    Spacer()
                }
            } footer: {
                Text("Sign in once with `gh auth login` in Terminal — macIsland reads that token; it never stores one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 300)
        .onAppear(perform: load)
    }

    private var isComplete: Bool {
        !owner.trimmingCharacters(in: .whitespaces).isEmpty &&
        !repo.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func load() {
        guard let config = store.load() else { return }
        owner = config.owner
        repo = config.repo
        branch = config.branch
        filter = config.workflowFilter.joined(separator: ", ")
    }

    private func save() {
        let config = GitHubConfig(
            owner: owner.trimmingCharacters(in: .whitespaces),
            repo: repo.trimmingCharacters(in: .whitespaces),
            branch: branch.trimmingCharacters(in: .whitespaces).isEmpty
                ? "main" : branch.trimmingCharacters(in: .whitespaces),
            workflowFilter: filter
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        store.save(config)
        saved = true
        // Rebuild the live module against the new repo (or park it if cleared).
        Task { await registry.reload(SourceID(raw: "github")) }
    }
}
