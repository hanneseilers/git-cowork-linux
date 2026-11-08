import CGtk
import Foundation
import GitCoworkCore

/// New task, review request and team editing.
@MainActor
enum CoworkSheets {
    static func newTask(status: TaskStatus, page: RepoPage) {
        let m = page.model
        let store = m.cowork
        let title = Entry(placeholder: L("What needs doing?"))
        let statusDrop = DropDown(TaskStatus.allCases.map(\.label), selected: TaskStatus.allCases.firstIndex(of: status) ?? 1)
        var people: [(String, String?)] = [(L("Unassigned"), nil)]
        if !store.me.email.isEmpty { people.append((store.me.displayName + L(" (me)"), store.me.email)) }
        people += store.others.map { ($0.displayName, $0.email) }
        let assignee = DropDown(people.map(\.0))
        let labels = Entry(placeholder: L("Labels, separated by commas"))
        let body = TextView()
        let bodyScroll = Scrolled(body)
        bodyScroll.size(380, 100)
        bodyScroll.css("card")
        let err = Sheets.error("")
        let form = Box.v(10)
        form.append(Sheets.field(L("Title"), title))
        let row = Box.h(10).homogeneous()
        row.append(Sheets.field(L("Status"), statusDrop))
        row.append(Sheets.field(L("Assignee"), assignee))
        form.append(row)
        form.append(Sheets.field(L("Labels"), labels))
        form.append(Sheets.field(L("Description"), bodyScroll))
        form.append(err)
        _ = Dialogs.form(L("New Task"), content: form, confirm: L("Create Task"), parent: page.root, focus: title) {
            let t = title.text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { err.text = L("Give the task a title."); err.visible = true; return false }
            let st = TaskStatus.allCases[max(0, statusDrop.selected)]
            let who = people.indices.contains(assignee.selected) ? people[assignee.selected].1 : nil
            let ls = labels.text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let text = body.text
            Task {
                if let task = await store.createTask(title: t, status: st, assignee: who, labels: ls, body: text) {
                    m.centerMode = .board
                    m.coworkSelection = .task(task.id)
                } else {
                    m.alert = AlertItem(title: "Couldn't create the task", message: store.syncError ?? "Writing to refs/cowork/main failed.")
                }
            }
            return true
        }
    }

    static func requestReview(branch: String, page: RepoPage) {
        let m = page.model
        let store = m.cowork
        let defaultBase = m.baseBranch()?.name ?? "main"
        var baseOptions = m.localBranches.map(\.name).filter { $0 != branch }
        if let d = m.baseBranch()?.name, !baseOptions.contains(d), d != branch { baseOptions.insert(d, at: 0) }
        let base = DropDown(baseOptions, selected: baseOptions.firstIndex(of: defaultBase) ?? 0)
        let tip = m.branch(named: branch)?.target
        let title = Entry(text: tip.flatMap { m.commit($0)?.subject } ?? branch)
        let tasks = store.tasks.filter { $0.status != .done }
        let taskOptions = [L("None")] + tasks.map { "\($0.id)  \($0.title)" }
        let linked = tasks.firstIndex { $0.branch == branch }.map { $0 + 1 } ?? 0
        let taskDrop = DropDown(taskOptions, selected: linked)
        let body = TextView()
        let bodyScroll = Scrolled(body)
        bodyScroll.size(400, 80)
        bodyScroll.css("card")
        var selected = Set<String>()
        let reviewers = Box.v(2)
        let candidates = store.others
        if candidates.isEmpty {
            reviewers.append(Label(L("No teammates known yet. Add them under Team, or they appear once they commit."), "dim-label").wrap())
        }
        for p in candidates.prefix(20) {
            reviewers.append(Check("\(p.displayName)  <\(p.email)>") { on in
                if on { selected.insert(p.email) } else { selected.remove(p.email) }
            })
        }
        let extra = Entry(placeholder: L("More reviewers: emails, separated by commas"))
        let links = m.links(for: nil)
        let openPR = links.map { Check(String(localized: "Also open a \(L($0.pullRequestTerm)) page on \($0.host)")) }
        let err = Sheets.error("")
        let form = Box.v(10)
        form.append(Label(String(localized: "Review of \(branch)"), "gc-mono"))
        form.append(Sheets.field(L("Title"), title))
        form.append(Sheets.field(L("Base"), base))
        form.append(Sheets.field(L("Reviewers"), Box.v(4, [reviewers, extra])))
        form.append(Sheets.field(L("Task"), taskDrop))
        form.append(Sheets.field(L("Note"), bodyScroll))
        if let openPR { form.append(openPR) }
        // Unpushed work can't be fetched by reviewers.
        if let local = m.localBranch(named: branch) {
            let onRemote = local.upstream != nil || m.remoteBranches.contains { $0.branchNameWithoutRemote == branch }
            if !onRemote || local.ahead > 0 {
                let warning = !onRemote
                    ? String(localized: "\(branch) isn't on the remote yet. Push it so reviewers can fetch it.")
                    : (local.ahead == 1 ? String(localized: "1 commit on \(branch) not pushed yet.") : String(localized: "\(local.ahead) commits on \(branch) not pushed yet."))
                let row = Box.h(6)
                row.append(Image("dialog-warning-symbolic"))
                row.append(Label(warning).wrap().hexpand())
                row.append(Button(L("Push Branch")) {
                    Task { if m.currentBranch == branch { await m.push() } else { await m.push(branch: branch) } }
                })
                form.append(row)
            }
        }
        form.append(err)
        _ = Dialogs.form(L("Request Review"), content: Scrolled(form).propagateHeight().minHeight(200), confirm: L("Request Review"),
                         parent: page.root, focus: title) {
            let t = title.text.trimmingCharacters(in: .whitespaces)
            let more = extra.text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains("@") }
            let all = Array(selected) + more
            guard !t.isEmpty else { err.text = L("Give the review a title."); err.visible = true; return false }
            guard let baseName = base.selectedItem else { err.text = L("Choose a base branch."); err.visible = true; return false }
            guard !all.isEmpty else { err.text = L("Choose at least one reviewer."); err.visible = true; return false }
            let task = taskDrop.selected > 0 ? tasks[taskDrop.selected - 1].id : nil
            let text = body.text
            let prURL = (openPR?.isOn ?? false) ? links?.newPullRequestURL(branch: branch, base: baseName) : nil
            Task {
                guard let r = await store.requestReview(branch: branch, base: baseName, title: t, reviewers: all, body: text, taskID: task) else {
                    m.alert = AlertItem(title: "Couldn't request the review", message: store.syncError ?? "Writing to refs/cowork/main failed.")
                    return
                }
                m.openDiff = nil
                m.centerMode = .reviews
                m.coworkSelection = .review(r.id)
                if let prURL { External.browse(prURL) }
            }
            return true
        }
    }

    static func team(page: RepoPage) {
        let m = page.model
        let store = m.cowork
        var members = store.snapshot.team
        if members.isEmpty { members = store.people }
        let rowsBox = Box.v(6)
        var fields: [(handle: Entry, name: Entry, email: Entry, row: Box)] = []
        func addRow(_ member: TeamMember?) {
            let handle = Entry(placeholder: L("handle"), text: member?.handle ?? "")
            let name = Entry(placeholder: L("Name"), text: member?.name ?? "")
            let email = Entry(placeholder: "name@example.com", text: member?.email ?? "")
            handle.size(90, -1)
            name.hexpand()
            email.hexpand()
            let row = Box.h(6)
            row.append(Label("@"))
            row.append(handle)
            row.append(name)
            row.append(email)
            let remove = Button(icon: "list-remove-symbolic", "flat")
            row.append(remove)
            rowsBox.append(row)
            fields.append((handle, name, email, row))
            remove.onClicked { [weak row] in
                guard let row else { return }
                row.visible = false
            }
        }
        members.forEach { addRow($0) }
        let form = Box.v(10)
        form.append(Label(L("Saved in the repository for everyone. Handles are used for @mentions; emails match commits and git config user.email."), "dim-label").wrap())
        form.append(Scrolled(rowsBox).propagateHeight().minHeight(120))
        form.append(Button(L("Add Member"), icon: "list-add-symbolic", "flat") { addRow(nil) }.halign(GTK_ALIGN_START))
        let err = Sheets.error("")
        form.append(err)
        _ = Dialogs.form(L("Team"), content: form, confirm: L("Save"), parent: page.root) {
            var result: [TeamMember] = []
            for f in fields where f.row.visible {
                let email = f.email.text.trimmingCharacters(in: .whitespaces)
                guard !email.isEmpty else { continue }
                guard email.contains("@"), !email.contains(where: { $0.isWhitespace || $0 == "\n" }) else {
                    err.text = String(localized: "\(email) isn't an email address."); err.visible = true; return false
                }
                let handle = f.handle.text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
                result.append(TeamMember(handle: handle, name: f.name.text.trimmingCharacters(in: .whitespaces), email: email))
            }
            Task { await store.saveTeam(result) }
            return true
        }
    }
}
