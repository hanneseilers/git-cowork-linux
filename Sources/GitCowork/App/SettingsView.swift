import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.Key.editorApp) private var editorApp = "Visual Studio Code"
    @AppStorage(Prefs.Key.terminalApp) private var terminalApp = "Terminal"
    @AppStorage(Prefs.Key.hostOverrides) private var hostOverrides = ""
    @AppStorage(Prefs.Key.coworkRemote) private var coworkRemote = ""
    @AppStorage(Prefs.Key.coworkAutoSync) private var coworkAutoSync = true

    var body: some View {
        Form {
            AccountsSection()
            Section("Apps") {
                TextField("Editor", text: $editorApp, prompt: Text("Visual Studio Code, Cursor, Zed…"))
                TextField("Terminal", text: $terminalApp, prompt: Text("Terminal, iTerm, Ghostty, Warp…"))
                Text("Application names as they appear in /Applications.")
                    .font(Theme.Font.small).foregroundStyle(.secondary)
            }
            Section("Self-hosted servers") {
                TextEditor(text: $hostOverrides)
                    .font(Theme.Font.mono)
                    .frame(height: 80)
                Text("One per line: host = github | gitlab | gitea | forgejo. Used for \"Open on…\" and \"Create Pull/Merge Request\" links. github.com, and hosts with gitlab, gitea or forgejo in their name, are detected automatically.")
                    .font(Theme.Font.small).foregroundStyle(.secondary)
            }
            Section("Cowork") {
                TextField("Sync remote", text: $coworkRemote, prompt: Text("Remote with cowork data, else origin"))
                Toggle("Sync tasks automatically", isOn: $coworkAutoSync)
                Text("Tasks, reviews and comments live on the hidden ref refs/cowork/main and are fetched and pushed with plain git, about once a minute while git-cowork is in front. Turn this off to sync only from the status bar or Repository > Sync Tasks Now.")
                    .font(Theme.Font.small).foregroundStyle(.secondary)
            }
            Section("Git") {
                LabeledContent("Executable", value: GitRunner.shared.gitPath)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
