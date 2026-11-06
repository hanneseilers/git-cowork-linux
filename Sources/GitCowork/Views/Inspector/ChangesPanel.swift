import GitCoworkCore
import SwiftUI

/// Right panel when "Uncommitted changes" is selected: file lists and the commit box.
struct ChangesPanel: View {
    @Bindable var model: RepoModel

    var body: some View {
        let st = model.status
        let task = st.branch.flatMap { model.inspectorTasks(branches: [$0]).first }
        VStack(spacing: 0) {
            PanelBar {
                // Shorter wording (and an icon-only task chip) when the panel is narrow.
                ViewThatFits(in: .horizontal) {
                    headerTitle(st, task: task, short: false, compactChip: false)
                    headerTitle(st, task: task, short: true, compactChip: false)
                    headerTitle(st, task: task, short: true, compactChip: true)
                    HStack(spacing: Theme.Space.m) {
                        title(st, short: true).truncationMode(.middle)
                        if let task { taskChip(task, compact: true) }
                    }
                }
                .font(Theme.Font.title)
                .lineLimit(1)
                .layoutPriority(1)
                Spacer(minLength: Theme.Space.s)
                if !st.isClean { FileViewControls() }
            }

            if let op = model.operation {
                OperationBanner(model: model, operation: op)
            }

            if st.isClean {
                EmptyState(symbol: "checkmark.circle", title: "Working copy is clean",
                           message: "Edit files, or let an agent work in this worktree. Changes show up here live.")
            } else {
                FileLists(model: model)
            }

            Divider()
            CommitComposer(model: model)
            BranchReviewBar(model: model)
        }
    }

    private func headerTitle(_ st: WorkingStatus, task: CoworkTask?, short: Bool, compactChip: Bool) -> some View {
        HStack(spacing: Theme.Space.m) {
            title(st, short: short)
            if let task { taskChip(task, compact: compactChip) }
        }
        .fixedSize()
    }

    private func taskChip(_ task: CoworkTask, compact: Bool) -> some View {
        Button { model.showTask(task.id) } label: {
            if compact {
                Image(systemName: task.status.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(task.status.color)
                    .frame(width: Theme.Metrics.chipHeight, height: Theme.Metrics.chipHeight)
                    .background(task.status.color.opacity(Theme.Tint.chip), in: Circle())
            } else {
                Chip(text: task.id, symbol: task.status.symbol, color: task.status.color)
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("\(task.id): \(task.title) (\(task.status.label)). Show on the board.")
    }

    /// "4 file changes on main"
    private func title(_ st: WorkingStatus, short: Bool) -> Text {
        if short {
            let branch = st.branch.map { Text($0).foregroundColor(.accentColor) } ?? Text("detached").foregroundColor(.secondary)
            return st.isClean ? branch : Text(verbatim: "\(st.changeCount) on ") + branch
        }
        if st.isClean {
            if let branch = st.branch { return Text("No changes on ") + Text(branch).foregroundColor(.accentColor) }
            return Text("No changes")
        }
        let n = st.changeCount
        let count = Text(verbatim: "\(n) file change\(n == 1 ? "" : "s") on ")
        if let branch = st.branch { return count + Text(branch).foregroundColor(.accentColor) }
        return count + Text("detached HEAD").foregroundColor(.secondary)
    }
}

/// Under the commit box: the open review of this branch, or "Request Review…"
/// when the branch has commits its base or upstream doesn't.
private struct BranchReviewBar: View {
    let model: RepoModel
    @State private var ahead: (count: Int, base: String)?

    var body: some View {
        let branch = model.currentBranch
        let review = branch.flatMap { model.inspectorReviews(branches: [$0]).first }
        // A real container (not Group) so .task runs even when nothing is shown.
        VStack(spacing: 0) {
            if let review {
                Divider()
                CoworkLinkRow(label: "Review", title: review.title,
                              help: String(localized: "Show the review of \(review.branch)")) {
                    VerdictChip(verdict: review.overall)
                } action: { model.showReview(review.id) }
                .padding(.horizontal, InspectorStyle.padding)
                .padding(.vertical, Theme.Space.s)
            } else if let branch, let ahead, ahead.count > 0 {
                Divider()
                HStack(spacing: Theme.Space.m) {
                    Text(verbatim: "\(ahead.count) commit\(ahead.count == 1 ? "" : "s") ahead of \(ahead.base)")
                        .font(Theme.Font.small)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Theme.Space.s)
                    Button("Request Review…") { model.sheet = .requestReview(branch: branch) }
                        .buttonStyle(.link)
                        .font(Theme.Font.small)
                        .fixedSize()
                        .help("Ask teammates to review \(branch)")
                }
                .padding(.horizontal, InspectorStyle.padding)
                .frame(height: Theme.Metrics.rowHeight + Theme.Space.m)
            }
        }
        .task(id: key) { await countAhead() }
    }

    private var key: String {
        "\(model.currentBranch ?? "")|\(model.headSHA ?? "")|\(model.status.upstream ?? "")|\(model.status.ahead)|\(model.refs.count)"
    }

    /// Commits on HEAD that aren't on the repo's default branch; falls back
    /// to the upstream's ahead count.
    private func countAhead() async {
        guard let branch = model.currentBranch, model.headSHA != nil else { ahead = nil; return }
        if let base = model.baseBranch() {
            if branch == base.name { ahead = nil; return }   // nothing to review on the base itself
            let n = await model.commitsAhead(of: base.ref)
            guard !Task.isCancelled else { return }
            if let n { ahead = (n, base.ref); return }
        }
        if let up = model.status.upstream, model.status.ahead > 0 {
            ahead = (model.status.ahead, up)
        } else {
            ahead = nil
        }
    }
}

private struct FileLists: View {
    @Bindable var model: RepoModel
    @State private var collapsedFolders: Set<String> = []
    @State private var collapsedSections: Set<String> = []
    @AppStorage(FileViewMode.storageKey) private var mode: FileViewMode = .path
    @AppStorage(FileSortMode.storageKey) private var sort: FileSortMode = .path

    private var selectedID: Binding<String?> {
        Binding(
            get: {
                if case .working(let f) = model.openDiff { return f.id }
                return nil
            },
            set: { id in
                guard let id, let change = allChanges.first(where: { $0.id == id }) else { return }
                model.openDiff = .working(change)
            })
    }

    private var unstaged: [FileChange] { model.status.unstaged + model.status.untracked }
    private var allChanges: [FileChange] { model.status.conflicted + unstaged + model.status.staged }

    var body: some View {
        let st = model.status
        List(selection: selectedID) {
            if !st.conflicted.isEmpty {
                section("conflicts", title: "Conflicted files", files: st.conflicted) { EmptyView() }
            }
            section("unstaged", title: "Unstaged files", files: unstaged) {
                if !unstaged.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        unstagedButtons(discard: "Discard All", stage: "Stage All Changes")
                        unstagedButtons(discard: "Discard", stage: "Stage All")
                    }
                }
            }
            section("staged", title: "Staged files", files: st.staged) {
                if !st.staged.isEmpty {
                    Button {
                        Task { await model.unstageAll() }
                    } label: { Label("Unstage All", systemImage: "minus") }
                    .buttonStyle(ActionButtonStyle.secondary(Theme.Status.deleted))
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, InspectorStyle.rowHeight)
        .contextMenu(forSelectionType: String.self) { ids in
            menu(for: changes(ids))
        } primaryAction: { ids in
            toggle(changes(ids))
        }
        .onChange(of: model.status) { _, st in followOpenDiff(st) }
    }

    /// After staging/unstaging (here, in the diff, or in a terminal) the open
    /// diff's entry may be gone: point it at the same path in its new list.
    private func followOpenDiff(_ st: WorkingStatus) {
        guard case .working(let f) = model.openDiff else { return }
        let all = st.conflicted + st.unstaged + st.untracked + st.staged
        if all.contains(where: { $0.id == f.id }) { return }
        let preferred: [FileChange] = f.area == .staged
            ? st.unstaged + st.untracked + st.conflicted
            : st.staged + st.conflicted + st.unstaged + st.untracked
        if let match = preferred.first(where: { $0.path == f.path }) {
            model.openDiff = .working(match)
        } else {
            model.openDiff = nil
        }
    }

    private func unstagedButtons(discard: String, stage: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Button {
                model.discard(unstaged)
            } label: { Label(discard, systemImage: "trash") }
            .buttonStyle(ActionButtonStyle.secondary(Theme.Status.deleted))
            .help("Discard all unstaged changes and delete untracked files")
            Button {
                Task { await model.stageAll() }
            } label: { Label(stage, systemImage: "plus") }
            .buttonStyle(ActionButtonStyle.secondary(Theme.Status.added))
            .help("Stage all changes")
        }
        .fixedSize()
    }

    private func section<Trailing: View>(_ key: String, title: String, files: [FileChange],
                                         @ViewBuilder trailing: () -> Trailing) -> some View {
        let isCollapsed = Binding(
            get: { collapsedSections.contains(key) },
            set: { if $0 { collapsedSections.insert(key) } else { collapsedSections.remove(key) } })
        return Section {
            if !isCollapsed.wrappedValue {
                rows(files, scope: key)
            }
        } header: {
            SectionHeader(title: title, count: files.count, collapsed: isCollapsed, trailing: trailing)
                .padding(.vertical, Theme.Space.s)
        }
    }

    private func rows(_ files: [FileChange], scope: String) -> some View {
        let items = FileTree.items(files, mode: mode, sort: sort, collapsed: collapsedFolders, scope: scope)
        return ForEach(items) { item in
            switch item {
            case .folder(let f):
                FolderRow(folder: f, toggle: { FileTree.toggle(f.id, in: &collapsedFolders) },
                          action: action(for: f.files))
                    .selectionDisabled()
                    .contextMenu { menu(for: f.files, folder: f.path) }
                    .listRowSeparator(.hidden)
            case .file(let c, let depth):
                FileRow(change: c, depth: depth, showDirectory: mode == .path, action: action(for: [c]))
                    .tag(c.id)
                    .listRowSeparator(.hidden)
            }
        }
    }

    /// Hover button: "Stage" for unstaged files, "Unstage" for staged ones.
    private func action(for files: [FileChange]) -> RowAction? {
        guard let area = files.first?.area else { return nil }
        switch area {
        case .staged:
            return RowAction(title: "Unstage", tint: Theme.Status.deleted) { toggle(files) }
        case .conflicted:
            return RowAction(title: "Mark Resolved", tint: Theme.Status.added) { toggle(files) }
        case .unstaged, .untracked:
            return RowAction(title: "Stage", tint: Theme.Status.added) { toggle(files) }
        }
    }

    private func changes(_ ids: Set<String>) -> [FileChange] {
        allChanges.filter { ids.contains($0.id) }
    }

    private func toggle(_ changes: [FileChange]) {
        let other = changes.filter { $0.area != .staged }
        // A partially staged file has a row in both lists; selecting both
        // means "stage it", not "stage, then unstage everything".
        let otherPaths = Set(other.map(\.path))
        let staged = changes.filter { $0.area == .staged && !otherPaths.contains($0.path) }
        Task {
            if !other.isEmpty { await model.stage(other) }
            if !staged.isEmpty { await model.unstage(staged) }
        }
    }

    /// `folder` is set for a folder row: Reveal / Copy Path then use the folder.
    @ViewBuilder
    private func menu(for changes: [FileChange], folder: String? = nil) -> some View {
        if !changes.isEmpty {
            let staged = changes.filter { $0.area == .staged }
            let other = changes.filter { $0.area != .staged }
            // Conflicted files are handled by Use Mine / Use Theirs / Mark Resolved.
            let discardable = changes.filter { $0.area == .unstaged || $0.area == .untracked }
            let conflictedOnly = !other.isEmpty && other.allSatisfy { $0.area == .conflicted }
            if !other.isEmpty { Button(conflictedOnly ? "Mark Resolved" : "Stage") { Task { await model.stage(other) } } }
            if !staged.isEmpty { Button("Unstage") { Task { await model.unstage(staged) } } }
            if folder == nil, changes.count == 1, let c = changes.first, c.area == .conflicted {
                Divider()
                // During a rebase "mine" is the commit being replayed (git's --theirs).
                let rebasing = model.operation == .rebase
                Button(rebasing ? "Use My Commit" : "Use Mine") { Task { await model.resolve(c, mine: true) } }
                Button(rebasing ? "Use Upstream" : "Use Theirs") { Task { await model.resolve(c, mine: false) } }
            }
            if !discardable.isEmpty {
                Divider()
                Button("Discard Changes…", role: .destructive) { model.discard(discardable) }
            }
            Divider()
            if let folder {
                let path = model.root.appendingPathComponent(folder).path
                Button("Reveal in Finder") { External.reveal(path) }
                Button("Copy Path") { External.copy(folder) }
            } else if let c = changes.first {
                let path = model.root.appendingPathComponent(c.path).path
                Button("Open in Editor") { External.openEditor(path) }
                Button("Reveal in Finder") { External.reveal(path) }
                Button("Copy Path") { External.copy(c.path) }
            }
        }
    }
}

/// Shown while a merge, rebase, cherry-pick or revert is waiting for the user.
private struct OperationBanner: View {
    let model: RepoModel
    let operation: RepoOperation

    var body: some View {
        let conflicts = model.status.conflicted.count
        HStack(spacing: Theme.Space.m) {
            Image(systemName: conflicts > 0 ? "exclamationmark.triangle.fill" : "arrow.triangle.merge")
                .foregroundStyle(conflicts > 0 ? Theme.Status.warning : Color.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(operation.rawValue) in progress").font(Theme.Font.body.weight(.semibold))
                Text(conflicts == 0 ? "No conflicts left." : conflicts == 1 ? "1 conflicted file: resolve, then stage."
                     : "\(conflicts) conflicted files: resolve, then stage.")
                    .font(Theme.Font.small).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Abort") { Task { await model.abortOperation() } }
                .buttonStyle(ActionButtonStyle.secondary(Theme.Status.deleted))
            if operation == .rebase {
                Button("Skip") { Task { await model.skipRebaseCommit() } }
                    .buttonStyle(ActionButtonStyle.secondary())
            }
            Button("Continue") { Task { await model.continueOperation() } }
                .buttonStyle(ActionButtonStyle.primary())
                .disabled(conflicts > 0)
        }
        .padding(Theme.Metrics.cardPadding)
        .background(Theme.Status.warning.opacity(Theme.Tint.banner), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .padding(.horizontal, InspectorStyle.padding)
        .padding(.top, InspectorStyle.padding)
    }
}
