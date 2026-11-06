import AppKit
import SwiftUI

/// Menu bar commands with keyboard shortcuts. They act on the focused window.
struct AppCommands: Commands {
    @FocusedValue(\.repoModel) private var model
    @FocusedValue(\.windowActions) private var window
    @Environment(\.openWindow) private var openWindow

    /// A repo window is focused and no git command is running, so a new one
    /// can't overlap it (same rule as the toolbar buttons).
    private var idle: Bool { model != nil && model?.busy == nil }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { WindowChrome.newTab() }
                .keyboardShortcut("t")
            Button("Open Repository…") {
                guard let path = RepoPicker.choose() else { return }
                if let window { window.open(path) } else { openInNewWindow(path) }
            }
            .keyboardShortcut("o")
            Button("Clone Repository…") {
                if let window {
                    window.showClone()
                } else {
                    // No window open: make an empty one, which shows the clone sheet.
                    LaunchFolders.pendingClone = true
                    LaunchFolders.newWindow()
                }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        // Ahead of Edit > Find so ⌘F filters commits in a repo window.
        CommandGroup(before: .textEditing) {
            Button("Filter Commits") { WindowChrome.focusFilter() }
                .keyboardShortcut("f")
                .disabled(model == nil)
        }

        CommandGroup(before: .sidebar) {
            ForEach(Array(CenterMode.allCases.enumerated()), id: \.element) { i, mode in
                Button(mode.title) {
                    model?.openDiff = nil
                    model?.centerMode = mode
                }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                .disabled(model == nil)
            }
            Divider()
        }

        CommandMenu("Repository") {
            Button("Refresh") { run { await $0.refresh() } }
                .keyboardShortcut("r")
                .disabled(model == nil)
            Divider()
            Button("Fetch All") { run { await $0.fetch() } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!idle)
            Button("Pull") { run { await $0.pull() } }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!idle)
            Button("Push") { run { await $0.push() } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!idle)
            Divider()
            Button("New Branch…") {
                guard let m = model else { return }
                m.sheet = .newBranch(from: m.currentBranch ?? "HEAD", label: m.currentBranch ?? "HEAD")
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(!idle)
            Button("Add Worktree…") { model?.sheet = .addWorktree(base: model?.currentBranch) }
                .disabled(!idle)
            Button("Stash Changes…") { model?.sheet = .stash }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!idle || model?.status.isClean != false)
            Button("Pop Stash") { run { await $0.popStash() } }
                .keyboardShortcut("s", modifiers: [.command, .shift, .option])
                .disabled(!idle || model?.stashes.isEmpty != false)
            Divider()
            Button("New Task…") {
                guard let m = model else { return }
                m.centerMode = .board
                m.openDiff = nil
                m.sheet = .newTask(status: .todo)
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(model == nil)
            Button(model?.currentBranch.map { "Request Review of \($0)…" } ?? "Request Review…") {
                guard let m = model, let branch = m.currentBranch else { return }
                m.sheet = .requestReview(branch: branch)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model?.currentBranch == nil)
            Button("Edit Team…") { model?.sheet = .team }
                .disabled(model == nil)
            Button("Sync Tasks Now") { run { await $0.syncCowork() } }
                .disabled(model == nil || model?.cowork.syncing == true)
            Divider()
            Button("Show Uncommitted Changes") {
                model?.centerMode = .history
                model?.selection = .workingCopy
                model?.openDiff = nil
            }
            .keyboardShortcut("0")
            .disabled(model == nil)
            Button("Open in Terminal") { if let m = model { External.openTerminal(m.root.path) } }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(model == nil)
            Button("Open in Editor") { if let m = model { External.openEditor(m.root.path) } }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model == nil)
            Button("Reveal in Finder") { if let m = model { External.reveal(m.root.path) } }
                .disabled(model == nil)
            Divider()
            Button(model?.showCommandLog == true ? "Hide Command Log" : "Show Command Log") {
                model?.showCommandLog.toggle()
            }
            .keyboardShortcut("j")
            .disabled(model == nil)
        }
    }

    private func run(_ action: @escaping (RepoModel) async -> Void) {
        guard let model else { return }
        Task { await action(model) }
    }

    /// File > Open with no window open: resolve to the worktree's top level
    /// first, like opening from a window does.
    private func openInNewWindow(_ path: String) {
        Task { @MainActor in
            if let resolved = await RepoLocator.resolve(path) {
                openWindow(id: "repo", value: resolved)
            } else {
                let alert = NSAlert()
                alert.messageText = "Not a git repository"
                alert.informativeText = path
                alert.runModal()
            }
        }
    }
}
