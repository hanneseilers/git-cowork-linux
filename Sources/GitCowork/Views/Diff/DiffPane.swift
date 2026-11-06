import GitCoworkCore
import SwiftUI

/// Diff of one file, shown in place of the history. Esc or × goes back.
struct DiffPane: View {
    let model: RepoModel
    let target: DiffTarget

    @AppStorage("diff.mode") private var modeRaw = DiffMode.hunk.rawValue
    @State private var document = DiffDocument()
    @State private var version = 0
    @State private var loaded = false
    /// Files of the shown commit, for previous / next.
    @State private var commitFiles: [FileChange] = []

    private var file: FileChange { target.file }
    private var mode: DiffMode { DiffMode(rawValue: modeRaw) ?? .hunk }

    /// Working-copy diffs reload on every refresh, so edits by agents show up live.
    private var reloadKey: String {
        switch target {
        case .working(let f): "\(f.id)#\(model.refreshCount)"
        case .commit(let d, let f): "\(d.parents.first ?? "")..\(d.id):\(f.id)"
        }
    }

    private var documentID: String {
        switch target {
        case .working(let f): f.id
        case .commit(let d, let f): "\(d.parents.first ?? "")..\(d.id):\(f.id)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DiffHeader(file: file, added: document.added, removed: document.removed) {
                fileNavigation
                Picker("Diff layout", selection: $modeRaw) {
                    ForEach(DiffMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Hunk: one column. Split: old and new side by side.")
                fileActions
                Button {
                    External.openEditor(model.root.appendingPathComponent(file.path).path)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("Open in Editor")
                Button {
                    model.openDiff = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Back to history (Esc)")
            }
            Divider()
            if loaded && document.isEmpty {
                EmptyState(symbol: "doc.text", title: "No text changes",
                           message: "The file may be binary, empty, or only its mode changed.")
            } else {
                DiffTextView(document: document, version: version, documentID: documentID, mode: mode,
                             actions: HunkStaging.actions(for: target, document: document),
                             actionsEnabled: model.busy == nil,
                             onHunkAction: hunkAction)
            }
        }
        .task(id: reloadKey) { await load() }
        .task(id: commitID) { await loadCommitFiles() }
    }

    // MARK: Header pieces

    @ViewBuilder
    private var fileActions: some View {
        if case .working(let f) = target {
            switch f.area {
            case .unstaged, .untracked:
                Button {
                    Task {
                        guard await model.stage([f]) else { return }
                        model.openDiff = .working(FileChange(path: f.path, status: f.status == .untracked ? .added : f.status, area: .staged))
                    }
                } label: { Label("Stage File", systemImage: "plus") }
                .buttonStyle(ActionButtonStyle.secondary(Theme.Status.added))
            case .staged:
                Button {
                    Task {
                        guard await model.unstage([f]) else { return }
                        model.openDiff = nil
                    }
                } label: { Label("Unstage File", systemImage: "minus") }
                .buttonStyle(ActionButtonStyle.secondary(Theme.Status.deleted))
            case .conflicted:
                Button("Mark Resolved") { Task { await model.stage([f]); model.openDiff = nil } }
                    .buttonStyle(ActionButtonStyle.secondary(Theme.Status.added))
            }
        }
    }

    /// Previous / next file in the changes list or the commit.
    @ViewBuilder
    private var fileNavigation: some View {
        let files = siblings
        if files.count > 1, let i = files.firstIndex(where: { $0.id == file.id }) {
            HStack(spacing: Theme.Space.xs) {
                Button { open(files[i - 1]) } label: { Image(systemName: "chevron.up") }
                    .disabled(i == 0)
                    .help("Previous file")
                Button { open(files[i + 1]) } label: { Image(systemName: "chevron.down") }
                    .disabled(i == files.count - 1)
                    .help("Next file")
                Text("\(i + 1) of \(files.count)")
                    .font(Theme.Font.small.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    private var siblings: [FileChange] {
        switch target {
        case .working:
            let st = model.status
            return st.conflicted + st.unstaged + st.untracked + st.staged   // same order as the Changes panel
        case .commit:
            return commitFiles
        }
    }

    private func open(_ f: FileChange) {
        switch target {
        case .working: model.openDiff = .working(f)
        case .commit(let d, _): model.openDiff = .commit(d, f)
        }
    }

    // MARK: Loading and actions

    private var commitID: String? {
        if case .commit(let d, _) = target { return d.id }
        return nil
    }

    private func loadCommitFiles() async {
        guard case .commit(let d, _) = target else { commitFiles = []; return }
        commitFiles = await model.changedFiles(d)
    }

    private func load() async {
        let data: Data
        switch target {
        case .working(let f): data = await DiffLoader.working(f, root: model.root)
        case .commit(let d, let f): data = await DiffLoader.commit(d, file: f, root: model.root)
        }
        guard !Task.isCancelled else { return }
        if data == document.raw, loaded { return }   // unchanged: keep scroll position and selection
        let parsed = await Task.detached(priority: .userInitiated) { DiffDocument.parse(data) }.value
        guard !Task.isCancelled else { return }
        document = parsed
        version += 1
        loaded = true
    }

    private func hunkAction(_ action: HunkAction, _ hunk: Int) {
        let doc = document
        let f = file
        if action == .discard {
            HunkStaging.confirmDiscard(hunk: hunk, in: doc, file: f, model: model)
        } else {
            Task { await HunkStaging.run(action, hunk: hunk, in: doc, file: f, model: model) }
        }
    }
}

/// Bar above the diff: status, path as breadcrumb (folders grey, name bold),
/// rename source, line counts, then the trailing controls.
private struct DiffHeader<Trailing: View>: View {
    let file: FileChange
    let added: Int
    let removed: Int
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            StatusGlyph(status: file.status)
            VStack(alignment: .leading, spacing: 0) {
                breadcrumb
                    .lineLimit(1)
                    .truncationMode(.head)
                if let old = file.oldPath {
                    Text("renamed from \(old)")
                        .font(Theme.Font.small)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .layoutPriority(1)
            .help(file.path)
            if added + removed > 0 {
                HStack(spacing: Theme.Space.s) {
                    if added > 0 { Text("+\(added)").foregroundStyle(Theme.Status.added) }
                    if removed > 0 { Text("−\(removed)").foregroundStyle(Theme.Status.deleted) }
                }
                .font(Theme.Font.monoSmall)
                .fixedSize()
            }
            Spacer(minLength: Theme.Space.m)
            trailing
        }
        .padding(.horizontal, Theme.Metrics.panelPadding)
        .frame(height: Theme.Metrics.panelHeaderHeight)
        .background(.bar)
    }

    private var breadcrumb: Text {
        let dir = file.directory
        let name = Text(file.fileName).font(Theme.Font.body.weight(.semibold))
        guard !dir.isEmpty else { return name }
        let folders = dir.split(separator: "/").joined(separator: " / ")
        return Text(folders + " / ").font(Theme.Font.body).foregroundColor(.secondary) + name
    }
}
