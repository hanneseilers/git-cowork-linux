import GitCoworkCore
import SwiftUI

/// Left column: branches, remotes, worktrees, cowork tasks/reviews, stashes, tags, team.
///
/// Equatable on the model's identity: the parent (RepoView) re-renders on every
/// keystroke and commit click, and the open-actions are closures SwiftUI can't
/// compare, so without this the whole list would be rebuilt and re-diffed each
/// time. The content still updates from the model it observes itself.
struct SidebarView: View, Equatable {
    let model: RepoModel
    /// Switch this window to another worktree.
    let openHere: (String) -> Void
    /// Open a worktree in a new tab.
    let openInNewTab: (String) -> Void

    nonisolated static func == (a: SidebarView, b: SidebarView) -> Bool { a.model === b.model }

    var body: some View {
        SidebarContent(model: model, openHere: openHere, openInNewTab: openInNewTab)
            .equatable()
    }
}

/// One flat List with custom header rows, so headers, folders and rows share one look.
private struct SidebarContent: View, Equatable {
    let model: RepoModel
    let openHere: (String) -> Void
    let openInNewTab: (String) -> Void

    nonisolated static func == (a: SidebarContent, b: SidebarContent) -> Bool { a.model === b.model }

    @State private var filter = ""
    @State private var selection: String?
    @FocusState private var filterFocused: Bool
    @AppStorage("sidebar.local") private var localOpen = SidebarSection.local.openByDefault
    @AppStorage("sidebar.remote") private var remoteOpen = SidebarSection.remote.openByDefault
    @AppStorage("sidebar.worktrees") private var worktreesOpen = SidebarSection.worktrees.openByDefault
    @AppStorage("sidebar.tasks") private var tasksOpen = SidebarSection.tasks.openByDefault
    @AppStorage("sidebar.reviews") private var reviewsOpen = SidebarSection.reviews.openByDefault
    @AppStorage("sidebar.stashes") private var stashesOpen = SidebarSection.stashes.openByDefault
    @AppStorage("sidebar.tags") private var tagsOpen = SidebarSection.tags.openByDefault
    @AppStorage("sidebar.team") private var teamOpen = SidebarSection.team.openByDefault
    /// Collapsed branch folders and remotes of this repository (all open by default).
    @State private var collapsed: Set<String> = []

    var body: some View {
        let builder = SidebarBuilder(model: model, collapsed: collapsed, openSections: openSections)
        let items = filter.isEmpty ? builder.tree() : builder.filtered(filter)
        VStack(alignment: .leading, spacing: 0) {
            SidebarFilterField(text: $filter, focus: $filterFocused,
                               count: filter.isEmpty ? builder.totalCount : items.matchCount)
                .padding(.horizontal, Theme.Metrics.panelPadding)
                .frame(height: Theme.Metrics.panelHeaderHeight)
                .background { focusShortcut }
            Divider()

            List(selection: $selection) {
                ForEach(items) { item in
                    row(item, first: item.id == items.first?.id)
                        .selectionDisabled(!item.isSelectable)
                        .listRowInsets(SidebarStyle.rowInsets)
                }
            }
            .listStyle(.sidebar)
            // One solid color behind the filter bar and the list (set by RepoView).
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, SidebarStyle.rowHeight)
            .environment(\.sidebarRowSize, .small)
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first { SidebarMenu(model: model, id: id, openHere: openHere, openInNewTab: openInNewTab) }
            } primaryAction: { ids in
                if let id = ids.first { primaryAction(id) }
            }
            .onChange(of: selection) { _, id in
                if let id { activate(id) }
            }
        }
        // Reads model.selection etc. in its own body, so commit clicks don't
        // re-run this one.
        .background { SidebarSelectionSync(model: model, selection: $selection) }
        .task(id: model.commonDir) { collapsed = SidebarCollapseStore.load(repoKey) }
        .onChange(of: model.refs) { prune(builder) }
        .onChange(of: model.remotes) { prune(builder) }
    }

    /// Invisible button that gives ⌥⌘F to the filter field.
    private var focusShortcut: some View {
        Button("Filter Sidebar") { filterFocused = true }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ item: SidebarItem, first: Bool) -> some View {
        switch item.kind {
        case .header(let section, let count, let expanded, let highlight):
            header(section, count: count, expanded: expanded, highlight: highlight, first: first)
        case .folder(let name, let expanded):
            SidebarGroupRow(name: name, symbol: "folder", expanded: expanded, depth: item.depth) { toggleFolder(item.id) }
        case .remote(let name, let expanded):
            SidebarGroupRow(name: name, symbol: "network", expanded: expanded, depth: item.depth) { toggleFolder(item.id) }
        case .branch(let ref, let label):
            SidebarRefRow(ref: ref, label: label, depth: item.depth)
                .tag(item.id)
        case .worktree(let wt):
            SidebarWorktreeRow(model: model, wt: wt, isCurrent: wt.path == model.root.path, repoName: model.name)
                .tag(item.id)
        case .stash(let stash):
            SidebarStashRow(stash: stash)
                .tag(item.id)
        case .task(let task):
            SidebarTaskRow(task: task)
                .tag(item.id)
        case .review(let review, let waiting):
            SidebarReviewRow(review: review, waiting: waiting, requester: waiting ? model.cowork.person(review.requester) : nil)
                .tag(item.id)
        case .person(let person, let isMe):
            SidebarPersonRow(person: person, isMe: isMe)
        case .link(let link):
            SidebarLinkRow(link: link) { open(link) }
        case .note(let text):
            SidebarNoteRow(text: text)
        }
    }

    @ViewBuilder
    private func header(_ section: SidebarSection, count: Int, expanded: Bool?, highlight: Bool, first: Bool) -> some View {
        let toggle = { toggleSection(section) }
        switch section {
        case .worktrees:
            SidebarSectionHeader(section: section, count: count, expanded: expanded, showsDivider: !first, toggle: toggle) {
                SidebarHeaderButton(help: "Add worktree") { model.sheet = .addWorktree(base: nil) }
            }
        case .tasks:
            SidebarSectionHeader(section: section, count: count, expanded: expanded, showsDivider: !first, toggle: toggle) {
                SidebarHeaderButton(help: "New task") { model.sheet = .newTask(status: .todo) }
            }
        default:
            SidebarSectionHeader(section: section, count: count, expanded: expanded, highlight: highlight,
                                 showsDivider: !first, toggle: toggle)
        }
    }

    // MARK: Expansion state

    private var openSections: Set<SidebarSection> {
        var s = Set<SidebarSection>()
        if localOpen { s.insert(.local) }
        if remoteOpen { s.insert(.remote) }
        if worktreesOpen { s.insert(.worktrees) }
        if tasksOpen { s.insert(.tasks) }
        if reviewsOpen { s.insert(.reviews) }
        if stashesOpen { s.insert(.stashes) }
        if tagsOpen { s.insert(.tags) }
        if teamOpen { s.insert(.team) }
        return s
    }

    private func toggleSection(_ section: SidebarSection) {
        guard filter.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            switch section {
            case .local: localOpen.toggle()
            case .remote: remoteOpen.toggle()
            case .worktrees: worktreesOpen.toggle()
            case .tasks: tasksOpen.toggle()
            case .reviews: reviewsOpen.toggle()
            case .stashes: stashesOpen.toggle()
            case .tags: tagsOpen.toggle()
            case .team: teamOpen.toggle()
            }
        }
    }

    /// Collapse state is kept per repository; all worktrees of one repo share it.
    private var repoKey: String { (model.commonDir ?? model.root).standardizedFileURL.path }

    private func toggleFolder(_ id: String) {
        var set = collapsed
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        withAnimation(.easeOut(duration: 0.15)) { collapsed = set }
        SidebarCollapseStore.save(set, repoKey: repoKey)
    }

    /// Forgets collapsed folders and remotes that no longer exist.
    private func prune(_ builder: SidebarBuilder) {
        guard model.isLoaded, !model.refs.isEmpty, !collapsed.isEmpty else { return }
        let kept = collapsed.intersection(builder.allGroupIDs())
        guard kept != collapsed else { return }
        collapsed = kept
        SidebarCollapseStore.save(kept, repoKey: repoKey)
    }

    // MARK: Actions

    /// Single click / keyboard selection.
    private func activate(_ id: String) {
        if id.hasPrefix("ref:"), let ref = model.refs.first(where: { "ref:" + $0.fullName == id }) {
            guard model.commitIndex[ref.target] != nil else { return }
            model.centerMode = .history
            model.reveal(ref.target)
        } else if id.hasPrefix("wt:"), let wt = model.worktrees.first(where: { "wt:" + $0.path == id }),
                  let head = wt.head, model.commitIndex[head] != nil {
            model.centerMode = .history
            model.reveal(head)
        } else if id.hasPrefix("task:") {
            openCoworkTarget("tasks/" + id.dropFirst(5), model: model)
        } else if id.hasPrefix("review:") {
            openCoworkTarget("reviews/" + id.dropFirst(7), model: model)
        }
    }

    /// Double click.
    private func primaryAction(_ id: String) {
        if id.hasPrefix("ref:"), let ref = model.refs.first(where: { "ref:" + $0.fullName == id }) {
            switch ref.kind {
            case .localBranch:
                // Git can't switch to a branch another worktree has checked out; go there instead.
                if let wt = model.sidebarOtherWorktree(for: ref.name) {
                    openHere(wt.path)
                } else if !ref.isHead {
                    Task { await model.checkout(ref) }
                }
            case .remoteBranch:
                if let wt = model.sidebarOtherWorktree(for: ref.branchNameWithoutRemote) {
                    openHere(wt.path)
                } else {
                    Task { await model.checkout(ref) }
                }
            case .tag:
                Task { await model.checkout(ref) }
            }
        } else if id.hasPrefix("wt:"), let wt = model.worktrees.first(where: { "wt:" + $0.path == id }) {
            if !model.sidebarIsCurrent(wt) { openHere(wt.path) }
        }
    }

    private func open(_ link: SidebarLink) {
        switch link {
        case .board: model.centerMode = .board
        case .reviews: model.centerMode = .reviews
        case .team: model.sheet = .team
        }
    }
}

/// Clears the sidebar highlight when the app shows something else, so the
/// highlight never goes stale and clicking the same row again re-reveals it.
private struct SidebarSelectionSync: View {
    let model: RepoModel
    @Binding var selection: String?

    var body: some View {
        Color.clear
            .onChange(of: model.selection) { check() }
            .onChange(of: model.coworkSelection) { check() }
            .onChange(of: model.centerMode) { check() }
    }

    private func check() {
        guard let id = selection, !stillShown(id) else { return }
        selection = nil
    }

    private func stillShown(_ id: String) -> Bool {
        if id.hasPrefix("ref:") || id.hasPrefix("wt:") {
            guard model.centerMode == .history, case .commit(let sha)? = model.selection else { return false }
            if id.hasPrefix("ref:") { return model.refs.contains { "ref:" + $0.fullName == id && $0.target == sha } }
            return model.worktrees.contains { "wt:" + $0.path == id && $0.head == sha }
        }
        if id.hasPrefix("task:") {
            return model.centerMode == .board && model.coworkSelection == .task(String(id.dropFirst(5)))
        }
        if id.hasPrefix("review:") {
            return model.centerMode == .reviews && model.coworkSelection == .review(String(id.dropFirst(7)))
        }
        return true
    }
}

/// Collapsed folder/remote ids per repository, in one UserDefaults dictionary.
enum SidebarCollapseStore {
    private static let key = "sidebar.collapsedByRepo"

    static func load(_ repo: String) -> Set<String> {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return Set(all[repo] ?? [])
    }

    static func save(_ ids: Set<String>, repoKey repo: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        all[repo] = ids.isEmpty ? nil : ids.sorted()
        UserDefaults.standard.set(all, forKey: key)
        // The old global key collided across repositories.
        UserDefaults.standard.removeObject(forKey: "sidebar.collapsedFolders")
    }
}
