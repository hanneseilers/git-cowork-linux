import CGtk
import Foundation
import GitCoworkCore

/// What a tab shows: the welcome screen or a repository.
@MainActor
protocol TabContent: AnyObject {
    var root: Widget { get }
    var title: String { get }
    var repoPath: String? { get }
    func closed()
}

/// One window with tabs (AdwTabView). Every repo or worktree is a tab.
@MainActor
final class AppWindow {
    unowned let app: App
    let root: Widget
    private let tabView: OpaquePointer
    private let tabBar: Widget
    private let toastOverlay: Widget
    private let windowTitle: Widget
    private var contents: [RawPtr: TabContent] = [:]
    private var titleTracker: Tracker?
    private(set) var isActive = false

    var gtkWindow: UnsafeMutablePointer<GtkWindow> { root.p(GtkWindow.self) }

    init(app: App) {
        self.app = app
        root = Widget(raw: RP(adw_application_window_new(RP(app.gapp).assumingMemoryBound(to: GtkApplication.self))))
        gtk_window_set_default_size(root.p(GtkWindow.self), 1360, 860)
        gtk_window_set_title(root.p(GtkWindow.self), "git-cowork")
        gtk_window_set_icon_name(root.p(GtkWindow.self), App.id)

        tabView = OP(adw_tab_view_new())
        let tabViewWidget = Widget(raw: RP(tabView))
        tabBar = Widget(raw: RP(adw_tab_bar_new()))
        adw_tab_bar_set_view(OP(tabBar.raw), tabView)
        adw_tab_bar_set_autohide(OP(tabBar.raw), 0)

        toastOverlay = Widget(raw: RP(adw_toast_overlay_new()))
        adw_toast_overlay_set_child(toastOverlay.op, tabViewWidget.w)

        windowTitle = Widget(raw: RP(adw_window_title_new("git-cowork", "")))

        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(OP(header), windowTitle.w)

        let openMenu = MenuButton(L("Open"), icon: "folder-open-symbolic")
        openMenu.tooltip(L("Open or clone a repository (Ctrl+O, Ctrl+Shift+O)"))
        openMenu.content { [weak self] popover in
            guard let self else { return }
            var items: [MenuItem] = [
                MenuItem(L("Open Repository…"), icon: "folder-open-symbolic") { [weak self] in self?.chooseRepository() },
                MenuItem(L("Clone Repository…"), icon: "folder-download-symbolic") { [weak self] in self?.showClone() },
                MenuItem(L("New Tab"), icon: "tab-new-symbolic") { [weak self] in self?.newTab() },
            ]
            let recents = Prefs.visibleRecents.prefix(10)
            if !recents.isEmpty {
                items.append(.separator)
                items.append(.header(L("Recent")))
                for path in recents {
                    items.append(MenuItem((path as NSString).lastPathComponent, icon: "folder-symbolic") { [weak self] in self?.open(path) })
                }
            }
            Menus.fill(popover, items)
        }
        adw_header_bar_pack_start(OP(header), openMenu.w)
        root.keep(openMenu)

        let newTabButton = Button(icon: "tab-new-symbolic", "flat") { [weak self] in self?.newTab() }
        newTabButton.tooltip(L("New Tab (Ctrl+T)"))
        adw_header_bar_pack_start(OP(header), newTabButton.w)
        root.keep(newTabButton)

        let mainMenu = MenuButton(icon: "open-menu-symbolic")
        mainMenu.tooltip(L("Main Menu"))
        mainMenu.content { [weak self] popover in
            Menus.fill(popover, [
                MenuItem(L("New Window")) { App.shared.newWindow() },
                MenuItem(L("Settings…")) { SettingsDialog.present(parent: self?.root) },
                MenuItem(L("Keyboard Shortcuts")) { self?.showShortcuts() },
                MenuItem(L("Check for Updates…")) { Updater.shared.checkFromMenu() },
                MenuItem(L("About git-cowork")) { App.shared.showAbout() },
                .separator,
                MenuItem(L("Quit")) { App.shared.quit() },
            ])
        }
        adw_header_bar_pack_end(OP(header), mainMenu.w)
        root.keep(mainMenu)

        let toolbarView = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(OP(toolbarView), header)
        adw_toolbar_view_add_top_bar(OP(toolbarView), tabBar.w)
        adw_toolbar_view_set_content(OP(toolbarView), toastOverlay.w)
        adw_application_window_set_content(root.p(), toolbarView)

        root.keep(tabViewWidget)
        connectSignals()
        installShortcuts()
        root.onDropFiles { [weak self] paths in
            guard let self, let first = paths.first else { return false }
            self.open(first)
            return true
        }
        newTab()
    }

    private func connectSignals() {
        Signal.onPtrBool(RP(tabView), "close-page") { [weak self] page in
            guard let self, let page else { return false }
            if let content = self.contents.removeValue(forKey: page) { content.closed() }
            adw_tab_view_close_page_finish(self.tabView, OP(page), 1)
            if adw_tab_view_get_n_pages(self.tabView) == 0 {
                DispatchQueue.main.async { MainActor.assumeIsolated { gtk_window_close(self.gtkWindow) } }
            }
            return true   // GDK_EVENT_STOP: we finished it ourselves
        }
        Signal.onPtr(RP(tabView), "notify::selected-page") { [weak self] _ in self?.selectedChanged() }
        Signal.onPtr(root.raw, "notify::is-active") { [weak self] _ in
            guard let self else { return }
            self.isActive = gtk_window_is_active(self.gtkWindow) != 0
            App.shared.updateActive()
        }
        Signal.onBool(root.raw, "close-request") { [weak self] in
            guard let self else { return false }
            self.closeAll()
            App.shared.windowClosed(self)
            return false
        }
    }

    func present() { gtk_window_present(gtkWindow) }

    /// Stops every tab's file watching and timers.
    func closeAll() {
        for (_, c) in contents { c.closed() }
        contents.removeAll()
    }

    // MARK: Tabs

    var selectedContent: TabContent? {
        guard let page = adw_tab_view_get_selected_page(tabView) else { return nil }
        return contents[RP(page)]
    }

    var selectedRepo: RepoPage? { selectedContent as? RepoPage }

    @discardableResult
    private func addTab(_ content: TabContent, select: Bool = true) -> OpaquePointer {
        let page = adw_tab_view_append(tabView, content.root.w)!
        contents[RP(page)] = content
        adw_tab_page_set_title(page, content.title)
        if select { adw_tab_view_set_selected_page(tabView, page) }
        return page
    }

    func newTab() {
        let welcome = WelcomePage(window: self)
        addTab(welcome)
    }

    func closeTab() {
        guard let page = adw_tab_view_get_selected_page(tabView) else { return }
        adw_tab_view_close_page(tabView, page)
    }

    func updateTitle(of content: TabContent) {
        for (page, c) in contents where c === content {
            adw_tab_page_set_title(OP(page), content.title)
            if let repo = content as? RepoPage { adw_tab_page_set_loading(OP(page), gbool(repo.model.busy != nil)) }
        }
        if selectedContent === content { selectedChanged() }
    }

    private func selectedChanged() {
        let content = selectedContent
        let title = content?.title ?? "git-cowork"
        adw_window_title_set_title(OP(windowTitle.raw), title)
        var subtitle = ""
        if let repo = content as? RepoPage {
            subtitle = repo.model.currentBranch ?? (repo.model.headSHA.map { L("detached at") + " " + String($0.prefix(7)) } ?? "")
        }
        adw_window_title_set_subtitle(OP(windowTitle.raw), subtitle)
        gtk_window_set_title(gtkWindow, content.map { "\($0.title) — git-cowork" } ?? "git-cowork")
    }

    /// Opens a folder: here if the current tab is empty, else in a new tab.
    /// A worktree that's already open in a tab of this window is brought to the front.
    func open(_ chosen: String) {
        Task {
            guard let resolved = await RepoLocator.resolve(chosen) else {
                Dialogs.alert(L("Not a git repository"), chosen, parent: root)
                return
            }
            let path = realPath(resolved)
            for (page, content) in contents where content.repoPath.map(realPath) == path {
                adw_tab_view_set_selected_page(tabView, OP(page))
                return
            }
            let repo = RepoPage(path: path, window: self)
            if let page = adw_tab_view_get_selected_page(tabView), contents[RP(page)] is WelcomePage {
                let old = contents.removeValue(forKey: RP(page))
                let newPage = addTab(repo)
                adw_tab_view_close_page(tabView, page)
                old?.closed()
                adw_tab_view_set_selected_page(tabView, newPage)
            } else {
                addTab(repo)
            }
        }
    }

    /// Switches the current tab to another worktree (or focuses its tab).
    func openHere(_ path: String, from page: RepoPage) {
        open(path)
    }

    func chooseRepository() {
        Dialogs.chooseFolder(title: L("Open Repository"), parent: root) { [weak self] path in self?.open(path) }
    }

    func showClone() {
        CloneDialog.present(parent: root) { [weak self] path in self?.open(path) }
    }

    func toast(_ text: String) { Dialogs.toast(text, in: toastOverlay) }

    // MARK: Keyboard shortcuts

    private func installShortcuts() {
        let controller = gtk_shortcut_controller_new()!
        gtk_shortcut_controller_set_scope(OP(controller), GTK_SHORTCUT_SCOPE_GLOBAL)
        func add(_ trigger: String, _ fn: @escaping @MainActor () -> Bool) {
            let action = gtk_callback_action_new({ _, _, data in
                guard let data else { return 0 }
                let fn = Unmanaged<ClosureBox>.fromOpaque(data).takeUnretainedValue().fn as! @MainActor () -> Bool
                return MainActor.assumeIsolated { gbool(fn()) }
            }, Unmanaged.passRetained(ClosureBox(fn)).toOpaque(), { data in
                if let data { Unmanaged<ClosureBox>.fromOpaque(data).release() }
            })
            let shortcut = gtk_shortcut_new(gtk_shortcut_trigger_parse_string(trigger), action)
            gtk_shortcut_controller_add_shortcut(OP(controller), shortcut)
        }
        func repo(_ fn: @escaping @MainActor (RepoPage) -> Void) -> @MainActor () -> Bool {
            { [weak self] in
                guard let r = self?.selectedRepo else { return false }
                fn(r)
                return true
            }
        }
        add("<Control>o") { [weak self] in self?.chooseRepository(); return true }
        add("<Control><Shift>o") { [weak self] in self?.showClone(); return true }
        add("<Control>t") { [weak self] in self?.newTab(); return true }
        add("<Control>w") { [weak self] in self?.closeTab(); return true }
        add("<Control>n") { App.shared.newWindow(); return true }
        add("<Control>q") { App.shared.quit(); return true }
        add("<Control>comma") { [weak self] in SettingsDialog.present(parent: self?.root); return true }
        add("<Control>question") { [weak self] in self?.showShortcuts(); return true }
        add("<Control>1", repo { $0.setMode(.history) })
        add("<Control>2", repo { $0.setMode(.board) })
        add("<Control>3", repo { $0.setMode(.reviews) })
        add("<Control>r", repo { r in Task { await r.model.refresh() } })
        add("<Control><Shift>f", repo { r in r.run { await $0.fetch() } })
        add("<Control><Shift>l", repo { r in r.run { await $0.pull() } })
        add("<Control><Shift>p", repo { r in r.run { await $0.push() } })
        add("<Control><Shift>b", repo { $0.newBranch() })
        add("<Control><Shift>s", repo { $0.model.sheet = .stash })
        add("<Control><Alt><Shift>s", repo { r in r.run { await $0.popStash() } })
        add("<Control>0", repo { $0.showChanges() })
        add("<Control>j", repo { $0.model.showCommandLog.toggle() })
        add("<Control><Alt>t", repo { External.openTerminal($0.model.root.path) })
        add("<Control><Alt>e", repo { External.openEditor($0.model.root.path) })
        add("<Control>f", repo { $0.focusFilter() })
        add("<Control><Alt>f", repo { $0.focusSidebarFilter() })
        add("<Control><Shift>t", repo { $0.newTask() })
        add("<Control><Shift>r", repo { $0.requestReview() })
        add("<Control>z") { [weak self] in
            // Text fields handle Ctrl+Z themselves first; this is the git undo.
            guard let r = self?.selectedRepo, r.model.busy == nil, r.model.undoTitle != nil else { return false }
            Task { await r.model.undoLastAction() }
            return true
        }
        add("Escape", repo { r in
            if r.model.openDiff != nil { r.model.openDiff = nil }
        })
        add("<Control>Return", repo { $0.commitShortcut() })
        add("<Control><Alt>Left", repo { $0.moveSelectedTask(by: -1) })
        add("<Control><Alt>Right", repo { $0.moveSelectedTask(by: 1) })
        root.addController(OP(controller))
    }

    func showShortcuts() {
        let rows: [(String, String)] = [
            ("Ctrl+O / Ctrl+Shift+O", L("Open / clone repository")),
            ("Ctrl+T / Ctrl+W", L("New tab / close tab")),
            ("Ctrl+1 / 2 / 3", L("History / Board / Reviews")),
            ("Ctrl+Shift+T", L("New task")),
            ("Ctrl+Shift+R", L("Request review of the current branch")),
            ("Ctrl+F / Ctrl+Alt+F", L("Filter commits / filter branches")),
            ("Ctrl+R", L("Refresh")),
            ("Ctrl+Shift+F", L("Fetch all")),
            ("Ctrl+Shift+L / Ctrl+Shift+P", L("Pull / push")),
            ("Ctrl+Shift+B", L("New branch")),
            ("Ctrl+Shift+S / Ctrl+Alt+Shift+S", L("Stash / pop")),
            ("Ctrl+0", L("Uncommitted changes")),
            ("Ctrl+Enter", L("Commit")),
            ("Esc", L("Close the diff")),
            ("Ctrl+Alt+T / Ctrl+Alt+E", L("Open in terminal / editor")),
            ("Ctrl+Z", L("Undo the last git action")),
            ("Ctrl+Alt+← / →", L("Move the selected task to the previous / next column")),
            ("Ctrl+J", L("Command log")),
            ("Ctrl+,", L("Settings")),
        ]
        let grid = Box.v(4)
        for (keys, what) in rows {
            let row = Box.h(12)
            row.append(Label(keys, "gc-mono").size(230, -1))
            row.append(Label(what).hexpand())
            grid.append(row)
        }
        let d = AlertDialog(L("Keyboard Shortcuts"), "")
        d.setExtra(grid)
        d.addResponse("ok", L("OK"))
        d.present(root) { _ in }
    }
}

/// The empty tab: open, clone, recent repositories.
@MainActor
final class WelcomePage: TabContent {
    let root: Widget
    weak var window: AppWindow?
    var title: String { L("New Tab") }
    var repoPath: String? { nil }

    init(window: AppWindow) {
        self.window = window
        let status = Widget(raw: RP(adw_status_page_new()))
        adw_status_page_set_icon_name(status.op, App.id)
        adw_status_page_set_title(status.op, "git-cowork")
        adw_status_page_set_description(status.op, L("Branches, history and worktrees. Plain git underneath."))

        let content = Box.v(18)
        content.halign(GTK_ALIGN_CENTER)
        let buttons = Box.h(12)
        buttons.halign(GTK_ALIGN_CENTER)
        buttons.append(Button(L("Open Repository…"), icon: "folder-open-symbolic", "pill", "suggested-action") { [weak window] in window?.chooseRepository() })
        buttons.append(Button(L("Clone Repository…"), icon: "folder-download-symbolic", "pill") { [weak window] in window?.showClone() })
        content.append(buttons)

        let recents = Prefs.visibleRecents
        let list = ListBox("boxed-list")
        list.size(460, -1)
        if recents.isEmpty {
            content.append(Label(L("Repositories you open show up here"), "dim-label").halign(GTK_ALIGN_CENTER))
        } else {
            content.append(Label(L("Recent"), "heading"))
            for path in recents.prefix(12) {
                let row = Box.h(10).margins(6, 8, 6, 8)
                row.append(Image("folder-symbolic"))
                let texts = Box.v(0).hexpand()
                texts.append(Label((path as NSString).lastPathComponent).ellipsize())
                texts.append(Label(tildePath(path), "dim-label", "caption").ellipsize(PANGO_ELLIPSIZE_MIDDLE))
                row.append(texts)
                list.append(row, action: { [weak window] in window?.open(path) }, menu: { x, y, w in
                    Menus.popup([
                        MenuItem(L("Open")) { [weak window] in window?.open(path) },
                        MenuItem(L("Show in File Manager")) { External.reveal(path) },
                        MenuItem(L("Remove from Recents")) { Prefs.recentRepos.removeAll { $0 == path } },
                    ], at: x, y, in: w)
                })
            }
            content.append(list)
        }
        content.append(Label(L("Tip: drop a folder anywhere in this window"), "dim-label", "caption").halign(GTK_ALIGN_CENTER))
        adw_status_page_set_child(status.op, content.w)
        status.keep(content)
        root = Scrolled(status)
        root.keep(status)
    }

    func closed() {}
}

/// "/home/a/src/x" -> "~/src/x".
func tildePath(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
