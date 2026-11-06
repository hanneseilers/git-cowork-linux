import GitCoworkCore
import SwiftUI

/// Right panel for a selected commit: message, author, refs and changed files.
struct CommitPanel: View {
    let model: RepoModel
    let sha: String

    @State private var detail: CommitDetail?
    @State private var files: [FileChange] = []
    @State private var collapsed: Set<String> = []
    @State private var copied = false
    @State private var failed = false
    @AppStorage(FileViewMode.storageKey) private var mode: FileViewMode = .path
    @AppStorage(FileSortMode.storageKey) private var sort: FileSortMode = .path

    var body: some View {
        VStack(spacing: 0) {
            header(detail)
            Divider()
            if !model.status.isClean {
                WorkingCopyBanner(count: model.status.changeCount) {
                    model.selection = .workingCopy
                    model.openDiff = nil
                }
            }
            if let detail {
                content(detail)
            } else if failed {
                EmptyState(symbol: "exclamationmark.triangle", title: "Commit not found",
                           message: "It may have been removed by a rebase or garbage collection.")
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            // Show the previously selected commit until this one has loaded.
            if detail == nil, let last = InspectorSession.of(model).lastCommit {
                detail = last.detail
                files = last.files
            }
        }
        .task(id: sha) { await load() }
    }

    /// Loads detail and files, and swaps both in together once they're ready.
    private func load() async {
        let s = sha
        failed = false
        guard let d = await model.commitDetail(s) else {
            if !Task.isCancelled && s == sha { detail = nil; files = []; failed = true }
            return
        }
        guard !Task.isCancelled else { return }
        let f = await model.changedFiles(d)
        guard !Task.isCancelled, s == sha else { return }
        if detail?.id != d.id { collapsed = []; copied = false }
        detail = d
        files = f
        InspectorSession.of(model).lastCommit = (d, f)
    }

    private func content(_ d: CommitDetail) -> some View {
        let message = CommitText.split(body: d.body)
        let refs = model.refsByCommit[d.id] ?? []
        let branches = linkableBranchNames(refs)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: InspectorStyle.sectionGap) {
                MessageCard(subject: d.subject, text: message.text)
                AuthorBlock(detail: d, reveal: model.reveal)
                if !message.coAuthors.isEmpty {
                    CoAuthorList(authors: message.coAuthors)
                }
                if !refs.isEmpty {
                    FlowRow(spacing: Theme.Space.s) {
                        ForEach(refs) { ref in
                            RefBadge(ref: ref, color: laneColor(d.id))
                                .truncationMode(.middle)
                                .help(ref.name)
                        }
                    }
                }
                CoworkLinks(model: model, branches: branches)
            }
            .padding(InspectorStyle.padding)

            Divider()
            HStack(spacing: Theme.Space.m) {
                if files.isEmpty {
                    Text("No file changes").font(Theme.Font.small).foregroundStyle(.secondary)
                } else {
                    ChangeSummary(files: files)
                }
                Spacer(minLength: Theme.Space.s)
                FileViewControls()
            }
            .padding(.horizontal, InspectorStyle.padding)
            .frame(height: InspectorStyle.subheaderHeight)
            Divider()

            fileList(d)
        }
    }

    /// Top bar: "commit 858f93a" (click copies the full sha) and "Open on github.com".
    private func header(_ d: CommitDetail?) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text("Commit").font(Theme.Font.title)
            if let d {
                Button {
                    External.copy(d.id)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Text(copied ? "copied" : String(d.id.prefix(7)))
                        .font(Theme.Font.mono)
                }
                .buttonStyle(.link)
                .help("Copy full SHA \(d.id)")
            }
            Spacer(minLength: Theme.Space.s)
            if let d, let links = model.links(for: nil), let url = links.commitURL(d.id) {
                Button {
                    External.browse(url)
                } label: {
                    Label("Open on \(links.host)", systemImage: "arrow.up.right.square")
                        .lineLimit(1)
                }
                .buttonStyle(.link)
                .font(Theme.Font.small)
                .help(url.absoluteString)
            }
        }
        .padding(.horizontal, InspectorStyle.padding)
        .frame(height: InspectorStyle.headerHeight)
    }

    private func fileList(_ d: CommitDetail) -> some View {
        let items = FileTree.items(files, mode: mode, sort: sort, collapsed: collapsed, scope: "commit")
        return List(selection: selectedFile(d)) {
            ForEach(items) { item in
                switch item {
                case .folder(let f):
                    FolderRow(folder: f) { FileTree.toggle(f.id, in: &collapsed) }
                        .selectionDisabled()
                        .contextMenu {
                            let path = model.root.appendingPathComponent(f.path).path
                            Button("Reveal in Finder") { External.reveal(path) }
                            Button("Copy Path") { External.copy(f.path) }
                        }
                        .listRowSeparator(.hidden)
                case .file(let c, let depth):
                    ChangedFileRow(change: c, depth: depth, showDirectory: mode == .path)
                        .tag(c.id)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, InspectorStyle.rowHeight)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let f = files.first(where: { $0.id == id }) {
                let path = model.root.appendingPathComponent(f.path).path
                Button("Show Diff") { model.openDiff = .commit(d, f) }
                Divider()
                Button("Open in Editor") { External.openEditor(path) }
                Button("Reveal in Finder") { External.reveal(path) }
                Button("Copy Path") { External.copy(f.path) }
            }
        }
    }

    private func laneColor(_ sha: String) -> Color {
        guard let i = model.commitIndex[sha], i < model.graph.count else { return .accentColor }
        return Color(nsColor: Theme.lane(model.graph[i].color))
    }

    private func selectedFile(_ d: CommitDetail) -> Binding<String?> {
        Binding(
            get: {
                if case .commit(let cd, let f) = model.openDiff, cd.id == d.id { return f.id }
                return nil
            },
            set: { id in
                guard let id, let f = files.first(where: { $0.id == id }) else { return }
                model.openDiff = .commit(d, f)
            })
    }
}

/// Lays out children left to right, wrapping onto new lines. A child wider
/// than the row is narrowed to the row width (its text truncates).
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = size(of: v, maxWidth: width)
            if x > 0 && x + s.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            maxX = max(maxX, x + s.width)
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for v in subviews {
            let s = size(of: v, maxWidth: bounds.width)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }

    private func size(of v: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let ideal = v.sizeThatFits(.unspecified)
        guard ideal.width > maxWidth, maxWidth.isFinite else { return ideal }
        let s = v.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        return CGSize(width: min(s.width, maxWidth), height: s.height)
    }
}
