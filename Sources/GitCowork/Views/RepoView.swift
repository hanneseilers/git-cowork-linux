import GitCoworkCore
import SwiftUI

/// The main window for one worktree: sidebar | center | inspector.
///
/// This body only does layout. Each column is its own view that reads just
/// the model values it needs, so typing a commit message or selecting a
/// commit doesn't re-render the sidebar or the toolbar.
struct RepoView: View {
    @Bindable var model: RepoModel
    let openHere: (String) -> Void
    let openInNewTab: (String) -> Void

    @AppStorage("layout.sidebarVisible") private var sidebarVisible = true

    var body: some View {
        // A plain split (not NavigationSplitView): the toolbar and the tab bar
        // then span the whole window, and all three panel headers start on the
        // same line, like GitKraken.
        VStack(spacing: 0) {
            HSplitView {
                if sidebarVisible {
                    SidebarColumn(model: model, openHere: openHere, openInNewTab: openInNewTab)
                        .equatable()
                        .frame(minWidth: Layout.sidebarMin, idealWidth: Layout.sidebarIdeal, maxWidth: Layout.sidebarMax, maxHeight: .infinity)
                        // Not under the tab bar: only the panel itself is tinted.
                        .background(Theme.sidebarBackground, ignoresSafeAreaEdges: [])
                }
                CenterColumn(model: model)
                    .frame(minWidth: Layout.centerMin, idealWidth: Layout.centerIdeal, maxWidth: .infinity, maxHeight: .infinity)
                InspectorColumn(model: model)
                    .frame(minWidth: Layout.inspectorMin, idealWidth: Layout.inspectorIdeal, maxWidth: Layout.inspectorMax, maxHeight: .infinity)
            }
            CommandLogArea(model: model)
            Divider()
            StatusBar(model: model)
        }
        .toolbar {
            RepoToolbar(model: model, openHere: openHere, openInNewTab: openInNewTab) {
                withAnimation(.easeOut(duration: 0.15)) { sidebarVisible.toggle() }
            }
        }
        .searchable(text: $model.filterText, placement: .toolbar, prompt: "Filter commits")
        .navigationTitle(title)
        .modifier(HideToolbarTitle())
        .modifier(RepoDialogs(model: model, openInNewTab: openInNewTab))
        .focusedSceneValue(\.repoModel, model)
    }

    /// Column widths, close to GitKraken's defaults.
    private enum Layout {
        static let sidebarMin: CGFloat = 220
        static let sidebarIdeal: CGFloat = 300
        static let sidebarMax: CGFloat = 440
        static let centerMin: CGFloat = 480
        static let centerIdeal: CGFloat = 760
        static let inspectorMin: CGFloat = 320
        static let inspectorIdeal: CGFloat = 440
        static let inspectorMax: CGFloat = 680
    }

    /// Window and tab title: "repo", or "repo · folder" for a linked worktree.
    private var title: String {
        let isMain = model.mainWorktreePath == nil || model.mainWorktreePath == model.root.path
        return isMain ? model.name : "\(model.name) · \(model.root.lastPathComponent)"
    }
}

/// The sidebar, compared by model identity only: its closures never change
/// meaning for a window, so parent re-renders don't rebuild the sidebar list.
private struct SidebarColumn: View, Equatable {
    let model: RepoModel
    let openHere: (String) -> Void
    let openInNewTab: (String) -> Void

    nonisolated static func == (a: SidebarColumn, b: SidebarColumn) -> Bool { a.model === b.model }

    var body: some View {
        SidebarView(model: model, openHere: openHere, openInNewTab: openInNewTab)
    }
}

/// History graph, task board or review list. An open diff covers whichever
/// is showing; Esc (which clears `openDiff`) returns to it.
private struct CenterColumn: View {
    let model: RepoModel

    var body: some View {
        let diff = model.openDiff
        let mode = model.centerMode
        ZStack {
            // Kept alive under a diff so the graph keeps its scroll position.
            if mode == .history {
                HistoryCenter(model: model)
                    .opacity(diff == nil ? 1 : 0)
                    .allowsHitTesting(diff == nil)
            } else if diff == nil {
                switch mode {
                case .board: BoardView(model: model)
                case .reviews: ReviewsView(model: model)
                case .history: EmptyView()
                }
            }
            if let diff {
                DiffPane(model: model, target: diff)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
}

/// The commit graph. Reads the values that change while typing or selecting,
/// so only this view (and the table it wraps) updates for them.
private struct HistoryCenter: View {
    let model: RepoModel

    var body: some View {
        HistoryTable(
            model: model,
            version: model.historyVersion,
            filter: model.filterText,
            wipCount: model.status.changeCount,
            selection: model.selection,
            revealToken: model.revealToken,
            worktreeInfoVersion: model.worktreeInfoVersion,
            draftSummary: model.draftSummary)
    }
}

/// Right panel: changes / commit details on History, the selected task or
/// review on Board and Reviews.
private struct InspectorColumn: View {
    let model: RepoModel

    var body: some View {
        switch model.centerMode {
        case .history:
            switch model.selection {
            case .workingCopy:
                ChangesPanel(model: model)
            case .commit(let sha):
                CommitPanel(model: model, sha: sha)
            case nil:
                EmptyState(symbol: "point.3.connected.trianglepath.dotted", title: "Select a commit")
            }
        case .board, .reviews:
            switch model.coworkSelection {
            case .task(let id):
                TaskPanel(model: model, taskID: id).id(id)
            case .review(let id):
                ReviewPanel(model: model, reviewID: id).id(id)
            case nil:
                if model.centerMode == .board {
                    EmptyState(symbol: "rectangle.split.3x1", title: "No task selected",
                               message: "Pick a card to see its details and comments, or press ⇧⌘T for a new task.")
                } else {
                    EmptyState(symbol: "checkmark.bubble", title: "No review selected",
                               message: "Pick a review request to see its changes and comments.")
                }
            }
        }
    }
}

/// Command log drawer above the status bar (⌘J).
private struct CommandLogArea: View {
    let model: RepoModel
    private static let height: CGFloat = 200

    var body: some View {
        if model.showCommandLog {
            Divider()
            CommandLogView(root: model.root)
                .frame(height: Self.height)
        }
    }
}

/// Alerts, confirmations and sheets driven by the model.
private struct RepoDialogs: ViewModifier {
    @Bindable var model: RepoModel
    let openInNewTab: (String) -> Void

    func body(content: Content) -> some View {
        content
            .alert(model.alert?.title ?? "", isPresented: isPresented(\.alert), presenting: model.alert) { _ in
                Button("OK") {}
                Button("Show Command Log") { model.showCommandLog = true }
            } message: { a in
                Text(a.message)
            }
            .alert(model.confirmation?.title ?? "", isPresented: isPresented(\.confirmation), presenting: model.confirmation) { c in
                Button(c.confirmTitle, role: c.destructive ? .destructive : nil) { Task { await c.action() } }
                Button("Cancel", role: .cancel) {}
            } message: { c in
                Text(c.message)
            }
            .sheet(item: $model.sheet) { kind in
                RepoSheet(model: model, kind: kind, openInNewTab: openInNewTab)
            }
    }

    private func isPresented<T>(_ key: ReferenceWritableKeyPath<RepoModel, T?>) -> Binding<Bool> {
        Binding(get: { model[keyPath: key] != nil }, set: { if !$0 { model[keyPath: key] = nil } })
    }
}
