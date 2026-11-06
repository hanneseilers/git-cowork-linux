import AppKit
import GitCoworkCore
import SwiftUI

/// Routes a SheetKind to its sheet.
struct RepoSheet: View {
    let model: RepoModel
    let kind: SheetKind
    let openInNewTab: (String) -> Void

    var body: some View {
        switch kind {
        case .newBranch(let from, let label): NewBranchSheet(model: model, start: from, startLabel: label)
        case .newTag(let sha): NewTagSheet(model: model, sha: sha)
        case .renameBranch(let name): RenameBranchSheet(model: model, old: name)
        case .addWorktree(let base): AddWorktreeSheet(model: model, base: base, openInNewTab: openInNewTab)
        case .stash: StashSheet(model: model)
        case .newTask(let status): NewTaskSheet(model: model, status: status)
        case .requestReview(let branch): RequestReviewSheet(model: model, branch: branch)
        case .team: TeamSheet(model: model)
        }
    }
}


struct NewBranchSheet: View {
    let model: RepoModel
    let start: String
    let startLabel: String
    @State private var name = ""
    @State private var checkout = true

    var body: some View {
        SheetScaffold(title: "New Branch", confirmTitle: "Create Branch",
                      confirmDisabled: !RefName.isValid(name) || model.localBranches.contains { $0.name == name } || model.busy != nil) {
            Task { await model.createBranch(name, from: start, checkout: checkout) }
        } content: {
            TextField("Branch name", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("Starts from \(startLabel)").font(Theme.Font.small).foregroundStyle(.secondary)
            Toggle("Check out after creating", isOn: $checkout).toggleStyle(.checkbox)
        }
    }
}

struct NewTagSheet: View {
    let model: RepoModel
    let sha: String
    @State private var name = ""
    @State private var message = ""

    var body: some View {
        SheetScaffold(title: "New Tag", confirmTitle: "Create Tag", confirmDisabled: !RefName.isValid(name) || model.busy != nil) {
            Task { await model.createTag(name, at: sha, message: message) }
        } content: {
            TextField("Tag name, e.g. v1.2.0", text: $name).textFieldStyle(.roundedBorder)
            TextField("Message (optional, makes an annotated tag)", text: $message).textFieldStyle(.roundedBorder)
            Text("On commit \(String(sha.prefix(7)))").font(Theme.Font.small).foregroundStyle(.secondary)
        }
    }
}

struct RenameBranchSheet: View {
    let model: RepoModel
    let old: String
    @State private var name: String

    init(model: RepoModel, old: String) {
        self.model = model
        self.old = old
        _name = State(initialValue: old)
    }

    var body: some View {
        SheetScaffold(title: "Rename \(old)", confirmTitle: "Rename", confirmDisabled: !RefName.isValid(name) || name == old || model.busy != nil) {
            Task { await model.renameBranch(old, to: name) }
        } content: {
            TextField("New name", text: $name).textFieldStyle(.roundedBorder)
        }
    }
}

struct StashSheet: View {
    let model: RepoModel
    @State private var message = ""

    var body: some View {
        SheetScaffold(title: "Stash Changes", confirmTitle: "Stash", confirmDisabled: model.busy != nil) {
            Task { await model.stash(message: message) }
        } content: {
            TextField("Message (optional)", text: $message).textFieldStyle(.roundedBorder)
            Text("Stashes all changes, including new files, and leaves a clean working copy.")
                .font(Theme.Font.small).foregroundStyle(.secondary)
        }
    }
}

struct AddWorktreeSheet: View {
    let model: RepoModel
    let openInNewTab: (String) -> Void

    enum Mode: String, CaseIterable { case newBranch = "New branch", existing = "Existing branch" }

    @State private var mode: Mode
    @State private var branch: String
    @State private var base: String
    @State private var existing: String
    @State private var path = ""
    @State private var pathEdited = false
    @State private var openAfter = true

    init(model: RepoModel, base: String?, openInNewTab: @escaping (String) -> Void) {
        self.model = model
        self.openInNewTab = openInNewTab
        let free = model.localBranches.map(\.name).filter { name in !model.worktrees.contains { $0.branch == name } }
        let baseRef = model.refs.first { $0.name == base }
        // A remote branch as base: suggest a local branch of the same name.
        let suggested = baseRef?.kind == .remoteBranch ? baseRef!.branchNameWithoutRemote : ""
        let startExisting = baseRef?.kind == .localBranch && free.contains(base ?? "")
        _mode = State(initialValue: startExisting ? .existing : .newBranch)
        _branch = State(initialValue: suggested)
        _base = State(initialValue: base ?? model.currentBranch ?? "HEAD")
        _existing = State(initialValue: startExisting ? base! : (free.first ?? ""))
    }

    private var freeBranches: [String] {
        model.localBranches.map(\.name)
            .filter { name in !model.worktrees.contains { $0.branch == name } }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var targetBranch: String { mode == .newBranch ? branch : existing }

    private var valid: Bool {
        guard !path.isEmpty, !FileManager.default.fileExists(atPath: path) else { return false }
        if mode == .newBranch {
            return RefName.isValid(branch) && !model.localBranches.contains { $0.name == branch }
        }
        return !existing.isEmpty
    }

    var body: some View {
        SheetScaffold(title: "Add Worktree", confirmTitle: "Create Worktree", confirmDisabled: !valid || model.busy != nil) {
            let p = path, newBranch = mode == .newBranch ? branch : nil, start = mode == .newBranch ? base : existing
            let open = openAfter
            Task {
                if await model.addWorktree(path: p, newBranch: newBranch, base: start), open {
                    openInNewTab(p)
                }
            }
        } content: {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Form {
                if mode == .newBranch {
                    TextField("Branch", text: $branch, prompt: Text("e.g. claude/fix-login"))
                    TextField("Based on", text: $base)
                } else {
                    Picker("Branch", selection: $existing) {
                        ForEach(freeBranches, id: \.self) { Text($0) }
                    }
                }
                HStack {
                    TextField("Folder", text: Binding(get: { path }, set: { path = $0; pathEdited = true }))
                    Button("Choose…") { choosePath() }
                }
            }
            .formStyle(.columns)

            if FileManager.default.fileExists(atPath: path) && !path.isEmpty {
                Text("That folder already exists").font(Theme.Font.small).foregroundStyle(.red)
            }
            Toggle("Open in a new tab", isOn: $openAfter).toggleStyle(.checkbox)
        }
        .onAppear { updatePath() }
        .onChange(of: targetBranch) { updatePath() }
    }

    private func updatePath() {
        guard !pathEdited else { return }
        path = targetBranch.isEmpty ? "" : model.suggestedWorktreePath(branch: targetBranch)
    }

    private func choosePath() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (path as NSString).lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            pathEdited = true
        }
    }
}

struct CloneSheet: View {
    let onCloned: (String) -> Void
    @State private var url = ""
    @State private var parent = CloneSheet.defaultParent
    @State private var running = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    static var defaultParent: String {
        let gh = NSHomeDirectory() + "/Documents/GitHub"
        return FileManager.default.fileExists(atPath: gh) ? gh : NSHomeDirectory()
    }

    private var folderName: String {
        var s = url.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        return s.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Clone Repository").font(Theme.Font.title)
            TextField("git@github.com:org/repo.git or https://…", text: $url)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text(parent).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let u = panel.url { parent = u.path }
                }
            }
            .font(Theme.Font.small)
            if !folderName.isEmpty {
                Text("Clones into \(parent)/\(folderName)").font(Theme.Font.small).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(Theme.Font.monoSmall).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if running { ProgressView().controlSize(.small); Text("Cloning…").font(Theme.Font.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Clone") { clone() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(folderName.isEmpty || running)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 480)
    }

    private func clone() {
        running = true
        error = nil
        let dest = parent + "/" + folderName
        Task {
            do {
                try await RepoModel.clone(url.trimmingCharacters(in: .whitespaces), into: dest)
                running = false
                dismiss()
                onCloned(dest)
            } catch {
                running = false
                self.error = error.localizedDescription
            }
        }
    }
}
