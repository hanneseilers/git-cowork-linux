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
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionGap) {
                MessageCard(subject: d.subject, text: message.text)
                AuthorBlock(detail: d, reveal: model.reveal)
                if !message.coAuthors.isEmpty {
                    CoAuthorList(authors: message.coAuthors)
                }
                if !refs.isEmpty {
                    FlowRow {
                        ForEach(refs) { ref in
                            RefBadge(ref: ref, color: laneColor(d.id))
                                .truncationMode(.middle)
                                .help(ref.name)
                        }
                    }
                }
                CoworkLinks(model: model, branches: branches)
            }
            .padding(Theme.Metrics.panelPadding)

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
            .padding(.horizontal, Theme.Metrics.panelPadding)
            .frame(height: InspectorStyle.subheaderHeight)
            Divider()

            fileList(d)
        }
    }

    /// Top bar: "commit 858f93a" (click copies the full sha) and "Open on github.com".
    private func header(_ d: CommitDetail?) -> some View {
        PanelBar(spacing: Theme.Space.s) {
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
                    Text(verbatim: copied ? L("copied") : String(d.id.prefix(7)))
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
                    FileRow(change: c, depth: depth, showDirectory: mode == .path)
                        .tag(c.id)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, Theme.Metrics.rowHeight)
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

/// Accent-tinted strip at the top of the commit panel: "4 file changes in working directory".
struct WorkingCopyBanner: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "pencil.line")
                .foregroundStyle(InspectorStyle.bannerTint)
            Text(verbatim: count == 1 ? L("1 file change in working directory") : String(localized: "\(count) file changes in working directory"))
                .font(Theme.Font.body.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            Button("View Changes", action: action)
                .buttonStyle(ActionButtonStyle.secondary(InspectorStyle.bannerTint))
        }
        .padding(.horizontal, Theme.Metrics.panelPadding)
        .padding(.vertical, Theme.Space.m)
        .background(InspectorStyle.bannerTint.opacity(Theme.Tint.banner))
        .overlay(alignment: .bottom) { Divider() }
    }
}
