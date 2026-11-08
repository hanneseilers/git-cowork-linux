import CGtk
import Foundation
import GitCoworkCore

/// The model's sheets (new branch, tag, rename, worktree, stash, task,
/// review request, team) as dialogs.
@MainActor
enum Sheets {
    static func present(_ sheet: SheetKind, page: RepoPage) {
        switch sheet {
        case .newBranch(let from, let label): newBranch(from: from, label: label, page: page)
        case .newTag(let sha): newTag(sha: sha, page: page)
        case .renameBranch(let old): rename(old, page: page)
        case .addWorktree(let base): addWorktree(base: base, page: page)
        case .stash: stash(page: page)
        case .newTask(let status): CoworkSheets.newTask(status: status, page: page)
        case .requestReview(let branch): CoworkSheets.requestReview(branch: branch, page: page)
        case .team: CoworkSheets.team(page: page)
        }
    }

    /// A labeled field for forms.
    static func field(_ title: String, _ widget: Widget) -> Widget {
        let b = Box.v(4)
        b.append(Label(title, "caption-heading"))
        b.append(widget)
        return b
    }

    static func error(_ text: String) -> Label {
        let l = Label(text, "error", "caption")
        l.wrap()
        l.visible = false
        return l
    }

    private static func newBranch(from: String, label: String, page: RepoPage) {
        let m = page.model
        let name = Entry(placeholder: L("feature/my-change"))
        let checkout = Check(L("Check out the new branch"), true)
        let err = error("")
        let form = Box.v(10)
        form.append(field(L("Name"), name))
        form.append(checkout)
        form.append(err)
        _ = Dialogs.form(String(localized: "New Branch from \(label)"), content: form, confirm: L("Create Branch"),
                         parent: page.root, focus: name) {
            let n = name.text.trimmingCharacters(in: .whitespaces)
            guard RefName.isValid(n) else {
                err.text = L("That isn't a valid branch name."); err.visible = true; return false
            }
            guard m.localBranch(named: n) == nil else {
                err.text = String(localized: "A branch named \(n) already exists."); err.visible = true; return false
            }
            let co = checkout.isOn
            Task { await m.createBranch(n, from: from, checkout: co) }
            return true
        }
    }

    private static func newTag(sha: String, page: RepoPage) {
        let m = page.model
        let name = Entry(placeholder: "v1.0.0")
        let message = Entry(placeholder: L("Optional: makes an annotated tag"))
        let err = error("")
        let form = Box.v(10)
        form.append(field(L("Name"), name))
        form.append(field(L("Message"), message))
        form.append(err)
        _ = Dialogs.form(String(localized: "Create Tag at \(String(sha.prefix(7)))"), content: form, confirm: L("Create Tag"),
                         parent: page.root, focus: name) {
            let n = name.text.trimmingCharacters(in: .whitespaces)
            guard RefName.isValid(n) else { err.text = L("That isn't a valid tag name."); err.visible = true; return false }
            guard !m.tags.contains(where: { $0.name == n }) else {
                err.text = String(localized: "A tag named \(n) already exists."); err.visible = true; return false
            }
            let msg = message.text
            Task { await m.createTag(n, at: sha, message: msg) }
            return true
        }
    }

    private static func rename(_ old: String, page: RepoPage) {
        let m = page.model
        let name = Entry(text: old)
        let err = error("")
        let form = Box.v(10)
        form.append(field(L("New name"), name))
        form.append(err)
        _ = Dialogs.form(String(localized: "Rename \(old)"), content: form, confirm: L("Rename"), parent: page.root, focus: name) {
            let n = name.text.trimmingCharacters(in: .whitespaces)
            guard RefName.isValid(n) else { err.text = L("That isn't a valid branch name."); err.visible = true; return false }
            guard n == old || m.localBranch(named: n) == nil else {
                err.text = String(localized: "A branch named \(n) already exists."); err.visible = true; return false
            }
            if n != old { Task { await m.renameBranch(old, to: n) } }
            return true
        }
    }

    private static func addWorktree(base: String?, page: RepoPage) {
        let m = page.model
        let start = base ?? m.currentBranch ?? "HEAD"
        // A local branch that isn't checked out anywhere can be used as is.
        let existing = m.localBranch(named: start) != nil && !m.worktrees.contains { $0.branch == start }
        let useExisting = Check(String(localized: "Check out \(start) itself"), existing)
        useExisting.sensitive = existing
        let branch = Entry(placeholder: L("New branch name"))
        let path = Entry(text: m.suggestedWorktreePath(branch: existing ? start : "new-branch"))
        let choose = Button(icon: "folder-open-symbolic") {}
        let err = error("")
        let pathRow = Box.h(4, [path.hexpand(), choose])
        let form = Box.v(10)
        form.append(Label(String(localized: "Starts from \(start)."), "dim-label").wrap())
        form.append(useExisting)
        let branchField = field(L("New branch"), branch)
        form.append(branchField)
        form.append(field(L("Folder"), pathRow))
        form.append(err)
        var pathEdited = false
        branchField.visible = !existing
        useExisting.onToggleChange { on in
            branchField.visible = !on
            if !pathEdited { path.text = m.suggestedWorktreePath(branch: on ? start : (branch.text.isEmpty ? "new-branch" : branch.text)) }
        }
        branch.onChanged {
            if !pathEdited { path.text = m.suggestedWorktreePath(branch: branch.text.isEmpty ? "new-branch" : branch.text) }
        }
        path.onChanged { if path.text != m.suggestedWorktreePath(branch: branch.text) { pathEdited = true } }
        choose.onClicked {
            Dialogs.chooseFolder(title: L("Folder for the worktree"), parent: page.root) { dir in
                path.text = dir + "/" + (path.text as NSString).lastPathComponent
                pathEdited = true
            }
        }
        _ = Dialogs.form(L("Add Worktree"), content: form, confirm: L("Add Worktree"), parent: page.root, focus: existing ? path : branch) {
            let p = path.text.trimmingCharacters(in: .whitespaces)
            guard p.hasPrefix("/") else { err.text = L("Choose a folder (a full path)."); err.visible = true; return false }
            guard !FileManager.default.fileExists(atPath: p) else {
                err.text = L("That folder already exists. Choose a new one."); err.visible = true; return false
            }
            var newBranch: String?
            if !useExisting.isOn {
                let b = branch.text.trimmingCharacters(in: .whitespaces)
                guard RefName.isValid(b) else { err.text = L("That isn't a valid branch name."); err.visible = true; return false }
                guard m.localBranch(named: b) == nil else {
                    err.text = String(localized: "A branch named \(b) already exists."); err.visible = true; return false
                }
                newBranch = b
            }
            Task {
                if await m.addWorktree(path: p, newBranch: newBranch, base: start) { page.openInNewTab(p) }
            }
            return true
        }
    }

    private static func stash(page: RepoPage) {
        let m = page.model
        let message = Entry(placeholder: L("Optional description"))
        let form = Box.v(10)
        form.append(Label(L("Saves all uncommitted changes, including new files, and cleans the working copy."), "dim-label").wrap())
        form.append(field(L("Message"), message))
        _ = Dialogs.form(L("Stash Changes"), content: form, confirm: L("Stash"), parent: page.root, focus: message) {
            let msg = message.text
            Task { await m.stash(message: msg) }
            return true
        }
    }
}

extension Check {
    func onToggleChange(_ fn: @escaping @MainActor (Bool) -> Void) {
        Signal.on(raw, "toggled") { [weak self] in
            guard let self else { return }
            fn(self.isOn)
        }
    }
}
