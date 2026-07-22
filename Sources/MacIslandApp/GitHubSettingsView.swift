import SwiftUI
import MacIslandCore
import MacIslandGitHub

/// The GitHub module's settings panel — the reference example of the `ModuleSettingsPanels`
/// opt-in hook. Point the module at *your* repo, then an optional branch and workflow-name
/// filter. Saving persists the config and `reload`s the module so a fresh
/// `GitHubActionsSource` starts watching the new target immediately.
///
/// The repository field is forgiving: paste a browser URL or type `owner/repo` — both parse
/// (see `GitHubConfig.parseRepository`). No token field: auth comes from the user's own `gh`
/// login (`gh auth token`), pulled live and never stored — nothing secret lives here or on disk.
struct GitHubSettingsView: View {
    let registry: ModuleRegistry

    @State private var repoInput = ""       // "owner/repo" or a full GitHub URL
    @State private var branch = "main"
    @State private var filter = ""          // comma-separated workflow-name substrings
    @State private var error: String?
    @State private var saved = false

    private let store = UserDefaultsGitHubConfigStore(defaults: AppDefaults.shared)

    var body: some View {
        Form {
            Section {
                TextField("Repository", text: $repoInput,
                          prompt: Text("owner/repo  ·  or  https://github.com/owner/repo"))
                TextField("Branch", text: $branch, prompt: Text("main"))
            } header: {
                Text("Repository")
            } footer: {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else {
                    Text("The GitHub repo whose Actions runs appear on the island.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                        .disabled(repoInput.trimmingCharacters(in: .whitespaces).isEmpty)
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
        .frame(minWidth: 440, minHeight: 320)
        .onAppear(perform: load)
    }

    private func load() {
        guard let config = store.load() else { return }
        repoInput = "\(config.owner)/\(config.repo)"
        branch = config.branch
        filter = config.workflowFilter.joined(separator: ", ")
    }

    private func save() {
        guard let parsed = GitHubConfig.parseRepository(repoInput) else {
            error = "Enter a repository as owner/repo or a github.com URL."
            saved = false
            return
        }
        error = nil
        let trimmedBranch = branch.trimmingCharacters(in: .whitespaces)
        let config = GitHubConfig(
            owner: parsed.owner,
            repo: parsed.repo,
            branch: trimmedBranch.isEmpty ? "main" : trimmedBranch,
            workflowFilter: filter
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        store.save(config)
        repoInput = "\(config.owner)/\(config.repo)"   // reflect the normalized form
        saved = true
        // Rebuild the live module against the new repo (or park it if cleared).
        Task { await registry.reload(SourceID(raw: "github")) }
    }
}
