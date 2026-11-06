import GitCoworkCore
import SwiftUI

/// repository ▾ > branch ▾  History|Board|Reviews  ·  Pull ▾ Push ▾ Branch Worktree Stash Pop | Terminal Editor  ·  inbox, filter
///
/// Every item is its own small view, so each one only re-renders when the
/// model values it reads change (not on every keystroke elsewhere).
/// What's running is shown in the status bar, so the toolbar never shifts.
struct RepoToolbar: ToolbarContent {
    let model: RepoModel
    let openHere: (String) -> Void
    let openInNewTab: (String) -> Void
    let toggleSidebar: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: Theme.Space.xs) {
                // Leading edge, next to the window buttons (like Finder / Xcode).
                Button(action: toggleSidebar) {
                    Image(systemName: "sidebar.leading")
                        .font(ChromeStyle.icon)
                        .frame(height: ChromeStyle.iconHeight)
                        .padding(.vertical, Theme.Space.xs)
                }
                .buttonStyle(HoverFillStyle.chrome())
                .help("Show or hide the sidebar (⌃⌘S)")
                .keyboardShortcut("s", modifiers: [.command, .control])
                .padding(.trailing, Theme.Space.m)
                RepositoryPicker(model: model, openHere: openHere, openInNewTab: openInNewTab)
                Image(systemName: "chevron.right")
                    .font(Theme.Glyph.dropdown)
                    .foregroundStyle(.tertiary)
                BranchPicker(model: model, openHere: openHere)
                CenterModeSwitch(model: model)
                    .padding(.leading, Theme.Space.l)
            }
        }

        ToolbarItem(placement: .principal) {
            ActionButtons(model: model)
        }

        ToolbarItem(placement: .primaryAction) {
            InboxButton(model: model)
        }
    }
}

/// Bell with the number of unread inbox items; opens the inbox popover.
/// Closing the popover marks everything in it as seen.
private struct InboxButton: View {
    let model: RepoModel
    @State private var shown = false
    /// Bumped after marking items seen (the seen list lives in UserDefaults, not the model).
    @State private var seenVersion = 0

    private var repoKey: String { model.mainWorktreePath ?? model.root.path }

    var body: some View {
        let _ = seenVersion
        let unread = CoworkNotifier.shared.unseen(model.cowork.inbox, repo: repoKey).count
        Button { shown.toggle() } label: {
            Image(systemName: "bell")
                .font(ChromeStyle.icon)
                .frame(width: ChromeStyle.iconHeight + Theme.Space.s, height: ChromeStyle.iconHeight)
                .overlay(alignment: .topTrailing) {
                    if unread > 0 { CountBadge(count: unread, style: .toolbar).offset(x: ChromeStyle.badgeOffset.width, y: ChromeStyle.badgeOffset.height) }
                }
                .padding(.vertical, Theme.Space.xs)
        }
        .buttonStyle(HoverFillStyle.chrome())
        .help(unread > 0 ? "Inbox: \(unread) new" : "Inbox")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            InboxPopover(model: model)
        }
        .onChange(of: shown) {
            guard !shown else { return }
            CoworkNotifier.shared.markSeen(model.cowork.inbox.map(\.id), repo: repoKey)
            seenVersion += 1
        }
    }
}

private struct ActionButtons: View {
    let model: RepoModel

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ChromeSplitButton(title: "Pull", symbol: "arrow.down.to.line", badge: model.status.behind,
                              help: pullHelp, disabled: busy) {
                Task { await model.pull() }
            } items: {
                Button("Fetch All") { Task { await model.fetch() } }
                Divider()
                ForEach(PullMode.allCases, id: \.self) { mode in
                    Button(mode.title) { Task { await model.pull(mode) } }
                }
            }
            ChromeSplitButton(title: "Push", symbol: "arrow.up.to.line", badge: model.status.ahead,
                              help: pushHelp, disabled: busy) {
                Task { await model.push() }
            } items: {
                Button("Push") { Task { await model.push() } }
                Button("Force Push (with lease)…") { model.confirmForcePush() }
            }
            ChromeButton(title: "Branch", symbol: "arrow.triangle.branch", help: "New branch", disabled: busy) {
                model.sheet = .newBranch(from: model.currentBranch ?? "HEAD", label: model.currentBranch ?? "HEAD")
            }
            ChromeButton(title: "Worktree", symbol: "folder.badge.plus", help: "Add worktree", disabled: busy) {
                model.sheet = .addWorktree(base: model.currentBranch)
            }
            ChromeButton(title: "Stash", symbol: "tray.and.arrow.down", help: "Stash changes",
                         disabled: busy || model.status.isClean) {
                model.sheet = .stash
            }
            ChromeButton(title: "Pop", symbol: "tray.and.arrow.up", help: "Pop latest stash",
                         disabled: busy || model.stashes.isEmpty) {
                Task { await model.popStash() }
            }

            ChromeDivider()

            ChromeButton(title: "Terminal", symbol: "terminal", help: "Open in \(Prefs.terminalApp)") {
                External.openTerminal(model.root.path)
            }
            ChromeButton(title: "Editor", symbol: "chevron.left.forwardslash.chevron.right", help: "Open in \(Prefs.editorApp)") {
                External.openEditor(model.root.path)
            }
        }
    }

    private var busy: Bool { model.busy != nil }

    private var pullHelp: String {
        guard let up = model.status.upstream else { return "Pull (no upstream set)" }
        return model.status.behind > 0 ? "Pull \(model.status.behind) commit(s) from \(up)" : "Pull from \(up)"
    }

    private var pushHelp: String {
        guard let up = model.status.upstream else { return "Push and set upstream" }
        return model.status.ahead > 0 ? "Push \(model.status.ahead) commit(s) to \(up)" : "Push to \(up)"
    }
}

/// "repository ▾": this repo's worktrees, recent repositories, open and clone.
private struct RepositoryPicker: View {
    let model: RepoModel
    let openHere: (String) -> Void
    let openInNewTab: (String) -> Void
    @Environment(\.windowActions) private var window

    var body: some View {
        StackedPicker(caption: "repository", title: title, help: model.root.path) {
            if model.worktrees.count > 1 {
                Section("Worktrees") {
                    ForEach(model.worktrees) { wt in
                        Toggle(isOn: Binding(get: { wt.path == model.root.path },
                                             set: { _ in if wt.path != model.root.path { openHere(wt.path) } })) {
                            Text(worktreeLabel(wt))
                        }
                    }
                }
            }
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents, id: \.self) { path in
                        Button((path as NSString).lastPathComponent) { openInNewTab(path) }
                    }
                }
            }
            Divider()
            Button("Open Repository…") {
                if let path = RepoPicker.choose() { window?.open(path) }
            }
            Button("Clone Repository…") { window?.showClone() }
            Divider()
            Button("Reveal in Finder") { External.reveal(model.root.path) }
        }
    }

    private var title: String {
        let isMain = model.mainWorktreePath == nil || model.mainWorktreePath == model.root.path
        return isMain ? model.name : "\(model.name) · \(model.root.lastPathComponent)"
    }

    private func worktreeLabel(_ wt: Worktree) -> String {
        let branch = wt.branch ?? "detached"
        return wt.displayName == branch ? branch : "\(branch) — \(wt.displayName)"
    }

    /// Recent repositories other than this one, newest first.
    private var recents: [String] {
        let current = model.mainWorktreePath ?? model.root.path
        return Prefs.recentRepos
            .filter { $0 != current && $0 != model.root.path }
            .prefix(10)
            .filter { FileManager.default.fileExists(atPath: $0) }
    }
}

/// "branch ▾": check out a local branch (grouped by folder) or create one.
private struct BranchPicker: View {
    let model: RepoModel
    let openHere: (String) -> Void

    var body: some View {
        StackedPicker(caption: "branch", title: title, help: "Switch branch") {
            let groups = BranchGroups(model.localBranches)
            ForEach(groups.top) { branchItem($0, label: $0.name) }
            ForEach(groups.folders, id: \.name) { folder in
                Menu(folder.name) {
                    ForEach(folder.refs) { branchItem($0, label: String($0.name.dropFirst(folder.name.count + 1))) }
                }
            }
            Divider()
            Button("New Branch…") {
                model.sheet = .newBranch(from: model.currentBranch ?? "HEAD", label: model.currentBranch ?? "HEAD")
            }
        }
    }

    private var title: String {
        if let b = model.currentBranch { return b }
        if let sha = model.headSHA { return "detached at \(sha.prefix(7))" }
        return "no commits"
    }

    /// A branch checked out in another worktree can't be switched to here;
    /// offer to open that worktree instead.
    @ViewBuilder
    private func branchItem(_ ref: Ref, label: String) -> some View {
        if let wt = model.worktrees.first(where: { $0.branch == ref.name && $0.path != model.root.path }) {
            Button {
                openHere(wt.path)
            } label: {
                Label("\(label) — in \(wt.displayName)", systemImage: "folder")
            }
            .help("Checked out in worktree \(wt.path)")
        } else {
            Toggle(isOn: Binding(get: { ref.isHead }, set: { _ in if !ref.isHead { Task { await model.checkout(ref) } } })) {
                Text(label)
            }
        }
    }
}

/// Local branches split into top-level ones and "folder/…" groups.
private struct BranchGroups {
    struct Folder { let name: String; var refs: [Ref] }
    var top: [Ref] = []
    var folders: [Folder] = []

    init(_ refs: [Ref]) {
        let sorted = refs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var index: [String: Int] = [:]
        for ref in sorted {
            guard let slash = ref.name.firstIndex(of: "/") else { top.append(ref); continue }
            let name = String(ref.name[..<slash])
            if let i = index[name] {
                folders[i].refs.append(ref)
            } else {
                index[name] = folders.count
                folders.append(Folder(name: name, refs: [ref]))
            }
        }
    }
}
