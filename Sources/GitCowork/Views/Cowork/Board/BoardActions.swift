import GitCoworkCore
import SwiftUI

/// What the board does to tasks: move, assign, start, delete.
@MainActor
enum BoardActions {
    static func move(_ id: String, to status: TaskStatus, model: RepoModel) {
        guard let t = model.cowork.task(id), t.status != status else { return }
        // Land on top of the new column, like a newly created task.
        let top = model.cowork.tasks.filter { $0.status == status }.compactMap(\.rank).min()
        Task {
            await model.cowork.updateTask(id) {
                $0.status = status
                if status != .done { $0.rank = (top ?? 0) - 1 }
            }
        }
    }

    static func assign(_ id: String, to email: String?, model: RepoModel) {
        guard let t = model.cowork.task(id), t.assignee?.lowercased() != email?.lowercased() else { return }
        Task { await model.cowork.updateTask(id) { $0.assignee = email } }
    }

    /// Drops task `id` into `status`, before `target` (or at the end when nil).
    /// When the task is dragged down within its own column, it lands after
    /// the target instead, which is what the drop line shows.
    @discardableResult
    static func drop(_ id: String, into status: TaskStatus, onto target: String?, model: RepoModel) -> Bool {
        guard let t = model.cowork.task(id), target != id else { return false }
        let full = BoardLogic.sorted(model.cowork.tasks.filter { $0.status == status }, status: status)
        // Done is ordered by date; dropping there only changes the status.
        if status == .done {
            guard t.status != .done else { return false }
            Task { await model.cowork.updateTask(id) { $0.status = .done } }
            return true
        }
        let sourceIndex = full.firstIndex { $0.id == id }
        let column = full.filter { $0.id != id }
        var index = column.count
        if let target, let i = column.firstIndex(where: { $0.id == target }) {
            let draggingDown = sourceIndex.map { s in full.firstIndex { $0.id == target }.map { s < $0 } ?? false } ?? false
            index = draggingDown ? i + 1 : i
        }
        // Same column, same place: nothing to do.
        if let s = sourceIndex, s == index { return false }

        let ranks = BoardLogic.ranks(inserting: id, at: index, in: column)
        // Neighbours without a rank need one too; all go in one commit.
        var edits: [String: (inout CoworkTask) -> Void] = [:]
        for (other, rank) in ranks where other != id { edits[other] = { $0.rank = rank } }
        let rank = ranks[id]
        edits[id] = { $0.status = status; if let rank { $0.rank = rank } }
        let message = edits.count == 1 ? "Update \(id)" : "Reorder \(status.title)"
        Task { await model.cowork.updateTasks(edits, message: message) }
        return true
    }

    /// The local or remote branch the task is linked to, if it exists.
    static func linkedRef(_ t: CoworkTask, model: RepoModel) -> Ref? {
        guard let b = t.branch, !b.isEmpty else { return nil }
        return model.localBranches.first { $0.name == b }
            ?? model.remoteBranches.first { $0.branchNameWithoutRemote == b && !$0.name.hasSuffix("/HEAD") }
    }

    /// Where new task branches start: the remote's default branch, else the
    /// current branch.
    static func startBase(model: RepoModel) -> String {
        if let remote = model.defaultRemote, let d = model.defaultBranch(remote: remote),
           model.remoteBranches.contains(where: { $0.name == "\(remote)/\(d)" }) {
            return "\(remote)/\(d)"
        }
        return model.currentBranch ?? "HEAD"
    }

    /// "Start Task": checks out the task's branch (an existing local one, else
    /// tracking the remote one, else a new one from the remote default
    /// branch), links it, moves the task to In Progress and assigns it to me.
    static func start(_ id: String, model: RepoModel) {
        guard let t = model.cowork.task(id) else { return }
        if let ref = linkedRef(t, model: model) {
            Task { await model.checkout(ref) }
            return
        }
        let name = (t.branch?.isEmpty == false ? t.branch : nil) ?? BoardLogic.branchName(for: t)
        let remote = model.defaultRemote
        let args: [String]
        if model.localBranches.contains(where: { $0.name == name }) {
            args = ["switch", name]
        } else if let remote, model.remoteBranches.contains(where: { $0.name == "\(remote)/\(name)" }) {
            args = ["switch", "--track", "\(remote)/\(name)"]
        } else {
            // --no-track: a new task branch must not push to the base branch.
            args = ["switch", "-c", name, "--no-track", startBase(model: model)]
        }
        Task {
            guard await model.perform("Start task", args) else { return }
            let top = model.cowork.tasks.filter { $0.status == .doing }.compactMap(\.rank).min()
            let me = model.cowork.me.email
            await model.cowork.updateTask(id) { t in
                t.branch = name
                if t.status == .backlog || t.status == .todo {
                    t.status = .doing
                    t.rank = (top ?? 0) - 1
                }
                if t.assignee == nil, !me.isEmpty { t.assignee = me }
            }
        }
    }

    static func confirmDelete(_ id: String, model: RepoModel) {
        guard let t = model.cowork.task(id) else { return }
        let comments = model.cowork.comments(on: t.commentParent).count
        let extra = comments > 0 ? " and its \(comments) comment\(comments == 1 ? "" : "s")" : ""
        model.confirmation = Confirmation(
            title: "Delete \(t.id)?",
            message: "“\(t.title)”\(extra) will be removed for everyone on the next sync.",
            confirmTitle: "Delete"
        ) {
            if model.coworkSelection == .task(t.id) { model.coworkSelection = nil }
            await model.cowork.deleteTask(t)
        }
    }
}

/// Right-click menu for a card.
struct BoardCardMenu: View {
    let model: RepoModel
    let task: CoworkTask

    var body: some View {
        Picker("Move To", selection: Binding(
            get: { task.status },
            set: { BoardActions.move(task.id, to: $0, model: model) })) {
            ForEach(TaskStatus.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)

        Picker("Assign To", selection: Binding(
            get: { assigneeTag },
            set: { BoardActions.assign(task.id, to: $0.isEmpty ? nil : $0, model: model) })) {
            let me = model.cowork.me
            if !me.email.isEmpty { Text("Me").tag(me.email) }
            Text("Unassigned").tag("")
            Divider()
            ForEach(model.cowork.people.filter { $0.id != me.id }) { p in
                Text(p.name.isEmpty ? p.email : p.name).tag(p.email)
            }
        }
        .pickerStyle(.menu)

        Divider()
        if let ref = BoardActions.linkedRef(task, model: model) {
            Button("Checkout Branch") { BoardActions.start(task.id, model: model) }
                .disabled(ref.kind == .localBranch && ref.isHead)
        } else {
            Button("Start Task") { BoardActions.start(task.id, model: model) }
        }
        Button("Copy ID") { External.copy(task.id) }
        Divider()
        Button("Delete…", role: .destructive) { BoardActions.confirmDelete(task.id, model: model) }
    }

    /// The picker tag of the current assignee: the matching person's email as
    /// written in the team list, so the checkmark shows whatever the case.
    private var assigneeTag: String {
        guard let a = task.assignee?.lowercased(), !a.isEmpty else { return "" }
        if a == model.cowork.me.id { return model.cowork.me.email }
        return model.cowork.people.first { $0.id == a }?.email ?? a
    }
}
