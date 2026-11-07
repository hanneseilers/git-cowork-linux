import CGtk
import Foundation
import GitCoworkCore

/// One open worktree: toolbar, sidebar, history / board / reviews, inspector,
/// status bar and command log. Counterpart of RepoView on macOS.
@MainActor
final class RepoPage: TabContent {
    let model: RepoModel
    weak var window: AppWindow?
    let root: Widget

    private let body = Box.v(0)
    private let banner = Box.h(8, [])
    private let bannerLabel = Label("")
    private let center = Stack()
    private let mainPaned = Paned()
    private let contentPaned = Paned()
    private let commandLog: CommandLogView
    private let logRevealer = Revealer()

    private(set) var sidebar: SidebarView!
    private(set) var history: HistoryView!
    private(set) var inspector: InspectorView!
    private(set) var diff: DiffView!
    private(set) var board: BoardView!
    private(set) var reviews: ReviewsView!
    private var toolbar: RepoToolbar!
    private var statusBar: StatusBar!
    private var shownAlert: UUID?
    private var shownConfirmation: UUID?
    private var shownSheet: String?

    var title: String { model.isLoaded ? model.name : (model.root.path as NSString).lastPathComponent }
    var repoPath: String? { model.root.path }

    init(path: String, window: AppWindow) {
        self.window = window
        model = RepoModel(root: URL(fileURLWithPath: path))
        commandLog = CommandLogView(model: model)
        root = body
        build()
        OpenRepos.add(path)
        Task { [weak self] in
            guard let self else { return }
            await self.model.load()
            if self.model.loadError == nil {
                Prefs.addRecent(self.model.mainWorktreePath ?? self.model.root.path)
            }
            self.window?.updateTitle(of: self)
        }
    }

    func closed() {
        OpenRepos.remove(model.root.path)
        model.stopWatching()
    }

    private func build() {
        toolbar = RepoToolbar(page: self)
        statusBar = StatusBar(page: self)
        sidebar = SidebarView(page: self)
        history = HistoryView(page: self)
        inspector = InspectorView(page: self)
        diff = DiffView(page: self)
        board = BoardView(page: self)
        reviews = ReviewsView(page: self)

        body.append(toolbar.root)

        banner.css("gc-banner")
        banner.append(Image("dialog-warning-symbolic"))
        banner.append(bannerLabel.hexpand())
        banner.append(Button(L("Continue"), "suggested-action") { [weak self] in self?.run { await $0.continueOperation() } })
        let skip = Button(L("Skip")) { [weak self] in self?.run { await $0.skipRebaseCommit() } }
        banner.append(skip)
        banner.append(Button(L("Abort"), "destructive-action") { [weak self] in self?.run { await $0.abortOperation() } })
        banner.visible = false
        body.append(banner)

        center.add("history", history.root)
        center.add("board", board.root)
        center.add("reviews", reviews.root)
        center.add("diff", diff.root)
        center.hexpand().vexpand()

        contentPaned.setStart(center)
        contentPaned.setEnd(inspector.root)
        contentPaned.resizeEnd(false)
        contentPaned.position = 760
        mainPaned.setStart(sidebar.root)
        mainPaned.setEnd(contentPaned)
        mainPaned.resizeStart(false)
        mainPaned.position = 250
        mainPaned.vexpand()
        body.append(mainPaned)

        logRevealer.setChild(commandLog.root)
        body.append(logRevealer)
        body.append(statusBar.root)

        let errorPage = Widget(raw: RP(adw_status_page_new()))
        adw_status_page_set_icon_name(errorPage.op, "dialog-error-symbolic")
        adw_status_page_set_title(errorPage.op, L("Can't open this repository"))
        errorPage.visible = false
        errorPage.vexpand()
        body.append(errorPage)

        body.track { [weak self] in
            guard let self else { return }
            let m = self.model
            // Load error replaces everything.
            if let error = m.loadError {
                adw_status_page_set_description(errorPage.op, error)
                errorPage.visible = true
                self.mainPaned.visible = false
                return
            }
            // Middle: diff over the current mode.
            self.center.visibleName = m.openDiff != nil ? "diff" : m.centerMode.rawValue
            // Merge / rebase banner.
            if let op = m.operation {
                self.banner.visible = true
                let conflicts = m.status.conflicted.count
                self.bannerLabel.text = conflicts > 0
                    ? String(localized: "\(L(op.rawValue)) in progress — \(conflicts) conflicted files")
                    : String(localized: "\(L(op.rawValue)) in progress")
                skip.visible = op == .rebase
            } else {
                self.banner.visible = false
            }
            self.logRevealer.revealed = m.showCommandLog
            self.window?.updateTitle(of: self)
        }

        // Alerts, confirmations and sheets the shared model asks for.
        body.track { [weak self] in
            guard let self else { return }
            if let a = self.model.alert, a.id != self.shownAlert {
                self.shownAlert = a.id
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Dialogs.alert(L(a.title), a.message, parent: self.root)
                        if self.model.alert?.id == a.id { self.model.alert = nil }
                    }
                }
            }
            if let c = self.model.confirmation, c.id != self.shownConfirmation {
                self.shownConfirmation = c.id
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if self.model.confirmation?.id == c.id { self.model.confirmation = nil }
                        Dialogs.confirm(L(c.title), L(c.message), confirm: L(c.confirmTitle), destructive: c.destructive, parent: self.root) {
                            Task { await c.action() }
                        }
                    }
                }
            }
            if let s = self.model.sheet, s.id != self.shownSheet {
                self.shownSheet = s.id
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Sheets.present(s, page: self)
                        self.model.sheet = nil
                        self.shownSheet = nil
                    }
                }
            }
        }
    }

    // MARK: Actions used by shortcuts and buttons

    /// Runs a model action in a task.
    func run(_ fn: @escaping @MainActor (RepoModel) async -> Void) {
        let m = model
        Task { await fn(m) }
    }

    func setMode(_ mode: CenterMode) {
        model.openDiff = nil
        model.centerMode = mode
    }

    func showChanges() {
        setMode(.history)
        model.selection = .workingCopy
        model.revealToken += 1
    }

    func newBranch() {
        let start = model.currentBranch ?? model.headSHA ?? "HEAD"
        model.sheet = .newBranch(from: start, label: model.currentBranch ?? String(start.prefix(7)))
    }

    func newTask() {
        setMode(.board)
        model.sheet = .newTask(status: .todo)
    }

    func requestReview() {
        guard let b = model.currentBranch else {
            model.alert = AlertItem(title: L("No branch checked out"), message: L("Check out the branch you want reviewed."))
            return
        }
        model.sheet = .requestReview(branch: b)
    }

    func focusFilter() { setMode(.history); history.focusFilter() }
    func focusSidebarFilter() { sidebar.focusFilter() }
    func commitShortcut() { inspector.commitShortcut() }

    func moveSelectedTask(by step: Int) {
        guard model.centerMode == .board, case .task(let id)? = model.coworkSelection else { return }
        board.move(id, by: step)
    }

    /// Opens a path in a new tab (worktrees, task worktrees).
    func openInNewTab(_ path: String) { window?.open(path) }
}

/// Worktree paths currently open in a tab, so opening one again focuses it.
@MainActor
enum OpenRepos {
    private static var counts: [String: Int] = [:]
    static func isOpen(_ path: String) -> Bool { counts[realPath(path), default: 0] > 0 }
    static func add(_ path: String) { counts[realPath(path), default: 0] += 1 }
    static func remove(_ path: String) {
        let key = realPath(path)
        let n = counts[key, default: 0] - 1
        counts[key] = n > 0 ? n : nil
    }
}

// MARK: Toolbar

@MainActor
final class RepoToolbar {
    let root = Box.h(4)
    unowned let page: RepoPage
    private var model: RepoModel { page.model }

    init(page: RepoPage) {
        self.page = page
        root.css("gc-toolbar")

        let repoMenu = MenuButton(icon: "folder-symbolic", "flat")
        let branchMenu = MenuButton(icon: "media-playlist-shuffle-symbolic", "flat")
        root.append(repoMenu)
        root.append(branchMenu)
        repoMenu.content { [weak self] p in self?.fillRepoMenu(p) }
        branchMenu.content { [weak self] p in self?.fillBranchMenu(p) }
        repoMenu.tooltip(L("Repository and worktrees"))
        branchMenu.tooltip(L("Branch"))

        root.append(Separator(GTK_ORIENTATION_VERTICAL).margins(4, 4, 4, 4))
        let modes = Box.h(0)
        modes.css("linked")
        var modeButtons: [CenterMode: Widget] = [:]
        for (i, mode) in CenterMode.allCases.enumerated() {
            let b = Widget(raw: RP(gtk_toggle_button_new_with_label(mode.title)))
            b.tooltip("\(mode.title) (Ctrl+\(i + 1))")
            Signal.on(b.raw, "clicked") { [weak self] in self?.page.setMode(mode) }
            modes.append(b)
            modeButtons[mode] = b
        }
        root.append(modes)
        root.append(spacer())

        let fetch = Button(icon: "emblem-synchronizing-symbolic", "flat") { [weak self] in self?.page.run { await $0.fetch() } }
        fetch.tooltip(L("Fetch All (Ctrl+Shift+F)"))
        let pull = Button(L("Pull"), icon: "go-down-symbolic", "flat") { [weak self] in self?.page.run { await $0.pull() } }
        pull.tooltip(L("Pull (Ctrl+Shift+L)"))
        let pullMore = MenuButton(icon: "pan-down-symbolic", "flat")
        pullMore.content { [weak self] p in
            guard let self else { return }
            var items = [MenuItem(L("Fetch All"), icon: "emblem-synchronizing-symbolic") { self.page.run { await $0.fetch() } }, .separator]
            for mode in PullMode.allCases {
                items.append(MenuItem(mode.title) { self.page.run { await $0.pull(mode) } })
            }
            Menus.fill(p, items)
        }
        let push = Button(L("Push"), icon: "go-up-symbolic", "flat") { [weak self] in self?.page.run { await $0.push() } }
        push.tooltip(L("Push (Ctrl+Shift+P)"))
        let pushMore = MenuButton(icon: "pan-down-symbolic", "flat")
        pushMore.content { [weak self] p in
            guard let self else { return }
            Menus.fill(p, [
                MenuItem(L("Push")) { self.page.run { await $0.push() } },
                MenuItem(L("Force Push (with lease)…"), destructive: true) { self.model.confirmForcePush() },
            ])
        }
        let branch = Button(L("Branch"), icon: "list-add-symbolic", "flat") { [weak self] in self?.page.newBranch() }
        branch.tooltip(L("New Branch (Ctrl+Shift+B)"))
        let worktree = Button(L("Worktree"), icon: "folder-new-symbolic", "flat") { [weak self] in
            self?.model.sheet = .addWorktree(base: self?.model.currentBranch)
        }
        let stash = Button(L("Stash"), icon: "document-save-symbolic", "flat") { [weak self] in self?.model.sheet = .stash }
        stash.tooltip(L("Stash (Ctrl+Shift+S)"))
        let pop = Button(L("Pop"), icon: "document-revert-symbolic", "flat") { [weak self] in self?.page.run { await $0.popStash() } }
        pop.tooltip(L("Pop stash (Ctrl+Alt+Shift+S)"))
        let undo = Button(icon: "edit-undo-symbolic", "flat") { [weak self] in self?.page.run { await $0.undoLastAction() } }
        let terminal = Button(icon: "utilities-terminal-symbolic", "flat") { [weak self] in
            guard let self else { return }
            External.openTerminal(self.model.root.path)
        }
        terminal.tooltip(L("Open in Terminal (Ctrl+Alt+T)"))
        let editor = Button(icon: "text-editor-symbolic", "flat") { [weak self] in
            guard let self else { return }
            External.openEditor(self.model.root.path)
        }
        editor.tooltip(L("Open in Editor (Ctrl+Alt+E)"))
        let inbox = InboxButton(page: page)

        let pullGroup = Box.h(0, [pull, pullMore]); pullGroup.css("linked")
        let pushGroup = Box.h(0, [push, pushMore]); pushGroup.css("linked")
        for w in [fetch, pullGroup, pushGroup] as [Widget] { root.append(w) }
        root.append(Separator(GTK_ORIENTATION_VERTICAL).margins(4, 4, 4, 4))
        for w in [branch, worktree, stash, pop, undo] as [Widget] { root.append(w) }
        root.append(Separator(GTK_ORIENTATION_VERTICAL).margins(4, 4, 4, 4))
        for w in [terminal, editor, inbox.root] as [Widget] { root.append(w) }
        root.keep(inbox)

        root.track { [weak self] in
            guard let self else { return }
            let m = self.model
            let idle = m.busy == nil && m.isLoaded
            for w in [fetch, pullGroup, pushGroup, branch, worktree, stash, pop] as [Widget] { w.sensitive = idle }
            for (mode, b) in modeButtons {
                gtk_toggle_button_set_active(b.p(), gbool(m.centerMode == mode && m.openDiff == nil))
            }
            repoMenu.setLabel(m.name)
            branchMenu.setLabel(m.currentBranch ?? (m.headSHA.map { String($0.prefix(7)) } ?? L("No commits yet")))
            let ahead = m.status.ahead, behind = m.status.behind
            pull.setLabel(behind > 0 ? "\(L("Pull")) \(behind)" : L("Pull"))
            push.setLabel(ahead > 0 ? "\(L("Push")) \(ahead)" : L("Push"))
            pop.sensitive = idle && !m.stashes.isEmpty
            let undoTitle = idle ? m.undoTitle : nil
            undo.sensitive = undoTitle != nil
            undo.tooltip(undoTitle.map { "\($0) (Ctrl+Z)" } ?? L("Nothing to undo"))
        }
    }

    private func fillRepoMenu(_ p: Popover) {
        var items: [MenuItem] = [.header(L("Worktrees"))]
        for wt in model.worktrees {
            let info = model.worktreeInfo[wt.path]
            var title = wt.displayName + (wt.branch.map { "  ·  \($0)" } ?? "")
            if let info, info.changes > 0 { title += "  ●\(info.changes)" }
            let current = wt.path == model.root.path
            items.append(MenuItem(title, icon: current ? "object-select-symbolic" : "folder-symbolic") { [weak self] in
                guard let self, !current else { return }
                self.page.openInNewTab(wt.path)
            })
        }
        items.append(MenuItem(L("Add Worktree…"), icon: "list-add-symbolic") { [weak self] in
            self?.model.sheet = .addWorktree(base: self?.model.currentBranch)
        })
        let recents = Prefs.visibleRecents.filter { $0 != model.mainWorktreePath }.prefix(8)
        if !recents.isEmpty {
            items.append(.separator)
            items.append(.header(L("Recent")))
            for path in recents {
                items.append(MenuItem((path as NSString).lastPathComponent, icon: "folder-symbolic") { [weak self] in self?.page.openInNewTab(path) })
            }
        }
        items.append(.separator)
        items.append(MenuItem(L("Show in File Manager"), icon: "system-file-manager-symbolic") { [weak self] in
            guard let self else { return }
            External.reveal(self.model.root.path)
        })
        items.append(MenuItem(L("Edit Team…"), icon: "system-users-symbolic") { [weak self] in self?.model.sheet = .team })
        items.append(MenuItem(L("Sync Tasks Now"), icon: "emblem-synchronizing-symbolic") { [weak self] in self?.page.run { await $0.syncCowork() } })
        Menus.fill(p, items)
    }

    private func fillBranchMenu(_ p: Popover) {
        var items: [MenuItem] = [MenuItem(L("New Branch…"), icon: "list-add-symbolic") { [weak self] in self?.page.newBranch() }, .separator]
        items.append(.header(L("Local")))
        for ref in model.localBranches.prefix(40) {
            let wt = model.worktree(holding: ref.name)
            let title = ref.name + (wt != nil ? "  — " + String(localized: "in \(wt!.displayName)") : "")
            items.append(MenuItem(title, icon: ref.isHead ? "object-select-symbolic" : nil, enabled: !ref.isHead) { [weak self] in
                guard let self else { return }
                if let wt { self.page.openInNewTab(wt.path) } else { self.page.run { await $0.checkout(ref) } }
            })
        }
        Menus.fill(p, items)
    }
}

// MARK: Status bar

@MainActor
final class StatusBar {
    let root = Box.h(10)
    unowned let page: RepoPage

    init(page: RepoPage) {
        self.page = page
        root.css("gc-statusbar")
        let spinner = Widget(raw: RP(gtk_spinner_new()))
        let busy = Label("")
        let cowork = Button(nil, "flat")
        let coworkLabel = Label("", "caption")
        cowork.setChild(coworkLabel)
        cowork.onClicked { [weak page] in page?.run { await $0.syncCowork() } }
        let paused = Button(L("Auto-fetch paused"), icon: "dialog-warning-symbolic", "flat") { [weak page] in
            page?.run { await $0.fetch() }
        }
        let upstream = Label("", "dim-label", "caption")
        let update = UpdateBadge()
        let log = Button(icon: "utilities-terminal-symbolic", "flat") { [weak page] in page?.model.showCommandLog.toggle() }
        log.tooltip(L("Show Command Log (Ctrl+J)"))

        root.append(spinner)
        root.append(busy)
        root.append(cowork)
        root.append(paused)
        root.append(spacer())
        root.append(upstream)
        root.append(update.root)
        root.append(log)
        root.keep(update)

        root.track { [weak self] in
            guard let self else { return }
            let m = self.page.model
            if let b = m.busy {
                spinner.visible = true
                gtk_spinner_start(OP(spinner.raw))
                busy.text = "\(L(b))…"
            } else {
                gtk_spinner_stop(OP(spinner.raw))
                spinner.visible = false
                busy.text = m.isLoaded ? "" : L("Loading…")
            }
            let c = m.cowork
            if c.syncing {
                coworkLabel.text = L("Syncing tasks…")
            } else if let e = c.syncError {
                coworkLabel.text = L("Task sync failed")
                cowork.tooltip(e)
            } else if let last = c.lastSync {
                coworkLabel.text = String(localized: "Tasks synced \(relativeDate(last))")
                cowork.tooltip(L("Sync now"))
            } else {
                coworkLabel.text = c.remote == nil ? L("Tasks not synced") : ""
            }
            paused.visible = m.autoFetchPaused != nil
            paused.tooltip(m.autoFetchPaused)
            if let up = m.status.upstream {
                upstream.text = String(localized: "\(m.status.ahead) ahead, \(m.status.behind) behind \(up)")
            } else {
                upstream.text = m.currentBranch == nil ? "" : L("No upstream")
            }
        }
    }
}

// MARK: Command log

@MainActor
final class CommandLogView {
    let root = Box.v(0)
    private let list = ListBox()
    private var shownCount = -1

    init(model: RepoModel) {
        let header = Box.h(6)
        header.css("gc-panel-header")
        header.append(Label(L("Command Log"), "heading").hexpand())
        header.append(Button(L("Clear"), "flat") { CommandLog.shared.clear() })
        header.append(Button(icon: "window-close-symbolic", "flat") { [weak model] in model?.showCommandLog = false })
        root.append(header)
        let scroll = Scrolled(list, hscroll: true)
        scroll.size(-1, 180)
        root.append(scroll)
        list.css("gc-log")

        root.track { [weak self] in
            guard let self else { return }
            let entries = CommandLog.shared.entries
            guard entries.count != self.shownCount || entries.isEmpty else { return }
            self.shownCount = entries.count
            self.list.removeAll()
            for e in entries.suffix(200) {
                let row = Box.v(2).margins(3, 8, 3, 8)
                let line = Box.h(8)
                line.append(Label(e.succeeded ? "✓" : "✗", e.succeeded ? "gc-ok" : "gc-fail"))
                line.append(Label("$ " + e.commandLine).selectable().hexpand().ellipsize(PANGO_ELLIPSIZE_MIDDLE))
                line.append(Label(String(format: "%.1fs", e.duration), "dim-label"))
                row.append(line)
                if !e.output.isEmpty {
                    row.append(Label(e.output, "dim-label").selectable().wrap().margins(0, 0, 0, 20))
                }
                self.list.append(row)
            }
            DispatchQueue.main.async { scroll.scrollY = 1e9 }
        }
    }
}
