import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.Key.editorApp) private var editorApp = "Visual Studio Code"
    @AppStorage(Prefs.Key.terminalApp) private var terminalApp = "Terminal"
    @AppStorage(Prefs.Key.hostOverrides) private var hostOverrides = ""
    @AppStorage(Prefs.Key.coworkRemote) private var coworkRemote = ""
    @AppStorage(Prefs.Key.coworkAutoSync) private var coworkAutoSync = true
    @AppStorage(Prefs.Key.autoFetch) private var autoFetch = true

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
                Toggle("Fetch automatically", isOn: $autoFetch)
                Text("Runs git fetch --all --prune for each open repository every 5 minutes while git-cowork is in front, so remote branches and ahead/behind stay current. It never asks for a password: if signing in fails, it pauses until a fetch, pull or push of yours works.")
                    .font(Theme.Font.small).foregroundStyle(.secondary)
                LabeledContent("Executable", value: GitRunner.shared.gitPath)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
