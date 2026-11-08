import CGtk
import Foundation
import GitCoworkCore

/// Settings › Accounts: sign in with a token or the browser (device flow),
/// create an SSH key per account, sign out. Tokens and key passphrases go to
/// the Secret Service; only git-cowork's own git commands use them.
@MainActor
enum AccountsPage {
    static func defaultHost(_ kind: HostKind) -> String {
        switch kind {
        case .github: "github.com"
        case .gitlab: "gitlab.com"
        case .gitea: "codeberg.org"
        }
    }

    static func make() -> Widget {
        let page = Widget(raw: RP(adw_preferences_page_new()))
        adw_preferences_page_set_title(page.p(), L("Accounts"))
        adw_preferences_page_set_icon_name(page.p(), "system-users-symbolic")
        let group = Widget(raw: RP(adw_preferences_group_new()))
        adw_preferences_group_set_title(group.p(), L("Accounts"))
        adw_preferences_group_set_description(group.p(), L("Used for HTTPS remotes on these servers, and for SSH remotes once you create an SSH key, only by git-cowork. Git in the terminal and other servers keep your own setup. Tokens and key passphrases are kept in the Secret Service (GNOME Keyring, KWallet)."))
        adw_preferences_page_add(page.p(), group.p())
        page.keep(group)

        let list = ListBox("boxed-list")
        adw_preferences_group_add(group.p(), list.w)
        group.keep(list)
        let buttons = Box.h(6).margins(10, 0, 0, 0)
        buttons.append(Button(L("Sign In to GitHub…"), "flat") { signInBrowser(.github, parent: page) })
        buttons.append(Button(L("Sign In to GitLab…"), "flat") { signInBrowser(.gitlab, parent: page) })
        buttons.append(Button(L("Add Token…"), "suggested-action") { addToken(parent: page) })
        adw_preferences_group_add(group.p(), buttons.w)
        group.keep(buttons)

        list.track {
            let accounts = AccountStore.shared.accounts
            list.removeAll()
            if accounts.isEmpty {
                list.append(Label(L("No accounts. Git works as in the terminal; add an account so HTTPS push and pull on GitHub, GitLab, Gitea or Forgejo just work."), "dim-label").wrap().margin(12), activatable: false)
            }
            for account in accounts {
                let row = Box.h(10).margins(8, 10, 8, 10)
                row.append(avatar(account.username, email: account.username + "@" + account.host, size: 28))
                let texts = Box.v(2).hexpand()
                texts.append(Label(account.username, "heading"))
                texts.append(Label("\(account.kind.title) · \(account.host)" + (account.sshKey != nil ? L(" · SSH key") : ""), "dim-label", "caption"))
                row.append(texts)
                if account.sshKey != nil {
                    row.append(Button(L("SSH Host Entry…"), "flat") { hostEntry(account, parent: page) })
                } else if account.canAddSSHKey {
                    row.append(Button(L("Create SSH Key…"), "flat") { createKey(account, parent: page) })
                }
                row.append(Button(L("Sign Out"), "flat", "error") {
                    Dialogs.confirm(String(localized: "Sign out of \(account.host)?"),
                                    L("git-cowork stops using this account. Key files stay in ~/.ssh and on the server."),
                                    confirm: L("Sign Out"), parent: page) { AccountStore.shared.signOut(account) }
                })
                list.append(row, activatable: false)
            }
        }
        return page
    }

    // MARK: Token

    static func addToken(parent: Widget?) {
        let kinds = HostKind.allCases
        let kind = DropDown(kinds.map(\.title))
        let host = Entry(text: defaultHost(.github))
        let token = Widget(raw: RP(gtk_password_entry_new()))
        gtk_password_entry_set_show_peek_icon(OP(token.raw), 1)
        let hint = Label("", "dim-label", "caption").wrap()
        let link = Button(L("Create one…"), "flat")
        let err = Sheets.error("")
        let form = Box.v(10)
        form.append(Sheets.field(L("Server type"), kind))
        form.append(Sheets.field(L("Server"), host))
        form.append(Sheets.field(L("Token"), token))
        form.append(Box.h(6, [hint.hexpand(), link]))
        form.append(err)
        var lastKind = HostKind.github
        func update() {
            let k = kinds[max(0, kind.selected)]
            if host.text == defaultHost(lastKind) { host.text = defaultHost(k) }
            lastKind = k
            hint.text = String(localized: "Needs the scopes \(k.scopesHint).")
            link.visible = HostAccount.normalizeHost(host.text).flatMap { HostAPI.newTokenPage(kind: k, host: $0) } != nil
        }
        update()
        Signal.onPtr(kind.raw, "notify::selected") { _ in update() }
        host.onChanged { update() }
        link.onClicked {
            let k = kinds[max(0, kind.selected)]
            if let h = HostAccount.normalizeHost(host.text), let page = HostAPI.newTokenPage(kind: k, host: h) { External.browse(page) }
        }
        var working = false
        var dialog: AlertDialog?
        dialog = Dialogs.form(L("Add Access Token"), content: form, confirm: L("Add"), parent: parent, focus: token) {
            guard !working else { return false }
            let k = kinds[max(0, kind.selected)]
            guard let h = HostAccount.normalizeHost(host.text) else {
                err.text = String(localized: "\(host.text) isn't a valid server name."); err.visible = true; return false
            }
            let t = String(cString: gtk_editable_get_text(OP(token.raw))).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { err.text = L("Paste the token."); err.visible = true; return false }
            working = true
            err.text = L("Checking the token…"); err.visible = true
            Task {
                defer { working = false }
                do {
                    let name = try await SignIn.username(kind: k, host: h, token: t)
                    try AccountStore.shared.add(HostAccount(host: h, kind: k, username: name, method: .token), tokens: TokenSet(access: t))
                    dialog?.close()
                } catch {
                    err.text = Keychain.lastError.map { error.localizedDescription + "\n" + $0 } ?? error.localizedDescription
                    err.visible = true
                }
            }
            return false   // stays open until the check is done; closed on success
        }
    }

    // MARK: Browser sign-in (OAuth device flow)

    static func signInBrowser(_ kind: HostKind, parent: Widget?) {
        let host = Entry(text: defaultHost(kind))
        let clientID = Entry(placeholder: L("OAuth client ID"))
        let help = Label(kind == .github
            ? L("Register an OAuth app under Settings > Developer settings > OAuth Apps on that server, tick \"Enable Device Flow\", and paste its client ID. Or use Add Token instead.")
            : L("Add an application under User settings > Applications on that server (GitLab 17.3 or later): untick \"Confidential\", allow the device code grant, scopes read_user, api and write_repository. Paste its application ID. Or use Add Token instead."),
            "dim-label", "caption").wrap()
        let codeLabel = Label("", "title-2", "gc-mono")
        codeLabel.selectable()
        let status = Label(L("You approve git-cowork in your browser. No password is typed here."), "dim-label").wrap()
        let err = Sheets.error("")
        let form = Box.v(10)
        form.append(Sheets.field(L("Server"), host))
        let idField = Sheets.field(L("OAuth client ID"), clientID)
        form.append(idField)
        form.append(help)
        form.append(codeLabel)
        form.append(status)
        form.append(err)
        func refreshID() {
            let known = HostAccount.normalizeHost(host.text).flatMap { OAuthApps.clientID(for: $0) }
            idField.visible = known == nil
            help.visible = known == nil
        }
        refreshID()
        host.onChanged { refreshID() }
        codeLabel.visible = false
        var task: Task<Void, Never>?
        var dialog: AlertDialog?
        dialog = Dialogs.form(String(localized: "Sign In to \(kind.title)"), content: form, confirm: L("Continue"), parent: parent, focus: host) {
            guard task == nil else { return false }
            guard let h = HostAccount.normalizeHost(host.text) else {
                err.text = String(localized: "\(host.text) isn't a valid server name."); err.visible = true; return false
            }
            let entered = clientID.text.trimmingCharacters(in: .whitespaces)
            guard let id = OAuthApps.clientID(for: h) ?? (entered.isEmpty ? nil : entered) else {
                err.text = L("Paste the OAuth client ID, or use Add Token instead."); err.visible = true; return false
            }
            let enteredID = OAuthApps.clientID(for: h) == nil
            err.visible = false
            task = Task {
                defer { task = nil }
                do {
                    let code = try await SignIn.requestCode(kind: kind, host: h, clientID: id)
                    codeLabel.text = code.userCode
                    codeLabel.visible = true
                    status.text = String(localized: "Enter this code on \(code.verificationURL.host ?? h) and approve git-cowork:") + "\n" + L("Waiting for approval…")
                    External.copy(code.userCode)
                    External.browse(code.verificationURLComplete ?? code.verificationURL)
                    let tokens = try await SignIn.waitForToken(kind: kind, host: h, clientID: id, code: code)
                    let name = try await SignIn.username(kind: kind, host: h, token: tokens.access)
                    if enteredID { OAuthApps.save(id, for: h) }
                    try AccountStore.shared.add(HostAccount(host: h, kind: kind, username: name, method: .oauth), tokens: tokens)
                    dialog?.close()
                } catch is CancellationError {
                } catch {
                    codeLabel.visible = false
                    err.text = error.localizedDescription
                    err.visible = true
                }
            }
            return false   // closed when signed in
        }
        // Cancel stops polling.
        if let dialog { Signal.on(dialog.raw, "closed") { task?.cancel() } }
    }

    // MARK: SSH keys

    static func createKey(_ account: HostAccount, parent: Widget?) {
        let shown = tildePath(SSHKeys.plannedPath(for: account) ?? SSHKeys.sshDir + "/git-cowork_\(SSHKey.sshHost(account.host))")
        let form = Box.v(10)
        form.append(Label(String(localized: "git-cowork makes a new key, adds it to \(account.username) on \(account.host), and uses it for SSH remotes on \(SSHKey.sshHost(account.host))."), "dim-label").wrap())
        form.append(Label(String(localized: "Saved as \(shown), with its passphrase in the Secret Service. Your ~/.ssh/config isn't changed."), "dim-label").wrap())
        let err = Sheets.error("")
        form.append(err)
        var working = false
        var dialog: AlertDialog?
        dialog = Dialogs.form(L("Create SSH Key"), content: form, confirm: L("Create Key"), parent: parent) {
            guard !working else { return false }
            working = true
            err.text = L("Creating key…"); err.visible = true
            Task {
                defer { working = false }
                do {
                    let path = try await SSHKeys.create(for: account)
                    AccountStore.shared.setSSHKey(path, for: account)
                    dialog?.close()
                } catch {
                    err.text = error.localizedDescription
                    err.visible = true
                }
            }
            return false   // closed once the key is made
        }
    }

    static func hostEntry(_ account: HostAccount, parent: Widget?) {
        guard let path = account.sshKey,
              let entry = SSHKey.hostEntry(host: account.host, keyPath: path, home: NSHomeDirectory()) else { return }
        let form = Box.v(10)
        form.append(Label(L("git-cowork already uses this key. To use it in the terminal too, add this near the top of ~/.ssh/config:"), "dim-label").wrap())
        let text = TextView(text: entry, monospace: true, editable: false)
        form.append(Scrolled(text).size(420, 110))
        form.append(Label(L("ssh will ask for the key's passphrase; it is stored in the Secret Service as \"git-cowork SSH key\"."), "dim-label", "caption").wrap())
        form.append(Button(L("Copy"), icon: "edit-copy-symbolic") { External.copy(entry) }.halign(GTK_ALIGN_START))
        let d = AlertDialog(L("SSH Host Entry"), "")
        d.setExtra(form)
        d.addResponse("ok", L("Done"))
        d.present(parent) { _ in }
    }
}

/// Clone: paste a URL, or pick from the repositories of an added account.
@MainActor
enum CloneDialog {
    static var defaultParent: String {
        for dir in ["/src", "/code", "/Projects", "/projects", "/git", "/Documents/GitHub"] {
            let path = NSHomeDirectory() + dir
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return NSHomeDirectory()
    }

    /// Last path part without ".git": "https://x/org/repo.git" -> "repo". Empty if unusable.
    static func folderName(for url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        let name = s.split(whereSeparator: { $0 == "/" || $0 == ":" || $0 == "\\" }).last.map(String.init) ?? ""
        return name == "." || name == ".." || name.hasPrefix("-") ? "" : name
    }

    static func present(parent: Widget?, done: @escaping @MainActor (String) -> Void) {
        let url = Entry(placeholder: "git@github.com:org/repo.git " + L("or") + " https://…")
        let folder = Entry(text: defaultParent)
        let choose = Button(icon: "folder-open-symbolic")
        let target = Label("", "dim-label", "caption")
        let err = Sheets.error("")
        let form = Box.v(10)

        // Repositories of added accounts.
        let accounts = AccountStore.shared.accounts
        if !accounts.isEmpty {
            let accountDrop = DropDown(accounts.map { "\($0.username) · \($0.host)" })
            let filter = Entry(placeholder: L("Filter repositories"), search: true)
            let repoList = ListBox("boxed-list")
            let status = Label(L("Loading…"), "dim-label", "caption")
            var repos: [HostRepo] = []
            var loadTask: Task<Void, Never>?
            func show() {
                repoList.removeAll()
                let q = filter.text
                for r in repos.filter({ $0.matches(q) }).prefix(200) {
                    let row = Box.h(8).margins(4, 8, 4, 8)
                    row.append(Image(r.isPrivate ? "changes-prevent-symbolic" : "folder-remote-symbolic", size: 14))
                    row.append(Label(r.fullPath).hexpand().ellipsize(PANGO_ELLIPSIZE_MIDDLE))
                    if let d = r.updatedAt { row.append(Label(relativeDate(d), "dim-label", "caption")) }
                    repoList.append(row, action: { url.text = r.cloneURL })
                }
                status.text = repos.isEmpty ? status.text : String(localized: "\(repos.count) repositories")
            }
            func load() {
                guard accounts.indices.contains(accountDrop.selected) else { return }
                let account = accounts[accountDrop.selected]
                loadTask?.cancel()
                repos = []
                status.text = L("Loading…")
                show()
                loadTask = Task {
                    do {
                        let list = try await RepoList.fetch(for: account)
                        repos = list
                        status.text = String(localized: "\(list.count) repositories")
                        show()
                    } catch is CancellationError {
                    } catch {
                        status.text = error.localizedDescription
                    }
                }
            }
            Signal.onPtr(accountDrop.raw, "notify::selected") { _ in load() }
            filter.onChanged { show() }
            form.append(Box.h(6, [accountDrop, filter.hexpand()]))
            form.append(Scrolled(repoList).size(460, 200))
            form.append(status)
            form.append(Label(L("Or Enter a URL"), "caption-heading"))
            load()
        }
        form.append(url)
        form.append(Sheets.field(L("Into folder"), Box.h(4, [folder.hexpand(), choose])))
        form.append(target)
        form.append(err)
        func updateTarget() {
            let name = folderName(for: url.text)
            target.text = name.isEmpty ? "" : String(localized: "Clones into \(tildePath(folder.text))/\(name)")
        }
        url.onChanged { updateTarget() }
        folder.onChanged { updateTarget() }
        choose.onClicked {
            Dialogs.chooseFolder(title: L("Clone Into"), parent: parent) { folder.text = $0 }
        }
        var running = false
        var dialog: AlertDialog?
        dialog = Dialogs.form(L("Clone Repository"), content: form, confirm: L("Clone"), parent: parent, focus: url) {
            guard !running else { return false }
            let source = url.text.trimmingCharacters(in: .whitespaces)
            let name = folderName(for: source)
            guard !source.isEmpty, !source.hasPrefix("-"), !name.isEmpty else {
                err.text = L("Enter the repository's URL."); err.visible = true; return false
            }
            let parentDir = folder.text.trimmingCharacters(in: .whitespaces)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: parentDir, isDirectory: &isDir), isDir.boolValue else {
                err.text = L("Choose an existing folder to clone into."); err.visible = true; return false
            }
            let dest = parentDir + "/" + name
            guard !FileManager.default.fileExists(atPath: dest) else {
                err.text = String(localized: "\(tildePath(dest)) already exists."); err.visible = true; return false
            }
            running = true
            err.text = L("Cloning…"); err.visible = true
            Task {
                defer { running = false }
                do {
                    try await RepoModel.clone(source, into: dest)
                    dialog?.close()
                    done(dest)
                } catch {
                    err.text = error.localizedDescription
                    err.visible = true
                }
            }
            return false   // closed once cloned
        }
    }
}
