import SwiftUI
import MacIslandCore

/// The menu-bar dropdown: one row per module (icon · name · status light · toggle ·
/// action buttons) plus a read-only "Connected" strip of external JSON-ingress
/// connections. Pull-model: statuses are read on appear and after each interaction — no
/// background work, so the idle quiescence budget (`PERFORMANCE.md`) is untouched.
struct ModulesMenu: View {
    @ObservedObject var registry: ModuleRegistry
    let core: IslandCore
    @Environment(\.openSettings) private var openSettings
    /// Bumped after a toggle/action to re-read the pulled state (the menu is short-lived,
    /// so re-reading on demand is enough — no observation plumbing needed).
    @State private var version = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Modules").font(.headline)

            ForEach(registry.modules) { module in
                moduleRow(module)
            }

            let connected = connectedIngress()
            if !connected.isEmpty {
                Divider()
                Text("Connected").font(.caption).foregroundStyle(.secondary)
                ForEach(connected, id: \.self) { name in
                    Label(name, systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption)
                }
            }

            Divider()
            Button("Quit macIsland") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 300)
        .id(version)   // re-read pulled state after an interaction
    }

    @ViewBuilder private func moduleRow(_ module: Module) -> some View {
        let display = registry.status(of: module.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: iconName(module.icon))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(module.displayName)
                    statusLabel(display)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { registry.isEnabled(module.id) },
                    set: { on in Task { await registry.setEnabled(module.id, on); version += 1 } }
                ))
                .labelsHidden()
            }
            // Contextual affordances: labeled actions (e.g. "Connect Calendar…") and, for a
            // module that opted into a settings panel, a link into the Settings window.
            HStack {
                ForEach(registry.actions(of: module.id)) { action in
                    Button(action.label) { Task { await action.perform(); version += 1 } }
                        .buttonStyle(.link)
                }
                if ModuleSettingsPanels.hasPanel(module.id) {
                    Button("Settings…") {
                        // We're an `.accessory` app (no Dock icon, never the active app), so the
                        // Settings window opens *behind* everything and looks like nothing happened.
                        // Activate first so it comes to the front.
                        NSApp.activate(ignoringOtherApps: true)
                        openSettings()
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    @ViewBuilder private func statusLabel(_ s: ModuleDisplayStatus) -> some View {
        switch s {
        case .disabled:
            Label("Off", systemImage: "circle").foregroundStyle(.secondary).font(.caption)
        case .live(.ok):
            Label("OK", systemImage: "circle.fill").foregroundStyle(.green).font(.caption)
        case .live(.needsAttention(let reason)):
            Label(reason, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.yellow).font(.caption)
        }
    }

    /// External JSON-ingress connections = live sources namespaced `ingress:` (the ids
    /// `IngressHost` mints per `SocketSource`). Named ones show their name; anonymous
    /// per-connection ones collapse to a count. Read once, on menu open.
    private func connectedIngress() -> [String] {
        let ingress = core.liveSourceIDs.map(\.raw).filter { $0.hasPrefix("ingress:") }
        let named = ingress.filter { !$0.hasPrefix("ingress:anon-") }
                           .map { String($0.dropFirst("ingress:".count)) }
                           .sorted()
        let anon = ingress.count - named.count
        return named + (anon > 0 ? ["\(anon) anonymous"] : [])
    }

    private func iconName(_ icon: Icon) -> String {
        if case .symbol(let name) = icon { return name }
        return "puzzlepiece.extension"   // `.image` fallback in the menu
    }
}
