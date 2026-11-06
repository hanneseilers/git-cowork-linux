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

    static func confirmDelete(_ id: String, model: RepoModel) {
        guard let t = model.cowork.task(id) else { return }
        let comments = model.cowork.comments(on: t.commentParent).count
        let extra = comments == 0 ? "" : comments == 1 ? L(" and its comment") : String(localized: " and its \(comments) comments")
        model.confirmation = Confirmation(
            title: String(localized: "Delete \(t.id)?"),
            message: String(localized: "“\(t.title)”\(extra) will be removed for everyone on the next sync."),
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
        if let ref = model.linkedBranch(of: task) {
            Button("Checkout Branch") { model.startTask(task.id) }
                .disabled(ref.kind == .localBranch && ref.isHead)
        } else {
            Button("Start Task") { model.startTask(task.id) }
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
