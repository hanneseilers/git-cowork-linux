import SwiftUI

/// Status bar button that appears when a newer release exists (or one was
/// just installed). Opens a small panel to install it and restart.
struct UpdateBadge: View {
    private let updater = Updater.shared
    @State private var showPanel = false

    var body: some View {
        if let label {
            Button { showPanel.toggle() } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(verbatim: label)
                }
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help(L("A new version of git-cowork is available"))
            .popover(isPresented: $showPanel, arrowEdge: .top) {
                UpdatePanel()
            }
        }
    }

    private var label: String? {
        if let v = updater.installed { return String(localized: "Restart for \(v)") }
        if let r = updater.available { return String(localized: "Update to \(r.version.description)") }
        return nil
    }
}

private struct UpdatePanel: View {
    private let updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let v = updater.installed {
                Text(verbatim: String(localized: "git-cowork \(v) is installed")).font(Theme.Font.headline)
                Text("Restart git-cowork to use it. Your open repositories reopen.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Restart Now") { updater.relaunch() }
                        .buttonStyle(ActionButtonStyle.primary())
                }
            } else if let r = updater.available {
                Text(verbatim: String(localized: "git-cowork \(r.version.description) is available")).font(Theme.Font.headline)
                Text(verbatim: String(localized: "You have \(updater.current?.description ?? "?")."))
                    .foregroundStyle(.secondary)
                if !r.notes.isEmpty {
                    ScrollView {
                        Text(verbatim: r.notes)
                            .font(Theme.Font.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                }
                if let error = updater.error {
                    Text(verbatim: error).font(Theme.Font.small).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    if let page = r.page {
                        Link("Release Notes", destination: page).font(Theme.Font.small)
                    }
                    Spacer()
                    if updater.installing {
                        ProgressView().controlSize(.small)
                        Text("Installing…").foregroundStyle(.secondary)
                    } else {
                        Button("Update Now") { Task { await updater.install() } }
                            .buttonStyle(ActionButtonStyle.primary())
                    }
                }
            }
        }
        .font(Theme.Font.body)
        .padding(Theme.Metrics.panelPadding)
        .frame(width: 340)
    }
}
