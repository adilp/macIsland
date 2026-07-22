import SwiftUI
import MacIslandCore

/// The opt-in extension point: a module id → a factory for its SwiftUI settings panel. A
/// module "opts in and builds its settings" by adding an entry here — its row then shows a
/// "Settings…" button that opens this panel in the standard Settings window (roomier than
/// the dropdown, per the design). The factory receives the `ModuleRegistry` so a panel can
/// `reload` its module after saving new config (see `GitHubSettingsView`).
@MainActor
enum ModuleSettingsPanels {
    static let byID: [SourceID: (ModuleRegistry) -> AnyView] = [
        SourceID(raw: "github"): { registry in AnyView(GitHubSettingsView(registry: registry)) }
    ]

    static func hasPanel(_ id: SourceID) -> Bool { byID[id] != nil }
}

/// Hosts whichever modules opted into a panel. Falls back to a placeholder so the empty-v1
/// window isn't blank if it's ever reached (it isn't, since no row shows "Settings…" yet).
struct ModulesSettingsView: View {
    let registry: ModuleRegistry

    var body: some View {
        Group {
            if registry.modules.contains(where: { ModuleSettingsPanels.hasPanel($0.id) }) {
                ForEach(registry.modules) { module in
                    if let panel = ModuleSettingsPanels.byID[module.id] {
                        panel(registry)
                    }
                }
            } else {
                Text("No module settings yet.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .frame(minWidth: 420, minHeight: 240)
    }
}
