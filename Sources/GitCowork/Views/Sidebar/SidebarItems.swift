import GitCoworkCore
import SwiftUI

/// Top-level groups of the sidebar, in display order.
enum SidebarSection: String, CaseIterable {
    case local, remote, worktrees, tasks, reviews, stashes, tags, team

    var title: String {
        switch self {
        case .local: "Local"
        case .remote: "Remote"
        case .worktrees: "Worktrees"
        case .tasks: "Tasks"
        case .reviews: "Reviews"
        case .stashes: "Stashes"
        case .tags: "Tags"
        case .team: "Team"
        }
    }

    var symbol: String {
        switch self {
        case .local: "laptopcomputer"
        case .remote: "cloud"
        case .worktrees: "square.stack.3d.up"
        case .tasks: "checklist"
        case .reviews: "checkmark.bubble"
        case .stashes: "tray"
        case .tags: "tag"
        case .team: "person.2"
        }
    }

    /// Open state when the user never toggled the section.
    var openByDefault: Bool {
        switch self {
        case .local, .remote, .worktrees, .tasks, .reviews: true
        case .stashes, .tags, .team: false
        }
    }
}

/// Non-selectable rows that do something when clicked ("All tasks…").
enum SidebarLink: String {
    case board, reviews, team

    var title: String {
        switch self {
        case .board: "All Tasks…"
        case .reviews: "All Reviews…"
        case .team: "Edit Team…"
        }
    }

    var symbol: String {
        switch self {
        case .board: "rectangle.split.3x1"
        case .reviews: "list.bullet"
        case .team: "pencil"
        }
    }
}

/// One row of the flattened sidebar list. Selectable rows use the ids that
/// SidebarMenu understands ("ref:…", "wt:…", "stash:…", "task:…", "review:…").
struct SidebarItem: Identifiable, Equatable {
    enum Kind: Equatable {
        /// `expanded` is nil when the header can't collapse (filtered results).
        case header(SidebarSection, count: Int, expanded: Bool?, highlight: Bool)
        case folder(name: String, expanded: Bool)
        case remote(name: String, expanded: Bool)
        case branch(Ref, label: String)
        case worktree(Worktree)
        case stash(Stash)
        case task(CoworkTask)
        /// `waiting`: I'm a reviewer and haven't answered yet.
        case review(ReviewRequest, waiting: Bool)
        case person(TeamMember, isMe: Bool)
        case link(SidebarLink)
        case note(String)
    }

    let id: String
    let kind: Kind
    var depth = 0

    var isSelectable: Bool {
        switch kind {
        case .branch, .worktree, .stash, .task, .review: true
        case .header, .folder, .remote, .person, .link, .note: false
        }
    }
}

/// Branches grouped into folders by "/" ("feature/login" goes under "feature").
struct SidebarNode {
    let id: String
    let name: String
    let ref: Ref?
    var children: [SidebarNode] = []

    static func tree(_ refs: [Ref], idPrefix: String, name: KeyPath<Ref, String> = \.name) -> [SidebarNode] {
        build(refs.map { ($0[keyPath: name].split(separator: "/").map(String.init), $0) }, path: idPrefix)
    }

    private static func build(_ items: [([String], Ref)], path: String) -> [SidebarNode] {
        var folders: [String: [([String], Ref)]] = [:]
        var leaves: [SidebarNode] = []
        for (parts, ref) in items {
            if parts.count <= 1 {
                leaves.append(SidebarNode(id: "ref:" + ref.fullName, name: parts.first ?? ref.name, ref: ref))
            } else {
                folders[parts[0], default: []].append((Array(parts.dropFirst()), ref))
            }
        }
        let folderNodes = folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
            SidebarNode(id: "folder:\(path)/\(key)", name: key, ref: nil, children: build(folders[key]!, path: "\(path)/\(key)"))
        }
        let sortedLeaves = leaves.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return folderNodes + sortedLeaves
    }

    /// Ids of every folder in the tree (for pruning stale collapse state).
    static func folderIDs(_ nodes: [SidebarNode], into set: inout Set<String>) {
        for node in nodes where node.ref == nil {
            set.insert(node.id)
            folderIDs(node.children, into: &set)
        }
    }
}

/// The cowork data the sidebar shows, worked out once per build.
@MainActor
struct SidebarCowork {
    let me: TeamMember
    /// Assigned to me and not done: in progress first, then review, to do, backlog.
    let myTasks: [CoworkTask]
    /// Open reviews where I'm asked and haven't answered.
    let waiting: [ReviewRequest]
    /// My own open requests (minus any already in `waiting`).
    let requested: [ReviewRequest]
    let people: [TeamMember]

    init(_ store: CoworkStore) {
        let me = store.me
        let email = me.email.lowercased()
        self.me = me
        guard !email.isEmpty else {
            myTasks = []; waiting = []; requested = []; people = store.people
            return
        }
        let order: [TaskStatus: Int] = [.doing: 0, .review: 1, .todo: 2, .backlog: 3]
        myTasks = store.tasks
            .filter { $0.assignee?.lowercased() == email && $0.status != .done }
            .sorted { a, b in
                let oa = order[a.status] ?? 9, ob = order[b.status] ?? 9
                return oa != ob ? oa < ob : a.updated > b.updated
            }
        let open = store.reviews.filter { $0.status == .open }.sorted { $0.updated > $1.updated }
        let waiting = open.filter { r in r.reviewers.contains { $0.key.lowercased() == email && $0.value == .requested } }
        let waitingIDs = Set(waiting.map(\.id))
        self.waiting = waiting
        requested = open.filter { $0.requester.lowercased() == email && !waitingIDs.contains($0.id) }
        people = store.people
    }
}

/// Turns the repo state into the flat row list the sidebar shows.
@MainActor
struct SidebarBuilder {
    let model: RepoModel
    /// Folder and remote ids the user collapsed. Everything else is open.
    let collapsed: Set<String>
    let openSections: Set<SidebarSection>
    let localBranches: [Ref]
    let remoteBranches: [Ref]
    let tags: [Ref]
    let cowork: SidebarCowork

    init(model: RepoModel, collapsed: Set<String>, openSections: Set<SidebarSection>) {
        self.model = model
        self.collapsed = collapsed
        self.openSections = openSections
        // One pass over refs instead of RepoModel's three computed filters.
        var local: [Ref] = [], remote: [Ref] = [], tags: [Ref] = []
        for r in model.refs {
            switch r.kind {
            case .localBranch: local.append(r)
            case .remoteBranch: remote.append(r)
            case .tag: tags.append(r)
            }
        }
        localBranches = local
        remoteBranches = remote
        self.tags = tags
        cowork = SidebarCowork(model.cowork)
    }

    // MARK: Full tree

    func tree() -> [SidebarItem] {
        var items: [SidebarItem] = []
        items.reserveCapacity(model.refs.count + model.worktrees.count + 32)
        for section in SidebarSection.allCases {
            let open = openSections.contains(section)
            items.append(header(section, expanded: open))
            if open { items += rows(for: section) }
        }
        return items
    }

    private func header(_ section: SidebarSection, expanded: Bool?) -> SidebarItem {
        let count = count(section)
        let highlight = section == .reviews && count > 0
        return SidebarItem(id: "header:" + section.rawValue,
                           kind: .header(section, count: count, expanded: expanded, highlight: highlight))
    }

    private func count(_ section: SidebarSection) -> Int {
        switch section {
        case .local: localBranches.count
        case .remote: remoteBranches.count
        case .worktrees: model.worktrees.count
        case .tasks: cowork.myTasks.count
        case .reviews: cowork.waiting.count
        case .stashes: model.stashes.count
        case .tags: tags.count
        case .team: cowork.people.count
        }
    }

    /// Refs and worktrees in the repo ("Viewing N"). Doesn't depend on what is collapsed.
    var totalCount: Int {
        localBranches.count + remoteBranches.count + tags.count + model.worktrees.count
    }

    private func rows(for section: SidebarSection) -> [SidebarItem] {
        switch section {
        case .local:
            return flatten(SidebarNode.tree(localBranches, idPrefix: "local"), depth: 0)
        case .remote:
            var items: [SidebarItem] = []
            var byRemote: [String: [Ref]] = [:]
            for r in remoteBranches { byRemote[r.remoteName ?? "", default: []].append(r) }
            for remote in model.remotes {
                let id = "remote:" + remote.name
                let open = !collapsed.contains(id)
                items.append(SidebarItem(id: id, kind: .remote(name: remote.name, expanded: open)))
                guard open else { continue }
                let branches = byRemote[remote.name] ?? []
                items += flatten(SidebarNode.tree(branches, idPrefix: id, name: \.branchNameWithoutRemote), depth: 1)
            }
            return items
        case .worktrees:
            return model.worktrees.map { SidebarItem(id: "wt:" + $0.path, kind: .worktree($0)) }
        case .tasks:
            var items = cowork.myTasks.map(taskItem)
            if items.isEmpty { items.append(SidebarItem(id: "note:tasks", kind: .note("Nothing assigned to you"))) }
            items.append(SidebarItem(id: "link:board", kind: .link(.board)))
            return items
        case .reviews:
            var items = cowork.waiting.map { reviewItem($0, waiting: true) }
                + cowork.requested.map { reviewItem($0, waiting: false) }
            if items.isEmpty { items.append(SidebarItem(id: "note:reviews", kind: .note("No open reviews"))) }
            items.append(SidebarItem(id: "link:reviews", kind: .link(.reviews)))
            return items
        case .stashes:
            return model.stashes.map { SidebarItem(id: "stash:" + $0.selector, kind: .stash($0)) }
        case .tags:
            return sortedTags(tags).map { SidebarItem(id: "ref:" + $0.fullName, kind: .branch($0, label: $0.name)) }
        case .team:
            return cowork.people.map(personItem) + [SidebarItem(id: "link:team", kind: .link(.team))]
        }
    }

    private func taskItem(_ t: CoworkTask) -> SidebarItem {
        SidebarItem(id: "task:" + t.id, kind: .task(t))
    }

    private func reviewItem(_ r: ReviewRequest, waiting: Bool) -> SidebarItem {
        SidebarItem(id: "review:" + r.id, kind: .review(r, waiting: waiting))
    }

    private func personItem(_ p: TeamMember) -> SidebarItem {
        SidebarItem(id: "person:" + p.id, kind: .person(p, isMe: p.id == cowork.me.id))
    }

    private func flatten(_ nodes: [SidebarNode], depth: Int) -> [SidebarItem] {
        var items: [SidebarItem] = []
        for node in nodes {
            if let ref = node.ref {
                items.append(SidebarItem(id: node.id, kind: .branch(ref, label: node.name), depth: depth))
            } else {
                let open = !collapsed.contains(node.id)
                items.append(SidebarItem(id: node.id, kind: .folder(name: node.name, expanded: open), depth: depth))
                if open { items += flatten(node.children, depth: depth + 1) }
            }
        }
        return items
    }

    /// Every folder and remote id that exists now; collapse state for others is stale.
    func allGroupIDs() -> Set<String> {
        var ids = Set<String>()
        SidebarNode.folderIDs(SidebarNode.tree(localBranches, idPrefix: "local"), into: &ids)
        for remote in model.remotes {
            let id = "remote:" + remote.name
            ids.insert(id)
            let branches = remoteBranches.filter { $0.remoteName == remote.name }
            SidebarNode.folderIDs(SidebarNode.tree(branches, idPrefix: id, name: \.branchNameWithoutRemote), into: &ids)
        }
        return ids
    }

    // MARK: Filtered

    /// Flat matches grouped by section, full names, no folders.
    func filtered(_ query: String) -> [SidebarItem] {
        let q = query.lowercased()
        func match(_ s: String) -> Bool { s.lowercased().contains(q) }
        let repoName = model.name

        var groups: [(SidebarSection, [SidebarItem])] = []
        func refItems(_ refs: [Ref]) -> [SidebarItem] {
            refs.filter { match($0.name) }.map { SidebarItem(id: "ref:" + $0.fullName, kind: .branch($0, label: $0.name)) }
        }
        let byName: (Ref, Ref) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        groups.append((.local, refItems(localBranches.sorted(by: byName))))
        groups.append((.remote, refItems(remoteBranches.sorted(by: byName))))
        // Match only what the row shows (branch, short folder name), not the full
        // path: every worktree path shares words like the repo name.
        groups.append((.worktrees, model.worktrees
            .filter { match($0.branch ?? "") || $0.sidebarFolderName(repoName: repoName).map(match) == true }
            .map { SidebarItem(id: "wt:" + $0.path, kind: .worktree($0)) }))
        groups.append((.tasks, cowork.myTasks
            .filter { match($0.title) || match($0.id) || match($0.branch ?? "") }
            .map(taskItem)))
        groups.append((.reviews, cowork.waiting.filter { match($0.branch) || match($0.title) }.map { reviewItem($0, waiting: true) }
            + cowork.requested.filter { match($0.branch) || match($0.title) }.map { reviewItem($0, waiting: false) }))
        groups.append((.stashes, model.stashes
            .filter { match($0.message) }
            .map { SidebarItem(id: "stash:" + $0.selector, kind: .stash($0)) }))
        groups.append((.tags, refItems(sortedTags(tags))))
        groups.append((.team, cowork.people
            .filter { match($0.name) || match($0.handle) || match($0.email) }
            .map(personItem)))

        var items: [SidebarItem] = []
        for (section, rows) in groups where !rows.isEmpty {
            items.append(SidebarItem(id: "header:" + section.rawValue,
                                     kind: .header(section, count: rows.count, expanded: nil, highlight: false)))
            items += rows
        }
        if items.isEmpty { items.append(SidebarItem(id: "note:nomatch", kind: .note("No matches"))) }
        return items
    }

    private func sortedTags(_ tags: [Ref]) -> [Ref] {
        tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
    }
}

extension Array where Element == SidebarItem {
    /// Result rows among filter results (for "N matches"); headers and notes don't count.
    var matchCount: Int {
        reduce(0) { n, item in
            switch item.kind {
            case .header, .link, .note: n
            default: n + 1
            }
        }
    }
}

extension Worktree {
    /// Folder name to show next to the branch, shortened: "repo-fix-login" → "fix-login",
    /// ".codex/worktrees/fix/repo" → "fix". Nil for the main worktree.
    func sidebarFolderName(repoName: String) -> String? {
        if isMain { return nil }   // the repo name, already in the window title
        var name = displayName
        guard !repoName.isEmpty else { return name }
        if name == repoName {
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if !parent.isEmpty { name = parent }
        } else if name.hasPrefix(repoName + "-") {
            name = String(name.dropFirst(repoName.count + 1))
        }
        return name
    }

    /// Like `sidebarFolderName`, but nil when it only repeats the branch name.
    func sidebarFolderLabel(repoName: String) -> String? {
        guard let name = sidebarFolderName(repoName: repoName) else { return nil }
        guard let branch else { return name }
        func letters(_ s: String) -> String {
            String(s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
        }
        let a = letters(name), b = letters(branch.split(separator: "/").last.map(String.init) ?? branch)
        return a.isEmpty || b.contains(a) || a.contains(b) ? nil : name
    }
}

extension RepoModel {
    /// Another worktree (not this window's) that has `branch` checked out.
    /// Git refuses to switch to or delete such a branch here.
    func sidebarOtherWorktree(for branch: String) -> Worktree? {
        guard let wt = worktrees.first(where: { $0.branch == branch }) else { return nil }
        return sidebarIsCurrent(wt) ? nil : wt
    }

    /// True for the worktree this window shows.
    func sidebarIsCurrent(_ wt: Worktree) -> Bool {
        wt.path == root.path || realPath(wt.path) == realPath(root.path)
    }

    /// Tasks linked to a branch (local name, without remote).
    func sidebarTasks(forBranch branch: String) -> [CoworkTask] {
        cowork.tasks.filter { $0.branch == branch }
    }
}
