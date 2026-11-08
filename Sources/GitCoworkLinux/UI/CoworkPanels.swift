import CGtk
import Foundation
import GitCoworkCore

/// Short display name for an email: team name, else author name, else the address.
@MainActor
func displayName(_ email: String?, in store: CoworkStore) -> String {
    guard let email, !email.isEmpty else { return L("Unassigned") }
    if email.lowercased() == store.me.id { return store.me.displayName + L(" (me)") }
    return store.person(email)?.displayName ?? email
}

/// Navigates to the board or review list and selects "tasks/CW-…" or "reviews/R-…".
@MainActor
func openCoworkTarget(_ target: String, page: RepoPage) {
    let model = page.model
    model.openDiff = nil
    if target.hasPrefix("tasks/") {
        let id = String(target.dropFirst(6).split(separator: "/").first ?? "")
        model.centerMode = .board
        model.coworkSelection = .task(id)
    } else if target.hasPrefix("reviews/") {
        let id = String(target.dropFirst(8).split(separator: "/").first ?? "")
        model.centerMode = .reviews
        model.coworkSelection = .review(id)
    }
}

/// Text with @mentions in bold.
@MainActor
func mentionMarkup(_ text: String, handles: Set<String>) -> String {
    var out = ""
    var word = ""
    func flush() {
        let escaped = gMarkupEscape(word)
        if word.hasPrefix("@"), handles.contains(String(word.dropFirst()).lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            out += "<b>\(escaped)</b>"
        } else {
            out += escaped
        }
        word = ""
    }
    for ch in text {
        if ch.isWhitespace { flush(); out += gMarkupEscape(String(ch)) } else { word.append(ch) }
    }
    flush()
    return out
}

func gMarkupEscape(_ s: String) -> String {
    guard let c = g_markup_escape_text(s, -1) else { return s }
    defer { g_free(c) }
    return String(cString: c)
}

/// The right panel on Board and Reviews: the selected task or review.
@MainActor
final class CoworkPanel {
    let root = Stack()
    unowned let page: RepoPage
    private let taskPanel: TaskPanel
    private let reviewPanel: ReviewPanel

    init(page: RepoPage) {
        self.page = page
        taskPanel = TaskPanel(page: page)
        reviewPanel = ReviewPanel(page: page)
        let none = Widget(raw: RP(adw_status_page_new()))
        adw_status_page_set_icon_name(none.op, "view-list-bullet-symbolic")
        adw_status_page_set_title(none.op, L("Nothing selected"))
        adw_status_page_set_description(none.op, L("Select a task or a review to see it here."))
        root.add("none", none)
        root.add("task", taskPanel.root)
        root.add("review", reviewPanel.root)
        root.track { [weak self] in
            guard let self else { return }
            switch self.page.model.coworkSelection {
            case .task(let id)? where self.page.model.cowork.task(id) != nil: self.root.visibleName = "task"
            case .review(let id)? where self.page.model.cowork.review(id) != nil: self.root.visibleName = "review"
            default: self.root.visibleName = "none"
            }
        }
    }
}

// MARK: Comments

/// Comments on a task or review, with a composer (Ctrl+Enter sends, @ mentions).
@MainActor
final class CommentThread {
    let root = Box.v(6)
    unowned let page: RepoPage
    private let list = Box.v(6)
    private let input = TextView()
    private let send = Button(L("Comment"), "suggested-action")
    private var parent = ""
    private var shown = ""

    init(page: RepoPage) {
        self.page = page
        root.append(Label(L("Comments"), "heading").margins(8, 0, 0, 0))
        root.append(list)
        let scroll = Scrolled(input)
        scroll.size(-1, 64)
        scroll.css("card")
        root.append(scroll)
        let row = Box.h(6)
        row.append(Label(L("Ctrl+Enter to send · @ to mention"), "dim-label", "caption").hexpand())
        row.append(send)
        root.append(row)
        send.onClicked { [weak self] in self?.submit() }
        input.onKey { [weak self] key, state in
            guard let self else { return false }
            if (Int32(key) == GDK_KEY_Return || Int32(key) == GDK_KEY_KP_Enter), state.rawValue & GDK_CONTROL_MASK.rawValue != 0 {
                self.submit()
                return true
            }
            return false
        }
        input.onChanged { [weak self] in
            guard let self, !self.parent.isEmpty else { return }
            self.page.model.cowork.drafts["comment:" + self.parent] = self.input.text
        }
    }

    func show(parent: String) {
        let store = page.model.cowork
        if parent != self.parent {
            self.parent = parent
            input.text = store.drafts["comment:" + parent] ?? ""
        }
        let comments = store.comments(on: parent)
        let sig = parent + comments.map { $0.id + $0.body }.joined()
        guard sig != shown else { return }
        shown = sig
        list.removeAll()
        if comments.isEmpty {
            list.append(Label(L("No comments yet"), "dim-label"))
        }
        let handles = store.mentionHandles
        for c in comments {
            let box = Box.v(2)
            box.css("gc-comment")
            let head = Box.h(6)
            head.append(avatar(c.authorName.isEmpty ? c.author : c.authorName, email: c.author, size: 18))
            head.append(Label(c.authorName.isEmpty ? c.author : c.authorName, "heading").hexpand().ellipsize())
            head.append(Label(relativeDate(c.created), "dim-label", "caption").tooltip(fullDate(c.created)))
            box.append(head)
            let body = Label("").wrap().selectable()
            body.markup(mentionMarkup(c.body, handles: handles))
            box.append(body)
            list.append(box)
        }
    }

    private func submit() {
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !parent.isEmpty else { return }
        let store = page.model.cowork
        let parent = self.parent
        input.text = ""
        store.drafts["comment:" + parent] = nil
        Task {
            if !(await store.addComment(on: parent, body: text)) {
                store.drafts["comment:" + parent] = text
                self.input.text = text
            }
        }
    }
}

// MARK: Task

@MainActor
final class TaskPanel {
    let root = Box.v(0)
    unowned let page: RepoPage
    private var model: RepoModel { page.model }
    private let idLabel = Label("", "gc-mono", "dim-label")
    private let title = Entry()
    private let status = MenuButton(nil, icon: nil, "flat")
    private let assignee = MenuButton(nil, icon: nil, "flat")
    private let labels = Box.h(4)
    private let addLabel = Entry(placeholder: L("Add label"))
    private let branchBox = Box.h(6)
    private let actions = Box.h(6)
    private let body = TextView()
    private let meta = Label("", "dim-label", "caption")
    private let comments: CommentThread
    private var taskID = ""
    private var signature = ""

    init(page: RepoPage) {
        self.page = page
        comments = CommentThread(page: page)
        let header = Box.h(6)
        header.css("gc-panel-header")
        header.append(Label(L("Task"), "heading"))
        header.append(idLabel.hexpand())
        header.append(Button(icon: "edit-copy-symbolic", "flat") { [weak self] in
            guard let self else { return }
            External.copy(self.taskID)
        }.tooltip(L("Copy ID")))
        let more = MenuButton(icon: "view-more-symbolic", "flat")
        more.content { [weak self] p in
            guard let self, let t = self.model.cowork.task(self.taskID) else { return }
            Menus.fill(p, BoardActions.menu(t, page: self.page))
        }
        header.append(more)
        root.append(header)

        let content = Box.v(10).margins(10, 10, 10, 10)
        title.css("title-4")
        title.onActivate { [weak self] in self?.saveTitle() }
        onFocusLeave(title) { [weak self] in self?.saveTitle() }
        content.append(title)

        let grid = Box.v(4)
        func line(_ name: String, _ w: Widget) {
            let r = Box.h(6)
            r.append(Label(name, "dim-label").size(80, -1))
            r.append(w.hexpand())
            grid.append(r)
        }
        line(L("Status"), status)
        line(L("Assignee"), assignee)
        line(L("Labels"), Box.v(4, [labels, addLabel]))
        line(L("Branch"), branchBox)
        content.append(grid)
        content.append(actions)
        content.append(Label(L("Description"), "heading"))
        let bodyScroll = Scrolled(body)
        bodyScroll.size(-1, 120)
        bodyScroll.css("card")
        onFocusLeave(body) { [weak self] in self?.saveBody() }
        content.append(bodyScroll)
        content.append(meta)
        content.append(comments.root)
        root.append(Scrolled(content).vexpand())

        status.content { [weak self] p in
            guard let self else { return }
            Menus.fill(p, TaskStatus.allCases.map { s in
                MenuItem(s.label) { BoardActions.move(self.taskID, to: s, model: self.model) }
            })
        }
        assignee.content { [weak self] p in
            guard let self else { return }
            let store = self.model.cowork
            var items: [MenuItem] = []
            if !store.me.email.isEmpty { items.append(MenuItem(store.me.displayName + L(" (me)")) { BoardActions.assign(self.taskID, to: store.me.email, model: self.model) }) }
            for person in store.others { items.append(MenuItem(person.displayName) { BoardActions.assign(self.taskID, to: person.email, model: self.model) }) }
            items += [.separator, MenuItem(L("Unassigned")) { BoardActions.assign(self.taskID, to: nil, model: self.model) }]
            Menus.fill(p, items)
        }
        addLabel.onActivate { [weak self] in
            guard let self else { return }
            let l = self.addLabel.text.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty else { return }
            self.addLabel.text = ""
            let id = self.taskID
            Task { await self.model.cowork.updateTask(id) { if !$0.labels.contains(l) { $0.labels.append(l) } } }
        }

        root.track { [weak self] in self?.render() }
    }

    private func render() {
        guard case .task(let id)? = model.coworkSelection, let t = model.cowork.task(id) else { return }
        let store = model.cowork
        var switched = false
        if id != taskID {
            // Save what was typed for the previous task first; the fields
            // keep focus when a card is clicked, so they'd show the old text.
            if !taskID.isEmpty { saveTitle(); saveBody() }
            taskID = id
            signature = ""
            switched = true
        }
        _ = store.version
        comments.show(parent: t.commentParent)
        let sig = "\(t)\(model.currentBranch ?? "")\(model.refs.count)\(model.worktrees.count)"
        guard sig != signature else { return }
        signature = sig
        idLabel.text = t.id
        if switched || !isFocused(title) { title.text = t.title }
        if switched || !isFocused(body) { body.text = t.body }
        status.setLabel(t.status.label)
        assignee.setLabel(displayName(t.assignee, in: store))
        labels.removeAll()
        for l in t.labels {
            let b = Button(l + "  ×", "flat", "gc-chip") { [weak self] in
                guard let self else { return }
                Task { await self.model.cowork.updateTask(id) { $0.labels.removeAll { $0 == l } } }
            }
            b.tooltip(L("Remove label"))
            labels.append(b)
        }
        // Branch
        branchBox.removeAll()
        if let b = t.branch, !b.isEmpty {
            let ref = model.linkedBranch(of: t)
            branchBox.append(Label((ref?.isHead ?? false ? "✓ " : "⎇ ") + b).ellipsize(PANGO_ELLIPSIZE_MIDDLE).hexpand())
            if ref == nil {
                branchBox.append(Label(L("not found"), "dim-label", "caption").tooltip(L("No local or remote branch with this name. Fetch, or link another branch.")))
            }
            branchBox.append(Button(icon: "edit-clear-symbolic", "flat") { [weak self] in
                guard let self else { return }
                Task { await self.model.cowork.updateTask(id) { $0.branch = nil } }
            }.tooltip(L("Unlink branch")))
        } else {
            let link = MenuButton(L("Link Branch"), icon: nil, "flat")
            link.content { [weak self] p in
                guard let self else { return }
                Menus.fill(p, self.model.localBranches.prefix(30).map { ref in
                    MenuItem(ref.name) { Task { await self.model.cowork.updateTask(id) { $0.branch = ref.name } } }
                })
            }
            link.tooltip(L("Link an existing local branch"))
            branchBox.append(link)
        }
        // Actions
        actions.removeAll()
        let linked = model.linkedBranch(of: t)
        if !(linked?.isHead ?? false) {
            actions.append(Button(linked == nil ? L("Start Task") : L("Checkout"), icon: "media-playback-start-symbolic") { [weak self] in
                self?.model.startTask(id)
            }.tooltip(String(localized: "Check out \(RefName.branch(for: t)) here (created if needed), then link it")))
        }
        if let wt = model.worktree(of: t) {
            if wt.path != model.root.path {
                actions.append(Button(L("Open Worktree"), icon: "view-dual-symbolic") { [weak self] in self?.page.openInNewTab(wt.path) })
            }
        } else {
            actions.append(Button(L("In New Worktree"), icon: "folder-new-symbolic") { [weak self] in
                guard let self else { return }
                self.model.startTaskInWorktree(id) { self.page.openInNewTab($0) }
            }.tooltip(String(localized: "Create \(RefName.branch(for: t)) in its own folder and open it in a new tab, e.g. for an agent")))
        }
        if let b = t.branch, !b.isEmpty, linked != nil {
            actions.append(Button(L("Request Review…"), icon: "mail-send-symbolic") { [weak self] in self?.model.sheet = .requestReview(branch: b) })
        }
        meta.text = String(localized: "Created by \(displayName(t.author, in: store)) · \(fullDate(t.created))") + "\n"
            + String(localized: "Updated \(relativeDate(t.updated))")
    }

    private func saveTitle() {
        let new = title.text.trimmingCharacters(in: .whitespaces)
        guard let t = model.cowork.task(taskID), !new.isEmpty, new != t.title else { return }
        Task { await model.cowork.updateTask(t.id) { $0.title = new } }
    }

    private func saveBody() {
        let new = body.text
        guard let t = model.cowork.task(taskID), new != t.body else { return }
        Task { await model.cowork.updateTask(t.id) { $0.body = new } }
    }
}

@MainActor
func isFocused(_ w: Widget) -> Bool {
    gtk_widget_has_focus(w.w) != 0 || (gtk_widget_get_focus_child(w.w) != nil)
}

/// Runs `fn` when keyboard focus leaves the widget (saves edits like macOS does on blur).
@MainActor
func onFocusLeave(_ w: Widget, _ fn: @escaping Action) {
    let c = gtk_event_controller_focus_new()!
    Signal.on(RP(c), "leave", fn)
    w.addController(OP(c))
}

// MARK: Review

@MainActor
final class ReviewPanel {
    let root = Box.v(0)
    unowned let page: RepoPage
    private var model: RepoModel { page.model }
    private let header = Label("", "heading")
    private let content = Box.v(10).margins(10, 10, 10, 10)
    private let info = Box.v(8)
    private let files = ListBox("boxed-list")
    private let note = Entry(placeholder: L("Add a note (optional)"))
    private let comments: CommentThread
    private var reviewID = ""
    private var signature = ""
    private var changes = BranchChanges()
    private var changesKey = ""

    init(page: RepoPage) {
        self.page = page
        comments = CommentThread(page: page)
        let h = Box.h(6)
        h.css("gc-panel-header")
        h.append(header.hexpand())
        let more = MenuButton(icon: "view-more-symbolic", "flat")
        more.content { [weak self] p in
            guard let self, let r = self.model.cowork.review(self.reviewID) else { return }
            Menus.fill(p, [
                MenuItem(r.status == .open ? L("Close Review") : L("Reopen Review")) { [weak self] in
                    guard let self else { return }
                    Task { await self.model.cowork.updateReview(r.id) { $0.status = r.status == .open ? .closed : .open } }
                },
                MenuItem(L("Copy Branch Name")) { External.copy(r.branch) },
                MenuItem(L("Copy Review ID")) { External.copy(r.id) },
            ])
        }
        h.append(more)
        root.append(h)
        content.append(info)
        content.append(files)
        content.append(comments.root)
        root.append(Scrolled(content).vexpand())
        root.track { [weak self] in self?.render() }
    }

    private func render() {
        guard case .review(let id)? = model.coworkSelection, let r = model.cowork.review(id) else { return }
        let store = model.cowork
        _ = store.version
        _ = model.historyVersion
        if id != reviewID { reviewID = id; signature = "" }
        comments.show(parent: r.commentParent)
        let key = "\(r.branch)|\(r.base)|\(model.refs.map(\.target).joined())"
        if key != changesKey {
            changesKey = key
            changes = BranchChanges()
            Task { [weak self] in
                guard let self else { return }
                let c = await self.model.branchChanges(branch: r.branch, base: r.base)
                guard self.changesKey == key else { return }
                self.changes = c
                self.signature = ""
                self.render()
            }
        }
        let sig = "\(r)\(changes.loaded)\(changes.files.count)\(String(describing: model.openDiff))"
        guard sig != signature else { return }
        signature = sig
        header.text = r.id

        info.removeAll()
        info.append(Label(r.title.isEmpty ? r.branch : r.title, "title-4").wrap().selectable())
        info.append(Label("\(r.branch) → \(r.base)", "gc-mono").ellipsize(PANGO_ELLIPSIZE_MIDDLE).tooltip(String(localized: "\(r.branch) into \(r.base)")))
        info.append(Label(String(localized: "Requested by \(displayName(r.requester, in: store)) · \(relativeDate(r.created))"), "dim-label", "caption"))
        if r.status == .closed { info.append(chip(L("Closed"), color: Theme.secondaryText)) }
        if !r.body.isEmpty { info.append(Label(r.body).wrap().selectable()) }
        if let task = r.taskID {
            info.append(Button(String(localized: "Open Task \(task)"), icon: "view-list-bullet-symbolic", "flat") { [weak self] in
                guard let self else { return }
                openCoworkTarget("tasks/\(task)", page: self.page)
            }.halign(GTK_ALIGN_START))
        }

        // Reviewers and verdicts
        info.append(Label(L("Reviewers"), "heading"))
        if r.reviewers.isEmpty { info.append(Label(L("Nobody asked yet"), "dim-label")) }
        for (email, verdict) in r.reviewers.sorted(by: { $0.key < $1.key }) {
            let row = Box.h(6)
            let name = displayName(email, in: store)
            row.append(avatar(name, email: email, size: 20))
            row.append(Label(name).hexpand().ellipsize())
            row.append(chip(verdictTitle(verdict), color: verdictColor(verdict)))
            row.onContextMenu { [weak self, weak row] x, y in
                guard let self, let row else { return }
                Menus.popup([MenuItem(L("Remove Reviewer"), destructive: true) {
                    Task { await self.model.cowork.updateReview(r.id) { $0.reviewers[email] = nil } }
                }], at: x, y, in: row)
            }
            info.append(row)
        }
        let add = MenuButton(L("Add"), icon: "list-add-symbolic", "flat")
        add.tooltip(L("Add reviewer"))
        add.content { [weak self] p in
            guard let self else { return }
            let candidates = store.people.filter { person in !r.reviewers.keys.contains { $0.lowercased() == person.id } && person.id != r.requester.lowercased() }
            Menus.fill(p, candidates.map { person in
                MenuItem(person.displayName) { Task { await self.model.cowork.updateReview(r.id) { $0.reviewers[person.email] = .requested } } }
            })
        }
        info.append(add.halign(GTK_ALIGN_START))

        // My verdict
        let iAmReviewer = r.reviewers.keys.contains { $0.lowercased() == store.me.id }
        if r.status == .open && (iAmReviewer || r.requester.lowercased() != store.me.id) {
            let verdictBox = Box.h(6)
            verdictBox.append(Button(L("Approve"), icon: "object-select-symbolic", "suggested-action") { [weak self] in self?.verdict(.approved, r) })
            verdictBox.append(Button(L("Request Changes"), icon: "dialog-warning-symbolic", "destructive-action") { [weak self] in self?.verdict(.changesRequested, r) })
            info.append(note)
            info.append(verdictBox)
            if let mine = r.reviewers.first(where: { $0.key.lowercased() == store.me.id })?.value, mine != .requested {
                info.append(Label(String(localized: "You: \(verdictTitle(mine).lowercased())"), "dim-label", "caption"))
            }
        }

        // Branch actions
        let branchActions = Box.h(6)
        if let ref = model.branch(named: r.branch) {
            if let wt = model.worktree(holding: r.branch), wt.path != model.root.path {
                branchActions.append(Button(L("Open Worktree"), "flat") { [weak self] in self?.page.openInNewTab(wt.path) })
            } else if !ref.isHead {
                branchActions.append(Button(L("Checkout"), "flat") { [weak self] in self?.page.run { await $0.checkout(ref) } })
            }
            branchActions.append(Button(L("Show in History"), "flat") { [weak self] in
                self?.page.setMode(.history)
                self?.model.reveal(ref.target)
            })
        }
        if model.remoteBranch(named: r.branch) == nil, model.localBranch(named: r.branch) != nil {
            branchActions.append(Button(L("Push Branch"), "flat") { [weak self] in
                self?.page.run { _ = await $0.push(branch: r.branch) }
            }.tooltip(String(localized: "\(r.branch) isn't on the remote yet. Push it so reviewers can fetch it.")))
        }
        if let links = model.links(for: nil), let url = links.newPullRequestURL(branch: r.branch, base: r.base) {
            branchActions.append(Button(String(localized: "Open \(L(links.pullRequestTerm)) on \(links.host)"), "flat") { External.browse(url) })
        }
        info.append(branchActions)

        // Changed files
        files.removeAll()
        if !changes.loaded {
            files.append(Label(L("Loading…"), "dim-label").margin(8), activatable: false)
        } else if let e = changes.error {
            files.append(Label(e, "dim-label").wrap().margin(8), activatable: false)
        } else if changes.files.isEmpty {
            files.append(Label(String(localized: "No changes between \(r.base) and \(r.branch)."), "dim-label").wrap().margin(8), activatable: false)
        } else if let detail = changes.detail {
            for f in changes.files.prefix(300) {
                files.append(fileRow(f), action: { [weak self] in self?.model.openDiff = .commit(detail, f) })
            }
            if changes.files.count > 300 {
                files.append(Label(String(localized: "and \(changes.files.count - 300) more files"), "dim-label").margin(8), activatable: false)
            }
        }
    }

    private func verdict(_ v: ReviewVerdict, _ r: ReviewRequest) {
        let text = note.text
        note.text = ""
        Task { await model.cowork.setVerdict(v, on: r, comment: text) }
    }
}

func verdictTitle(_ v: ReviewVerdict) -> String {
    switch v {
    case .requested: L("Waiting")
    case .approved: L("Approved")
    case .changesRequested: L("Changes requested")
    case .commented: L("Commented")
    }
}

@MainActor
func verdictColor(_ v: ReviewVerdict) -> RGBA {
    switch v {
    case .requested: Theme.secondaryText
    case .approved: Theme.green
    case .changesRequested: Theme.red
    case .commented: Theme.blue
    }
}
