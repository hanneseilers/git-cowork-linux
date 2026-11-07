import CGtk
import Foundation
import GitCoworkCore

/// Settings (Ctrl+,): apps, git, cowork, updates, accounts. Same keys as the
/// macOS app (Prefs.Key), stored in ~/.config/git-cowork-gtk.plist.
@MainActor
enum SettingsDialog {
    private static var current: Widget?

    static func present(parent: Widget?) {
        let dialog = Widget(raw: RP(adw_preferences_dialog_new()))
        current = dialog
        let d = dialog.raw.assumingMemoryBound(to: AdwPreferencesDialog.self)
        adw_preferences_dialog_add(d, generalPage().p())
        adw_preferences_dialog_add(d, gitPage().p())
        adw_preferences_dialog_add(d, AccountsPage.make().p())
        adw_dialog_present(dialog.raw.assumingMemoryBound(to: AdwDialog.self), parent?.w)
    }

    // MARK: Pages

    private static func page(_ title: String, icon: String) -> Widget {
        let p = Widget(raw: RP(adw_preferences_page_new()))
        adw_preferences_page_set_title(p.p(), title)
        adw_preferences_page_set_icon_name(p.p(), icon)
        return p
    }

    private static func group(_ title: String, _ description: String? = nil) -> Widget {
        let g = Widget(raw: RP(adw_preferences_group_new()))
        adw_preferences_group_set_title(g.p(), title)
        if let description { adw_preferences_group_set_description(g.p(), description) }
        return g
    }

    private static func addGroup(_ group: Widget, to page: Widget) {
        adw_preferences_page_add(page.p(), group.p())
        page.keep(group)
    }

    private static func add(_ row: Widget, to group: Widget) {
        adw_preferences_group_add(group.p(), row.w)
        group.keep(row)
    }

    static func entryRow(_ title: String, key: String, default def: String = "", hint: String? = nil) -> Widget {
        let row = Widget(raw: RP(adw_entry_row_new()))
        adw_preferences_row_set_title(row.p(), title)
        gtk_editable_set_text(OP(row.raw), UserDefaults.standard.string(forKey: key) ?? def)
        Signal.on(row.raw, "changed") {
            let text = String(cString: gtk_editable_get_text(OP(row.raw)))
            UserDefaults.standard.set(text, forKey: key)
        }
        if let hint { row.tooltip(hint) }
        return row
    }

    static func switchRow(_ title: String, subtitle: String, key: String, default def: Bool) -> Widget {
        let row = Widget(raw: RP(adw_switch_row_new()))
        adw_preferences_row_set_title(row.p(), title)
        adw_action_row_set_subtitle(row.p(), subtitle)
        adw_switch_row_set_active(OP(row.raw), gbool(UserDefaults.standard.object(forKey: key) as? Bool ?? def))
        Signal.onPtr(row.raw, "notify::active") { _ in
            UserDefaults.standard.set(adw_switch_row_get_active(OP(row.raw)) != 0, forKey: key)
        }
        return row
    }

    private static func generalPage() -> Widget {
        let p = page(L("General"), icon: "preferences-system-symbolic")
        let apps = group(L("Apps"), L("A command to run, like code, zed or gnome-terminal. Empty: the first one installed."))
        let term = entryRow(L("Terminal"), key: Prefs.Key.terminalApp, default: "",
                            hint: External.detectedTerminal.map { String(localized: "Found: \($0)") })
        let editor = entryRow(L("Editor"), key: Prefs.Key.editorApp, default: "",
                              hint: External.detectedEditor.map { String(localized: "Found: \($0)") })
        // The shared default is a macOS app name; show empty instead.
        if Prefs.terminalApp == "Terminal" { gtk_editable_set_text(OP(term.raw), "") }
        if Prefs.editorApp == "Visual Studio Code" && UserDefaults.standard.string(forKey: Prefs.Key.editorApp) == nil {
            gtk_editable_set_text(OP(editor.raw), "")
        }
        add(term, to: apps)
        add(editor, to: apps)
        addGroup(apps, to: p)

        let hosts = group(L("Self-hosted servers"),
                          L("One per line: host = github | gitlab | gitea | forgejo. Used for \"Open on…\" and pull request links."))
        let text = TextView(text: Prefs.hostOverrides, monospace: true)
        text.onChanged { UserDefaults.standard.set(text.text, forKey: Prefs.Key.hostOverrides) }
        let frame = Scrolled(text)
        frame.size(-1, 90)
        frame.css("card")
        add(frame, to: hosts)
        addGroup(hosts, to: p)

        let updates = group(L("Updates"))
        add(switchRow(L("Check for updates automatically"),
                      subtitle: L("Once a day, git-cowork asks GitHub for the newest release. Nothing about you or your repositories is sent."),
                      key: Prefs.Key.checkForUpdates, default: true), to: updates)
        addGroup(updates, to: p)
        return p
    }

    private static func gitPage() -> Widget {
        let p = page(L("Git"), icon: "emblem-shared-symbolic")
        let git = group(L("Git"))
        add(switchRow(L("Fetch automatically"),
                      subtitle: L("Runs git fetch --all --prune for each open repository every 5 minutes while git-cowork is in front. It never asks for a password."),
                      key: Prefs.Key.autoFetch, default: true), to: git)
        addGroup(git, to: p)

        let cowork = group(L("Cowork"), L("Tasks, reviews and comments live on the hidden ref refs/cowork/main and are fetched and pushed with plain git."))
        add(switchRow(L("Sync tasks automatically"),
                      subtitle: L("About once a minute while git-cowork is in front, every 3 minutes in the background."),
                      key: Prefs.Key.coworkAutoSync, default: true), to: cowork)
        add(entryRow(L("Remote"), key: Prefs.Key.coworkRemote, default: "", hint: L("Remote with cowork data, else origin")), to: cowork)
        addGroup(cowork, to: p)
        return p
    }
}
