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
            let top = cowork.tasks.filter { $0.status == .doing }.compactMap(\.rank).min()
            let me = cowork.me.email
            await cowork.updateTask(id) { t in
                t.branch = name
                if t.status == .backlog || t.status == .todo {
                    t.status = .doing
                    t.rank = (top ?? 0) - 1
                }
                if t.assignee == nil, !me.isEmpty { t.assignee = me }
            }
        }
    }
}
