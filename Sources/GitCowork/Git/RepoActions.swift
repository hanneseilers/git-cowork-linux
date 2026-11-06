import AppKit
import Foundation
import GitCoworkCore

enum PullMode: String, CaseIterable {
    case `default`, ffOnly, rebase, merge

    var title: String {
        switch self {
        case .default: "Pull"
        case .ffOnly: "Pull (fast-forward only)"
        case .rebase: "Pull (rebase)"
        case .merge: "Pull (merge)"
        }
    }

    var args: [String] {
        switch self {
        case .default: ["pull"]
        case .ffOnly: ["pull", "--ff-only"]
        case .rebase: ["pull", "--rebase"]
        case .merge: ["pull", "--no-rebase"]
        }
    }
}

enum ResetMode: String, CaseIterable {
    case soft, mixed, hard
}

/// Everything the user can do to a repo. Each action is one or two plain git
/// commands; they all show up in the command log.
extension RepoModel {
    /// Runs a git command that changes the repo, then refreshes.
    /// Errors are shown as an alert with git's own message.
    @discardableResult
    func perform(_ label: String, _ args: [String], okCodes: Set<Int32> = [0]) async -> Bool {
        guard beginBusy(label) else { return false }
        defer { endBusy(label) }
        do {
            try await git.run(args, in: root, logged: true, okCodes: okCodes)
            await refresh()
            return true
        } catch {
            await refresh()
            alert = AlertItem(title: "\(label) failed", message: error.localizedDescription)
            return false
        }
    }

    /// One git action at a time. Claims `busy` for `label`, or tells the user
    /// why nothing happened when another action is still running.
    func beginBusy(_ label: String) -> Bool {
        if let running = busy {
            if alert == nil {
                alert = AlertItem(title: "\(label) not started", message: "Wait for \(running) to finish, then try again.")
            }
            return false
        }
        busy = label
        return true
    }

    /// Releases `busy` if `label` still holds it.
    func endBusy(_ label: String) {
        if busy == label { busy = nil }
    }

    // MARK: Remote

    func fetch() async {
        await perform("Fetch", ["fetch", "--all", "--prune"])
        await syncCowork()
    }

    func pull(_ mode: PullMode = .default) async {
        await perform("Pull", mode.args)
    }

    func push(force: Bool = false) async {
        var args = ["push"]
        if force { args.append("--force-with-lease") }
        if status.upstream == nil {
            guard let remote = defaultRemote else {
                alert = AlertItem(title: "Push failed", message: "This repository has no remote.")
                return
            }
            args += ["-u", remote, "HEAD"]
        }
        await perform(force ? "Force push" : "Push", args)
    }

    func confirmForcePush() {
        confirmation = Confirmation(
            title: "Force push \(currentBranch ?? "HEAD")?",
            message: "Uses --force-with-lease: it overwrites the remote branch, but only if nobody else pushed to it since your last fetch.",
            confirmTitle: "Force Push"
        ) { [weak self] in await self?.push(force: true) }
    }

    // MARK: Branches

    /// Worktree (other than this one) that has `branch` checked out.
    func worktree(holding branch: String) -> Worktree? {
        worktrees.first { $0.branch == branch && $0.path != root.path }
    }

    func checkout(_ ref: Ref) async {
        let local = ref.kind == .remoteBranch ? ref.branchNameWithoutRemote : ref.name
        if ref.kind != .tag, let wt = worktree(holding: local) {
            alert = AlertItem(title: "\(local) is checked out in another worktree",
                              message: "Git allows a branch in one worktree at a time. It's open in \(wt.path). Open that worktree instead, or create a new branch.")
            return
        }
        switch ref.kind {
        case .localBranch:
            await perform("Checkout", ["switch", ref.name])
        case .remoteBranch:
            let local = ref.branchNameWithoutRemote
            if localBranches.contains(where: { $0.name == local }) {
                await perform("Checkout", ["switch", local])
            } else {
                await perform("Checkout", ["switch", "--track", ref.name])
            }
        case .tag:
            await perform("Checkout", ["switch", "--detach", ref.name])
        }
    }

    func checkoutCommit(_ sha: String) async {
        await perform("Checkout", ["switch", "--detach", sha])
    }

    /// `--no-track`: a new branch made from e.g. origin/main shouldn't use main as its upstream.
    @discardableResult
    func createBranch(_ name: String, from start: String, checkout: Bool) async -> Bool {
        if checkout {
            return await perform("Create branch", ["switch", "--no-track", "-c", name, start])
        } else {
            return await perform("Create branch", ["branch", "--no-track", name, start])
        }
    }

    /// Pushes a branch that may not be checked out, setting its upstream.
    @discardableResult
    func push(branch: String) async -> Bool {
        guard let remote = defaultRemote else {
            alert = AlertItem(title: "Push failed", message: "This repository has no remote.")
            return false
        }
        return await perform("Push", ["push", "-u", remote, branch])
    }

    func renameBranch(_ old: String, to new: String) async {
        await perform("Rename branch", ["branch", "-m", old, new])
    }

    func deleteBranch(_ ref: Ref) {
        if ref.kind == .remoteBranch, let remote = ref.remoteName {
            confirmation = Confirmation(
                title: "Delete \(ref.name) on \(remote)?",
                message: "This deletes the branch on the server for everyone.",
                confirmTitle: "Delete Remote Branch"
            ) { [weak self] in
                await self?.perform("Delete remote branch", ["push", remote, "--delete", ref.branchNameWithoutRemote])
            }
            return
        }
        Task {
            guard beginBusy("Delete branch") else { return }
            let r = await git.execute(["branch", "-d", ref.name], in: root)
            endBusy("Delete branch")
            if r.exitCode == 0 {
                CommandLog.shared.add(.init(args: ["branch", "-d", ref.name], directory: root, start: .now, duration: 0, result: r))
                await refresh()
            } else if r.stderr.contains("not fully merged") {
                confirmation = Confirmation(
                    title: "\(ref.name) is not fully merged",
                    message: "Its commits aren't in your current branch or its upstream. Delete it anyway? The commits can only be recovered via reflog.",
                    confirmTitle: "Delete Anyway"
                ) { [weak self] in await self?.perform("Delete branch", ["branch", "-D", ref.name]) }
            } else {
                alert = AlertItem(title: "Delete branch failed", message: GitError(command: "", result: r).localizedDescription)
            }
        }
    }

    func merge(_ name: String) async {
        let ok = await perform("Merge", ["merge", name], okCodes: [0])
        if !ok, !status.conflicted.isEmpty {
            alert = AlertItem(title: "Merge has conflicts",
                              message: "Resolve the conflicted files in Changes, then Continue, or Abort the merge.")
            selection = .workingCopy
        }
    }

    func rebase(onto name: String) async {
        let ok = await perform("Rebase", ["rebase", name])
        if !ok, !status.conflicted.isEmpty { selection = .workingCopy }
    }

    // MARK: Commits

    func cherryPick(_ sha: String) async {
        await perform("Cherry-pick", ["cherry-pick", sha])
    }

    func revert(_ sha: String) async {
        await perform("Revert", ["revert", "--no-edit", sha])
    }

    func reset(to sha: String, mode: ResetMode) {
        let branch = currentBranch ?? "HEAD"
        let short = String(sha.prefix(7))
        if mode == .hard {
            confirmation = Confirmation(
                title: "Hard reset \(branch) to \(short)?",
                message: "All uncommitted changes are lost, and commits after \(short) leave the branch.",
                confirmTitle: "Reset"
            ) { [weak self] in await self?.perform("Reset", ["reset", "--hard", sha]) }
        } else {
            Task { await perform("Reset", ["reset", "--\(mode.rawValue)", sha]) }
        }
    }

    func createTag(_ name: String, at sha: String, message: String) async {
        if message.isEmpty {
            await perform("Create tag", ["tag", name, sha])
        } else {
            await perform("Create tag", ["tag", "-a", name, "-m", message, sha])
        }
    }

    func deleteTag(_ name: String) {
        confirmation = Confirmation(title: "Delete tag \(name)?", message: "Only deletes the local tag.",
                                    confirmTitle: "Delete") { [weak self] in
            await self?.perform("Delete tag", ["tag", "-d", name])
        }
    }

    func pushTag(_ name: String) async {
        guard let remote = defaultRemote else { return }
        await perform("Push tag", ["push", remote, "refs/tags/\(name)"])
    }

    // MARK: Working copy

    @discardableResult
    func stage(_ changes: [FileChange]) async -> Bool {
        let paths = changes.map(\.path)
        guard !paths.isEmpty else { return false }
        return await perform("Stage", ["add", "--"] + paths)
    }

    func stageAll() async {
        await perform("Stage all", ["add", "-A"])
    }

    @discardableResult
    func unstage(_ changes: [FileChange]) async -> Bool {
        var paths = changes.map(\.path)
        paths += changes.compactMap(\.oldPath)
        guard !paths.isEmpty else { return false }
        if headSHA == nil {
            return await perform("Unstage", ["rm", "--cached", "-r", "-q", "--"] + paths)
        } else {
            return await perform("Unstage", ["restore", "--staged", "--"] + paths)
        }
    }

    func unstageAll() async {
        if headSHA == nil {
            await perform("Unstage all", ["rm", "--cached", "-r", "-q", "."])
        } else {
            await perform("Unstage all", ["reset", "-q"])
        }
    }

    func discard(_ changes: [FileChange]) {
        guard !changes.isEmpty else { return }
        let names = changes.count == 1 ? changes[0].path : "\(changes.count) files"
        confirmation = Confirmation(
            title: "Discard changes to \(names)?",
            message: "This can't be undone.",
            confirmTitle: "Discard"
        ) { [weak self] in
            guard let self else { return }
            let untracked = changes.filter { $0.area == .untracked }.map(\.path)
            let tracked = changes.filter { $0.area != .untracked && $0.area != .conflicted }.map(\.path)
            if !tracked.isEmpty { await perform("Discard", ["restore", "--"] + tracked) }
            if !untracked.isEmpty { await perform("Discard", ["clean", "-fdq", "--"] + untracked) }
        }
    }

    /// Discards every uncommitted change, including new files.
    func discardAll() {
        confirmation = Confirmation(
            title: "Discard all changes?",
            message: "Every uncommitted change and every new file in this worktree is lost. This can't be undone.",
            confirmTitle: "Discard All"
        ) { [weak self] in
            guard let self else { return }
            if await perform("Discard all", ["restore", "--staged", "--worktree", "--", "."]) {
                await perform("Discard all", ["clean", "-fdq"])
            }
        }
    }

    func commit(message: String, amend: Bool) async -> Bool {
        var args = ["commit"]
        if amend { args.append("--amend") }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if amend { args.append("--no-edit") } else { args.append("--no-edit") }
        } else {
            args += ["-m", message]
        }
        return await perform(amend ? "Amend" : "Commit", args)
    }

    /// Resolves a conflict with one whole side. `mine` is the user's own
    /// version: git's --ours for merge / cherry-pick / revert, but --theirs
    /// during a rebase (there --ours is the branch being rebased onto).
    func resolve(_ change: FileChange, mine: Bool) async {
        let side = (operation == .rebase) == mine ? "theirs" : "ours"
        guard await perform("Resolve", ["checkout", "--\(side)", "--", change.path]) else { return }
        await perform("Resolve", ["add", "--", change.path])
    }

    /// Stages, unstages or discards one hunk (a patch from DiffDocument.patch(forHunk:)).
    @discardableResult
    func applyHunk(_ patch: Data, _ action: HunkAction, zeroContext: Bool) async -> Bool {
        // --whitespace=nowarn also overrides apply.whitespace=fix, which would
        // otherwise rewrite the staged lines.
        var args = ["apply", "--whitespace=nowarn"]
        switch action {
        case .stage: args += ["--cached"]
        case .unstage: args += ["--cached", "--reverse"]
        case .discard: args += ["--reverse"]
        }
        if zeroContext { args.append("--unidiff-zero") }   // diff.context=0
        args.append("-")
        guard beginBusy(action.title) else { return false }
        defer { endBusy(action.title) }
        do {
            try await git.run(args, in: root, logged: true, input: patch)
            await refresh()
            return true
        } catch {
            await refresh()
            alert = AlertItem(title: "\(action.title) failed", message: error.localizedDescription)
            return false
        }
    }

    /// Clones `url` into `dest` (a folder that doesn't exist yet). Used before a repo window exists.
    static func clone(_ url: String, into dest: String) async throws {
        let parent = URL(fileURLWithPath: dest).deletingLastPathComponent()
        try await GitRunner.shared.run(["clone", url, dest], in: parent, logged: true)
    }

    // MARK: Merge / rebase in progress

    func continueOperation() async {
        switch operation {
        case .merge: await perform("Continue merge", ["commit", "--no-edit"])
        case .rebase: await perform("Continue rebase", ["rebase", "--continue"])
        case .cherryPick: await perform("Continue cherry-pick", ["cherry-pick", "--continue"])
        case .revert: await perform("Continue revert", ["revert", "--continue"])
        case nil: break
        }
    }

    func abortOperation() async {
        switch operation {
        case .merge: await perform("Abort merge", ["merge", "--abort"])
        case .rebase: await perform("Abort rebase", ["rebase", "--abort"])
        case .cherryPick: await perform("Abort cherry-pick", ["cherry-pick", "--abort"])
        case .revert: await perform("Abort revert", ["revert", "--abort"])
        case nil: break
        }
    }

    func skipRebaseCommit() async {
        await perform("Skip commit", ["rebase", "--skip"])
    }

    // MARK: Stash

    func stash(message: String) async {
        var args = ["stash", "push", "--include-untracked"]
        if !message.isEmpty { args += ["-m", message] }
        await perform("Stash", args)
    }

    func popStash(_ stash: Stash? = nil) async {
        await perform("Pop stash", ["stash", "pop"] + (stash.map { [$0.selector] } ?? []))
    }

    func applyStash(_ stash: Stash) async {
        await perform("Apply stash", ["stash", "apply", stash.selector])
    }

    func dropStash(_ stash: Stash) {
        confirmation = Confirmation(title: "Delete \(stash.selector)?", message: stash.message,
                                    confirmTitle: "Delete") { [weak self] in
            await self?.perform("Drop stash", ["stash", "drop", stash.selector])
        }
    }

    // MARK: Worktrees

    func addWorktree(path: String, newBranch: String?, base: String) async -> Bool {
        if let newBranch {
            // Like createBranch: a new branch started from a remote branch must
            // not track it (a bare `git push` would go to that branch), unless
            // it's the same branch checked out locally.
            let sameRemoteBranch = refs.contains { $0.kind == .remoteBranch && $0.name == base && $0.branchNameWithoutRemote == newBranch }
            return await perform("Add worktree", ["worktree", "add"] + (sameRemoteBranch ? [] : ["--no-track"])
                                    + ["-b", newBranch, path, base])
        }
        return await perform("Add worktree", ["worktree", "add", path, base])
    }

    func removeWorktree(_ wt: Worktree) {
        let dirty = (worktreeInfo[wt.path]?.changes ?? 0) > 0
        confirmation = Confirmation(
            title: "Remove worktree \(wt.displayName)?",
            message: dirty
                ? "It has uncommitted changes. They will be lost. The branch \(wt.branch ?? "") stays."
                : "Deletes the folder \(wt.path). The branch \(wt.branch ?? "") stays.",
            confirmTitle: "Remove"
        ) { [weak self] in
            await self?.perform("Remove worktree", ["worktree", "remove"] + (dirty ? ["--force"] : []) + [wt.path])
        }
    }

    func pruneWorktrees() async {
        await perform("Prune worktrees", ["worktree", "prune"])
    }

    /// Suggested folder for a new worktree: a sibling of the main checkout, `<repo>-<branch>`.
    func suggestedWorktreePath(branch: String) -> String {
        let main = URL(fileURLWithPath: mainWorktreePath ?? root.path)
        let safe = branch.replacingOccurrences(of: "/", with: "-")
        return main.deletingLastPathComponent().appendingPathComponent("\(main.lastPathComponent)-\(safe)").path
    }
}

// MARK: Opening things outside the app

enum External {
    static func open(app: String, path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", app, path]
        try? p.run()
    }

    static func openTerminal(_ path: String) { open(app: Prefs.terminalApp, path: path) }
    static func openEditor(_ path: String) { open(app: Prefs.editorApp, path: path) }
    static func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    static func browse(_ url: URL?) { if let url { NSWorkspace.shared.open(url) } }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
