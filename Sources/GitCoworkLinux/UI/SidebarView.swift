import CGtk
import Foundation
import GitCoworkCore

/// Local and remote branches, worktrees, tasks, reviews, stashes, tags and
/// team, with counts and right-click menus. Counterpart of SidebarView on macOS.
@MainActor
final class SidebarView {
    let root = Box.v(0)
    unowned let page: RepoPage
    private var model: RepoModel { page.model }
    private let filter = Entry(placeholder: L("Filter branches"), search: true)
    private let list = ListBox("navigation-sidebar")
    private let scroll: Scrolled
    private var signature = ""

    enum Section: String, CaseIterable {
        case local, remote, worktrees, tasks, reviews, stashes, tags, team
        var title: String {
            switch self {
            case .local: L("Local")
            case .remote: L("Remote")
            case .worktrees: L("Worktrees")
            case .tasks: L("Tasks")
            case .reviews: L("Reviews")
            case .stashes: L("Stashes")
            case .tags: L("Tags")
            case .team: L("Team")
            }
        }
        var icon: String {
            switch self {
            case .local: "computer-symbolic"
            case .remote: "folder-remote-symbolic"
            case .worktrees: "view-dual-symbolic"
            case .tasks: "view-list-bullet-symbolic"
            case .reviews: "mail-send-receive-symbolic"
            case .stashes: "document-save-symbolic"
            case .tags: "bookmark-new-symbolic"
            case .team: "system-users-symbolic"
            }
        }
        var openByDefault: Bool { ![.stashes, .tags, .team].contains(self) }
    }

    init(page: RepoPage) {
        self.page = page
        scroll = Scrolled(list)
        root.css("gc-sidebar")
        filter.margin(6)
        filter.onChanged { [weak self] in self?.render(force: true) }
        filter.tooltip(L("Filter (Ctrl+Alt+F)"))
        root.append(filter)
        scroll.vexpand()
        root.append(scroll)
        root.track { [weak self] in self?.render() }
    }

    func focusFilter() { filter.grabFocus() }

    // MARK: Expanded state

    private func isOpen(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: "sidebar.open." + key) as? Bool ?? def
    }
    private func toggle(_ key: String, default def: Bool) {
        UserDefaults.standard.set(!isOpen(key, default: def), forKey: "sidebar.open." + key)
        render(force: true)
    }

    // MARK: Rendering

    private func render(force: Bool = false) {
        let m = model
        // Read everything shown, so the tracker re-renders on changes.
        let refs = m.refs, worktrees = m.worktrees, info = m.worktreeInfo, stashes = m.stashes
        _ = m.worktreeInfoVersion
        let tasks = m.cowork.tasks, reviews = m.cowork.reviews, team = m.cowork.snapshot.team
        let me = m.cowork.me
        let selection = m.selection
        let query = filter.text.trimmingCharacters(in: .whitespaces).lowercased()

        var sig = query + "|" + refs.map { "\($0.fullName)\($0.target)\($0.ahead)\($0.behind)\($0.isHead)" }.joined()
        sig += "|" + worktrees.map { "\($0.path)\($0.branch ?? "")\(info[$0.path].map { "\($0.changes)\($0.ahead)\($0.behind)" } ?? "")" }.joined()
        sig += "|" + stashes.map(\.selector).joined() + "|\(m.cowork.version)|\(String(describing: selection))|\(m.root.path)"
        guard force || sig != signature else { return }
        signature = sig
        let scrollY = scroll.scrollY

        list.removeAll()
        let match: (String) -> Bool = { query.isEmpty || $0.lowercased().contains(query) }
        let selectedSHA: String? = { if case .commit(let s)? = selection { return s } else { return nil } }()

        // Local branches
        let locals = m.localBranches.filter { match($0.name) }
        section(.local, count: locals.count, query: query) {
            self.branchTree(SidebarTree.build(locals, prefix: "local", name: \.name), depth: 1, selectedSHA: selectedSHA)
        }
        // Remote branches, grouped by remote
        let remotes = m.remoteBranches.filter { !$0.name.hasSuffix("/HEAD") && match($0.name) }
        section(.remote, count: remotes.count, query: query) {
            for remote in m.remotes {
                let mine = remotes.filter { $0.remoteName == remote.name }
                guard !mine.isEmpty || query.isEmpty else { continue }
                let key = "remote." + remote.name
                let open = !query.isEmpty || self.isOpen(key, default: true)
                self.folderRow(remote.name, icon: "network-server-symbolic", open: open, depth: 1) { self.toggle(key, default: true) }
                if open {
                    self.branchTree(SidebarTree.build(mine, prefix: key, name: \.branchNameWithoutRemote), depth: 2, selectedSHA: selectedSHA)
                }
            }
        }
        // Worktrees
        let wts = worktrees.filter { match($0.displayName) || match($0.branch ?? "") }
        section(.worktrees, count: wts.count, query: query) {
            for wt in wts { self.worktreeRow(wt, info: info[wt.path]) }
        }
        // Tasks: open ones, mine first
        let open = tasks.filter { $0.status != .done && match($0.title + " " + $0.id) }
            .sorted { a, b in
                let am = a.assignee?.lowercased() == me.id, bm = b.assignee?.lowercased() == me.id
                if am != bm { return am }
                return a.updated > b.updated
            }
        section(.tasks, count: open.count, query: query) {
            for t in open.prefix(30) { self.taskRow(t) }
            self.linkRow(L("All Tasks…"), icon: "view-grid-symbolic") { self.page.setMode(.board) }
        }
        let openReviews = reviews.filter { $0.status == .open && match($0.title + " " + $0.branch) }
        section(.reviews, count: openReviews.count, query: query) {
            for r in openReviews.prefix(30) {
                let waiting = r.reviewers.contains { $0.key.lowercased() == me.id && $0.value == .requested }
                self.reviewRow(r, waiting: waiting)
            }
            self.linkRow(L("All Reviews…"), icon: "view-list-symbolic") { self.page.setMode(.reviews) }
        }
        let st = stashes.filter { match($0.message) }
        section(.stashes, count: st.count, query: query) {
            for s in st { self.stashRow(s) }
        }
        let tags = m.tags.filter { match($0.name) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        section(.tags, count: tags.count, query: query) {
            for t in tags { self.refRow(t, label: t.name, depth: 1, selected: selectedSHA == t.target) }
        }
        let people = team.isEmpty ? m.cowork.people : team
        section(.team, count: people.count, query: query) {
            for p in people where match(p.displayName + p.email) {
                let row = Box.h(8).margins(2, 4, 2, 16)
                row.append(avatar(p.displayName, email: p.email, size: 18))
                row.append(Label(p.displayName + (p.id == me.id ? L(" (me)") : "")).hexpand().ellipsize())
                if !p.handle.isEmpty { row.append(Label("@" + p.handle, "dim-label", "caption")) }
                self.list.append(row, activatable: false)
            }
            self.linkRow(L("Edit Team…"), icon: "document-edit-symbolic") { self.model.sheet = .team }
        }
        DispatchQueue.main.async { [scroll] in scroll.scrollY = scrollY }
    }

    private func section(_ s: Section, count: Int, query: String, _ content: () -> Void) {
        if !query.isEmpty && count == 0 { return }
        let open = !query.isEmpty || isOpen(s.rawValue, default: s.openByDefault)
        let row = Box.h(6).margins(6, 4, 2, 2)
        row.append(Image(open ? "pan-down-symbolic" : "pan-end-symbolic", size: 12))
        row.append(Label(s.title.uppercased(), "gc-section").hexpand())
        row.append(Label("\(count)", "gc-count"))
        list.append(row, action: { [weak self] in self?.toggle(s.rawValue, default: s.openByDefault) })
        if open { content() }
    }

    private func folderRow(_ name: String, icon: String, open: Bool, depth: Int, toggle: @escaping Action) {
        let row = Box.h(6).margins(1, 4, 1, Int32(8 + depth * 12))
        row.append(Image(open ? "pan-down-symbolic" : "pan-end-symbolic", size: 12))
        row.append(Image(icon, size: 14))
        row.append(Label(name).hexpand().ellipsize())
        list.append(row, action: toggle)
    }

    private func linkRow(_ title: String, icon: String, _ action: @escaping Action) {
        let row = Box.h(6).margins(1, 4, 1, 20)
        row.append(Image(icon, size: 14))
        row.append(Label(title, "dim-label").hexpand())
        list.append(row, action: action)
    }

    private func branchTree(_ nodes: [SidebarTree], depth: Int, selectedSHA: String?) {
        for node in nodes {
            if let ref = node.ref {
                refRow(ref, label: node.name, depth: depth, selected: selectedSHA == ref.target)
            } else {
                let key = "folder." + node.id
                // Branch folders (claude/…, feature/…) are open until closed.
                let open = !filter.text.isEmpty || isOpen(key, default: true)
                folderRow(node.name, icon: "folder-symbolic", open: open, depth: depth) { [weak self] in self?.toggle(key, default: true) }
                if open { branchTree(node.children, depth: depth + 1, selectedSHA: selectedSHA) }
            }
        }
    }

    private func refRow(_ ref: Ref, label: String, depth: Int, selected: Bool) {
        let row = Box.h(6).margins(1, 4, 1, Int32(8 + depth * 12))
        let icon: String
        switch ref.kind {
        case .localBranch: icon = ref.isHead ? "object-select-symbolic" : "media-playlist-shuffle-symbolic"
        case .remoteBranch: icon = "folder-remote-symbolic"
        case .tag: icon = "bookmark-new-symbolic"
        }
        row.append(Image(icon, size: 14))
        let name = Label(label).hexpand().ellipsize(PANGO_ELLIPSIZE_MIDDLE)
        if ref.isHead { name.css("heading") }
        row.append(name)
        if ref.kind == .localBranch {
            if let wt = model.worktree(holding: ref.name) {
                row.append(Image("view-dual-symbolic", size: 12).tooltip(String(localized: "Checked out in worktree \(wt.path)")))
            }
            if ref.upstreamGone {
                row.append(Label(L("gone"), "dim-label", "caption"))
            } else {
                if ref.ahead > 0 { row.append(Label("↑\(ref.ahead)", "caption")) }
                if ref.behind > 0 { row.append(Label("↓\(ref.behind)", "caption")) }
            }
        }
        row.tooltip(ref.name)
        row.onClick(button: 1) { [weak self] _, count, _, _ in
            guard let self, count == 2 else { return }
            self.doubleClick(ref)
        }
        list.append(row, selected: selected, action: { [weak self] in self?.model.reveal(ref.target) },
                    menu: { [weak self] x, y, w in self?.refMenu(ref, at: x, y, in: w) })
    }

    private func doubleClick(_ ref: Ref) {
        if ref.kind == .tag { return }
        let local = ref.kind == .remoteBranch ? ref.branchNameWithoutRemote : ref.name
        if let wt = model.worktree(holding: local) { page.openInNewTab(wt.path); return }
        if ref.isHead { return }
        page.run { await $0.checkout(ref) }
    }

    private func worktreeRow(_ wt: Worktree, info: WorktreeInfo?) {
        let current = realPath(wt.path) == model.root.path
        let row = Box.h(6).margins(2, 4, 2, 20)
        row.append(Image(current ? "object-select-symbolic" : "folder-symbolic", size: 14))
        let texts = Box.v(0).hexpand()
        let name = Label(wt.displayName).ellipsize()
        if current { name.css("heading") }
        texts.append(name)
        texts.append(Label(wt.branch ?? L("detached"), "dim-label", "caption").ellipsize())
        row.append(texts)
        if let info {
            if info.changes > 0 { row.append(Label("●\(info.changes)", "caption").tooltip(String(localized: "\(info.changes) uncommitted changes"))) }
            if info.ahead > 0 { row.append(Label("↑\(info.ahead)", "caption")) }
            if info.behind > 0 { row.append(Label("↓\(info.behind)", "caption")) }
        }
        row.tooltip(wt.path)
        list.append(row, action: { [weak self] in
            guard let self, !current else { return }
            self.page.openInNewTab(wt.path)
        }, menu: { [weak self] x, y, w in self?.worktreeMenu(wt, current: current, at: x, y, in: w) })
    }

    private func taskRow(_ t: CoworkTask) {
        let row = Box.h(6).margins(2, 4, 2, 20)
        row.append(Label(t.id, "gc-mono", "dim-label", "caption"))
        row.append(Label(t.title).hexpand().ellipsize())
        if let a = t.assignee, let p = model.cowork.person(a) { row.append(avatar(p.displayName, email: p.email, size: 16)) }
        let selected = model.coworkSelection == .task(t.id)
        list.append(row, selected: selected, action: { [weak self] in
            self?.page.setMode(.board)
            self?.model.coworkSelection = .task(t.id)
        }, menu: { [weak self] x, y, w in
            guard let self else { return }
            var items = [MenuItem(L("Open Task")) { self.page.setMode(.board); self.model.coworkSelection = .task(t.id) }]
            if let branch = t.branch, let ref = self.model.localBranch(named: branch), !ref.isHead {
                if let wt = self.model.worktree(holding: branch) {
                    items.append(MenuItem(String(localized: "Open Worktree for \(branch)")) { self.page.openInNewTab(wt.path) })
                } else {
                    items.append(MenuItem(String(localized: "Checkout \(branch)")) { self.page.run { await $0.checkout(ref) } })
                }
            }
            items += [.separator, MenuItem(L("Copy ID")) { External.copy(t.id) }]
            Menus.popup(items, at: x, y, in: w)
        })
    }

    private func reviewRow(_ r: ReviewRequest, waiting: Bool) {
        let row = Box.h(6).margins(2, 4, 2, 20)
        row.append(Image(waiting ? "mail-unread-symbolic" : "mail-send-receive-symbolic", size: 14))
        row.append(Label(r.title.isEmpty ? r.branch : r.title).hexpand().ellipsize())
        if waiting { row.append(Label(L("waiting"), "caption", "accent")) }
        list.append(row, selected: model.coworkSelection == .review(r.id), action: { [weak self] in
            self?.page.setMode(.reviews)
            self?.model.coworkSelection = .review(r.id)
        }, menu: { [weak self] x, y, w in
            guard let self else { return }
            var items = [MenuItem(L("Open Review")) { self.page.setMode(.reviews); self.model.coworkSelection = .review(r.id) }]
            if let task = r.taskID {
                items.append(MenuItem(String(localized: "Open Task \(task)")) { self.page.setMode(.board); self.model.coworkSelection = .task(task) })
            }
            items += [.separator, MenuItem(L("Copy Branch Name")) { External.copy(r.branch) }]
            Menus.popup(items, at: x, y, in: w)
        })
    }

    private func stashRow(_ s: Stash) {
        let row = Box.h(6).margins(2, 4, 2, 20)
        row.append(Label(s.selector, "gc-mono", "dim-label", "caption"))
        row.append(Label(s.message).hexpand().ellipsize())
        list.append(row, action: { [weak self] in self?.model.reveal(s.sha) }, menu: { [weak self] x, y, w in
            guard let self else { return }
            Menus.popup([
                MenuItem(L("Apply")) { self.page.run { await $0.applyStash(s) } },
                MenuItem(L("Pop")) { self.page.run { await $0.popStash(s) } },
                .separator,
                MenuItem(L("Delete…"), destructive: true) { self.model.dropStash(s) },
            ], at: x, y, in: w)
        })
    }

    // MARK: Menus

    private func refMenu(_ ref: Ref, at x: Double, _ y: Double, in w: Widget) {
        let m = model
        let current = m.currentBranch ?? "HEAD"
        var items: [MenuItem] = []
        switch ref.kind {
        case .localBranch:
            let other = m.worktree(holding: ref.name)
            if let wt = other {
                items += [MenuItem(L("Open Worktree in New Tab")) { [weak self] in self?.page.openInNewTab(wt.path) }, .separator]
            } else if !ref.isHead {
                items.append(MenuItem(L("Checkout")) { [weak self] in self?.page.run { await $0.checkout(ref) } })
            } else {
                items += [MenuItem(L("Pull")) { [weak self] in self?.page.run { await $0.pull() } },
                          MenuItem(L("Push")) { [weak self] in self?.page.run { await $0.push() } }, .separator]
            }
            if !ref.isHead {
                items += mergeRebase(ref.name, current: current) + [.separator]
            }
            items.append(MenuItem(String(localized: "New Branch from \(ref.name)…")) { m.sheet = .newBranch(from: ref.name, label: ref.name) })
            if !m.worktrees.contains(where: { $0.branch == ref.name }) {
                items.append(MenuItem(L("Create Worktree…")) { m.sheet = .addWorktree(base: ref.name) })
            }
            items.append(MenuItem(L("Rename…")) { m.sheet = .renameBranch(ref.name) })
            if other == nil && !ref.isHead {
                items.append(MenuItem(L("Delete…"), destructive: true) { m.deleteBranch(ref) })
            } else if other != nil {
                items.append(MenuItem(L("Delete… (checked out in a worktree)"), enabled: false) {})
            }
            items.append(.separator)
            items += coworkItems(branch: ref.name)
            items += hostLinks(branch: ref.name, remote: ref.upstream?.split(separator: "/").first.map(String.init))
            items.append(MenuItem(L("Copy Name")) { External.copy(ref.name) })
        case .remoteBranch:
            let local = ref.branchNameWithoutRemote
            if let wt = m.worktree(holding: local) {
                items.append(MenuItem(String(localized: "Open Worktree for \(local)")) { [weak self] in self?.page.openInNewTab(wt.path) })
            } else {
                items.append(MenuItem(L("Checkout as Local Branch")) { [weak self] in self?.page.run { await $0.checkout(ref) } })
            }
            items += mergeRebase(ref.name, current: current) + [.separator]
            items.append(MenuItem(L("Create Worktree…")) { m.sheet = .addWorktree(base: ref.name) })
            items.append(MenuItem(String(localized: "New Branch from \(ref.name)…")) { m.sheet = .newBranch(from: ref.name, label: ref.name) })
            items.append(.separator)
            items += coworkItems(branch: local)
            items += hostLinks(branch: local, remote: ref.remoteName)
            items.append(MenuItem(L("Copy Name")) { External.copy(ref.name) })
            items.append(.separator)
            items.append(MenuItem(String(localized: "Delete on \(ref.remoteName ?? "remote")…"), destructive: true) { m.deleteBranch(ref) })
        case .tag:
            items = [
                MenuItem(L("Checkout (detached)")) { [weak self] in self?.page.run { await $0.checkout(ref) } },
                MenuItem(L("Push Tag")) { [weak self] in self?.page.run { await $0.pushTag(ref.name) } },
                MenuItem(L("Copy Name")) { External.copy(ref.name) },
                .separator,
                MenuItem(L("Delete…"), destructive: true) { m.deleteTag(ref.name) },
            ]
        }
        Menus.popup(items, at: x, y, in: w)
    }

    private func mergeRebase(_ name: String, current: String) -> [MenuItem] {
        [MenuItem(String(localized: "Merge \(name) into \(current)")) { [weak self] in self?.page.run { await $0.merge(name) } },
         MenuItem(String(localized: "Rebase \(current) onto \(name)")) { [weak self] in self?.page.run { await $0.rebase(onto: name) } }]
    }

    private func coworkItems(branch: String) -> [MenuItem] {
        var items = [MenuItem(L("Request Review…")) { [weak self] in self?.model.sheet = .requestReview(branch: branch) }]
        for t in model.cowork.tasks where t.branch == branch {
            items.append(MenuItem(String(localized: "Open Task \(t.id)")) { [weak self] in
                self?.page.setMode(.board)
                self?.model.coworkSelection = .task(t.id)
            })
        }
        items.append(.separator)
        return items
    }

    private func hostLinks(branch: String, remote: String?) -> [MenuItem] {
        guard let links = model.links(for: remote) else { return [] }
        var items: [MenuItem] = []
        let base = model.baseBranch()?.name
        if branch != base, let url = links.newPullRequestURL(branch: branch, base: base) {
            items.append(MenuItem(String(localized: "Create \(L(links.pullRequestTerm)) on \(links.host)")) { External.browse(url) })
        }
        if let url = links.branchURL(branch) {
            items.append(MenuItem(String(localized: "Open Branch on \(links.host)")) { External.browse(url) })
        }
        return items
    }

    private func worktreeMenu(_ wt: Worktree, current: Bool, at x: Double, _ y: Double, in w: Widget) {
        var items: [MenuItem] = []
        if !current {
            items += [MenuItem(L("Open in New Tab")) { [weak self] in self?.page.openInNewTab(wt.path) }, .separator]
        }
        items += [
            MenuItem(L("Open in Terminal")) { External.openTerminal(wt.path) },
            MenuItem(L("Open in Editor")) { External.openEditor(wt.path) },
            MenuItem(L("Show in File Manager")) { External.reveal(wt.path) },
            MenuItem(L("Copy Path")) { External.copy(wt.path) },
        ]
        if let branch = wt.branch {
            let links = hostLinks(branch: branch, remote: nil)
            if !links.isEmpty { items += [.separator] + links }
        }
        if !wt.isMain {
            items += [.separator,
                      MenuItem(L("Prune Stale Worktrees")) { [weak self] in self?.page.run { await $0.pruneWorktrees() } },
                      MenuItem(L("Remove Worktree…"), destructive: true, enabled: !current) { [weak self] in self?.model.removeWorktree(wt) }]
        }
        Menus.popup(items, at: x, y, in: w)
    }
}

/// Branches grouped into folders by "/" ("feature/login" goes under "feature").
struct SidebarTree {
    let id: String
    let name: String
    let ref: Ref?
    var children: [SidebarTree] = []

    static func build(_ refs: [Ref], prefix: String, name: KeyPath<Ref, String>) -> [SidebarTree] {
        build(refs.map { ($0[keyPath: name].split(separator: "/").map(String.init), $0) }, path: prefix)
    }

    private static func build(_ items: [([String], Ref)], path: String) -> [SidebarTree] {
        var folders: [String: [([String], Ref)]] = [:]
        var leaves: [SidebarTree] = []
        for (parts, ref) in items {
            if parts.count <= 1 {
                leaves.append(SidebarTree(id: "ref:" + ref.fullName, name: parts.first ?? ref.name, ref: ref))
            } else {
                folders[parts[0], default: []].append((Array(parts.dropFirst()), ref))
            }
        }
        let folderNodes = folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
            SidebarTree(id: "\(path)/\(key)", name: key, ref: nil, children: build(folders[key]!, path: "\(path)/\(key)"))
        }
        return folderNodes + leaves.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
