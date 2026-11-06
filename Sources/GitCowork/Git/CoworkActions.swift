import Foundation
import GitCoworkCore

/// Cowork actions that also touch git (branches for tasks).
extension RepoModel {
    /// The local or remote branch a task is linked to, if it exists here.
    func linkedBranch(of task: CoworkTask) -> Ref? {
        guard let b = task.branch, !b.isEmpty else { return nil }
        return localBranch(named: b) ?? remoteBranch(named: b)
    }

    /// "Start Task": checks out the task's branch (an existing local one, else
    /// tracking the remote one, else a new one from the base branch), links
    /// it, moves the task to In Progress and assigns it to me.
    func startTask(_ id: String) {
        guard let t = cowork.task(id) else { return }
        if let ref = linkedBranch(of: t) {
            Task { await checkout(ref) }
            return
        }
        let name = (t.branch?.isEmpty == false ? t.branch : nil) ?? RefName.branch(for: t)
        let args: [String]
        if localBranch(named: name) != nil {
            args = ["switch", name]
        } else if let remote = defaultRemote, remoteBranches.contains(where: { $0.name == "\(remote)/\(name)" }) {
            args = ["switch", "--track", "\(remote)/\(name)"]
        } else {
            // --no-track: a new task branch must not push to the base branch.
            args = ["switch", "-c", name, "--no-track", baseBranch()?.ref ?? currentBranch ?? "HEAD"]
        }
        Task {
            guard await perform("Start task", args) else { return }
            await markStarted(id, branch: name)
        }
    }

    /// The worktree that has the task's branch checked out, if any.
    func worktree(of task: CoworkTask) -> Worktree? {
        guard let b = task.branch, !b.isEmpty else { return nil }
        return worktrees.first { $0.branch == b }
    }

    /// "Start in New Worktree": gives the task its own folder (next to the
    /// main checkout) on its own branch, so an agent or a second person can
    /// work on it without touching this checkout. Calls `open` with the new
    /// folder, e.g. to show it in a new tab. Reuses an existing worktree.
    func startTaskInWorktree(_ id: String, open: @escaping (String) -> Void) {
        Task { if let path = await startTaskInWorktree(id) { open(path) } }
    }

    /// Returns the worktree folder, or nil if it couldn't be created.
    func startTaskInWorktree(_ id: String) async -> String? {
        guard let t = cowork.task(id) else { return nil }
        if let wt = worktree(of: t) { return wt.path }
        let name = (t.branch?.isEmpty == false ? t.branch : nil) ?? RefName.branch(for: t)
        let path = suggestedWorktreePath(branch: name)
        let ok: Bool
        if localBranch(named: name) != nil {
            ok = await addWorktree(path: path, newBranch: nil, base: name)
        } else if let remote = remoteBranch(named: name) {
            ok = await addWorktree(path: path, newBranch: name, base: remote.name)
        } else {
            ok = await addWorktree(path: path, newBranch: name, base: baseBranch()?.ref ?? currentBranch ?? "HEAD")
        }
        guard ok else { return nil }
        await markStarted(id, branch: name)
        return path
    }

    /// Links the branch, moves the task to In Progress (top of the column)
    /// and assigns it to me if nobody has it.
    private func markStarted(_ id: String, branch: String) async {
        let top = cowork.tasks.filter { $0.status == .doing }.compactMap(\.rank).min()
        let me = cowork.me.email
        await cowork.updateTask(id) { t in
            t.branch = branch
            if t.status == .backlog || t.status == .todo {
                t.status = .doing
                t.rank = (top ?? 0) - 1
            }
            if t.assignee == nil, !me.isEmpty { t.assignee = me }
        }
    }
}
