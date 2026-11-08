import CGtk
import Foundation
import GitCoworkCore

/// What the board does to tasks: move, assign, drop, delete (same rules as macOS).
@MainActor
enum BoardActions {
    static func move(_ id: String, to status: TaskStatus, model: RepoModel) {
        guard let t = model.cowork.task(id), t.status != status else { return }
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

    @discardableResult
    static func drop(_ id: String, into status: TaskStatus, onto target: String?, model: RepoModel) -> Bool {
        guard let t = model.cowork.task(id), target != id else { return false }
        let full = BoardLogic.sorted(model.cowork.tasks.filter { $0.status == status }, status: status)
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
        if let s = sourceIndex, s == index { return false }
        let ranks = BoardLogic.ranks(inserting: id, at: index, in: column)
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

    /// Right-click menu for a card (also the panel's "More" menu).
    static func menu(_ task: CoworkTask, page: RepoPage) -> [MenuItem] {
        let model = page.model
        var items: [MenuItem] = [.header(L("Move to"))]
        for s in TaskStatus.allCases where s != task.status {
            items.append(MenuItem(s.label) { move(task.id, to: s, model: model) })
        }
        items.append(.separator)
        items.append(.header(L("Assign")))
        if !model.cowork.me.email.isEmpty {
            items.append(MenuItem(L("Me")) { assign(task.id, to: model.cowork.me.email, model: model) })
        }
        for p in model.cowork.others.prefix(8) {
            items.append(MenuItem(p.displayName) { assign(task.id, to: p.email, model: model) })
        }
        if task.assignee != nil { items.append(MenuItem(L("Unassigned")) { assign(task.id, to: nil, model: model) }) }
        items.append(.separator)
        if let ref = model.linkedBranch(of: task), ref.isHead {
            // Already here.
        } else if model.linkedBranch(of: task) != nil {
            items.append(MenuItem(L("Checkout Branch")) { model.startTask(task.id) })
        } else {
            items.append(MenuItem(L("Start Task")) { model.startTask(task.id) })
        }
        if let wt = model.worktree(of: task) {
            if wt.path != model.root.path { items.append(MenuItem(L("Open Worktree")) { page.openInNewTab(wt.path) }) }
        } else {
            items.append(MenuItem(L("Start in New Worktree")) { model.startTaskInWorktree(task.id) { page.openInNewTab($0) } })
        }
        items += [MenuItem(L("Copy ID")) { External.copy(task.id) }, .separator,
                  MenuItem(L("Delete…"), destructive: true) { confirmDelete(task.id, model: model) }]
        return items
    }
}

/// Backlog / To Do / In Progress / In Review / Done, with search, person and label filters.
@MainActor
final class BoardView {
    let root = Box.v(0)
    unowned let page: RepoPage
    private var model: RepoModel { page.model }
    private let search = Entry(placeholder: L("Search tasks"), search: true)
    private let personFilter = MenuButton(L("Everyone"), icon: "system-users-symbolic", "flat")
    private let labelFilter = MenuButton(L("All Labels"), icon: "bookmark-new-symbolic", "flat")
    private let columnsBox = Box.h(10).margins(10, 10, 10, 10)
    private let empty = Widget(raw: RP(adw_status_page_new()))
    private var person: String?   // email, "" = unassigned, nil = everyone
    private var label: String?
    private var signature = ""

    init(page: RepoPage) {
        self.page = page
        let header = Box.h(8)
        header.css("gc-panel-header")
        search.hexpand()
        search.onChanged { [weak self] in self?.render(force: true) }
        header.append(search)
        header.append(personFilter)
        header.append(labelFilter)
        header.append(Button(L("New Task"), icon: "list-add-symbolic", "suggested-action") { [weak self] in
            self?.model.sheet = .newTask(status: .todo)
        }.tooltip(L("New task in To Do (Ctrl+Shift+T)")))
        root.append(header)

        personFilter.content { [weak self] p in
            guard let self else { return }
            var items = [MenuItem(L("Everyone")) { self.person = nil; self.render(force: true) }]
            if !self.model.cowork.me.email.isEmpty {
                items.append(MenuItem(L("Mine")) { self.person = self.model.cowork.me.email; self.render(force: true) })
            }
            items.append(MenuItem(L("Unassigned")) { self.person = ""; self.render(force: true) })
            items.append(.separator)
            for p in self.model.cowork.others {
                items.append(MenuItem(p.displayName) { self.person = p.email; self.render(force: true) })
            }
            Menus.fill(p, items)
        }
        labelFilter.content { [weak self] p in
            guard let self else { return }
            var items = [MenuItem(L("All Labels")) { self.label = nil; self.render(force: true) }]
            for l in self.model.cowork.allLabels {
                items.append(MenuItem(l) { self.label = l; self.render(force: true) })
            }
            Menus.fill(p, items)
        }

        adw_status_page_set_icon_name(empty.op, "view-list-bullet-symbolic")
        adw_status_page_set_title(empty.op, L("No tasks yet"))
        adw_status_page_set_description(empty.op, L("Tasks are stored in this repository on refs/cowork/main and sync with your teammates through the remote."))
        let first = Button(L("Create First Task"), "pill", "suggested-action") { [weak self] in self?.model.sheet = .newTask(status: .todo) }
        first.halign(GTK_ALIGN_CENTER)
        adw_status_page_set_child(empty.op, first.w)
        empty.keep(first)
        empty.vexpand()
        root.append(empty)
        let scroll = Scrolled(columnsBox, hscroll: true)
        scroll.vexpand()
        root.append(scroll)

        root.track { [weak self] in self?.render() }
    }

    private func visible(_ t: CoworkTask) -> Bool {
        if let person {
            if person.isEmpty { if t.assignee != nil { return false } }
            else if t.assignee?.lowercased() != person.lowercased() { return false }
        }
        if let label, !t.labels.contains(label) { return false }
        return BoardLogic.matches(t, query: search.text)
    }

    private func render(force: Bool = false) {
        let store = model.cowork
        let version = store.version
        let selection = model.coworkSelection
        let sig = "\(version)|\(String(describing: selection))|\(person ?? "-")|\(label ?? "-")|\(search.text)|\(model.currentBranch ?? "")"
        guard force || sig != signature else { return }
        signature = sig
        personFilter.setLabel(person.map { $0.isEmpty ? L("Unassigned") : ($0.lowercased() == store.me.id ? L("Mine") : store.person($0)?.displayName ?? $0) } ?? L("Everyone"))
        labelFilter.setLabel(label ?? L("All Labels"))

        let tasks = store.tasks
        empty.visible = tasks.isEmpty && store.loaded
        columnsBox.visible = !tasks.isEmpty || !store.loaded
        columnsBox.removeAll()
        for status in TaskStatus.allCases {
            let column = BoardLogic.sorted(tasks.filter { $0.status == status && visible($0) }, status: status)
            columnsBox.append(makeColumn(status, column, selection: selection))
        }
    }

    private func makeColumn(_ status: TaskStatus, _ tasks: [CoworkTask], selection: CoworkSelection?) -> Widget {
        let col = Box.v(6)
        col.css("gc-column")
        col.size(250, -1)
        col.vexpand()
        let header = Box.h(6).margins(2, 4, 4, 4)
        header.append(Label(status.label, "heading").hexpand())
        header.append(Label("\(tasks.count)", "gc-count"))
        header.append(Button(icon: "list-add-symbolic", "flat", "circular") { [weak self] in
            self?.model.sheet = .newTask(status: status)
        }.tooltip(String(localized: "New task in \(status.label)")))
        col.append(header)
        let cards = Box.v(6)
        for t in tasks { cards.append(card(t, selected: selection == .task(t.id))) }
        let scroll = Scrolled(cards)
        scroll.vexpand()
        col.append(scroll)
        // Drop on the column's free space: to the end.
        addDropTarget(col) { [weak self] id in
            guard let self else { return false }
            return BoardActions.drop(id, into: status, onto: nil, model: self.model)
        }
        return col
    }

    private func card(_ t: CoworkTask, selected: Bool) -> Widget {
        let store = model.cowork
        let c = Box.v(6)
        c.css("gc-card")
        if selected { c.css("gc-selected") }
        let top = Box.h(6)
        top.append(Label(t.id, "gc-mono", "dim-label", "caption").hexpand())
        let comments = store.comments(on: t.commentParent).count
        if comments > 0 { top.append(Label("💬 \(comments)", "dim-label", "caption").tooltip(String(localized: "\(comments) comments"))) }
        if let a = t.assignee, let p = store.person(a) {
            top.append(avatar(p.displayName, email: p.email, size: 18).tooltip(p.displayName))
        }
        c.append(top)
        c.append(Label(t.title).wrap().lines(3))
        if !t.labels.isEmpty || t.branch != nil {
            let bottom = Box.h(4)
            for l in t.labels.prefix(4) { bottom.append(chip(l, color: Theme.labelColor(l))) }
            if let b = t.branch, !b.isEmpty {
                let here = model.linkedBranch(of: t)?.isHead ?? false
                bottom.append(Label((here ? "✓ " : "⎇ ") + b, "dim-label", "caption").ellipsize(PANGO_ELLIPSIZE_MIDDLE).hexpand())
            }
            c.append(bottom)
        }
        c.onClick(button: 1) { [weak self] _, count, _, _ in
            guard let self else { return }
            self.model.coworkSelection = .task(t.id)
            if count == 2 { self.model.startTask(t.id) }
        }
        c.onContextMenu { [weak self, weak c] x, y in
            guard let self, let c else { return }
            self.model.coworkSelection = .task(t.id)
            Menus.popup(BoardActions.menu(t, page: self.page), at: x, y, in: c)
        }
        // Drag the card; drop it on another card to land before it.
        let source = gtk_drag_source_new()!
        let id = t.id
        Signal.onXYProvider(RP(source)) { id }
        c.addController(OP(source))
        addDropTarget(c) { [weak self] dragged in
            guard let self else { return false }
            return BoardActions.drop(dragged, into: t.status, onto: t.id, model: self.model)
        }
        return c
    }

    private func addDropTarget(_ w: Widget, _ fn: @escaping @MainActor (String) -> Bool) {
        let target = gtk_drop_target_new(GType(16 << 2), GDK_ACTION_MOVE)!   // G_TYPE_STRING
        Signal.onDropString(RP(target), fn)
        w.addController(OP(target))
    }

    /// Ctrl+Alt+← / → moves the selected task to the previous / next column.
    func move(_ id: String, by step: Int) {
        guard let t = model.cowork.task(id), let i = TaskStatus.allCases.firstIndex(of: t.status) else { return }
        let j = i + step
        guard TaskStatus.allCases.indices.contains(j) else { return }
        BoardActions.move(id, to: TaskStatus.allCases[j], model: model)
    }
}
