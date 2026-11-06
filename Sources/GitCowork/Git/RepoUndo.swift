import Foundation
import GitCoworkCore

/// Edit > Undo for the last git action (one level per window). Which actions
/// count and how each is taken back is decided in GitCoworkCore (UndoRecord);
/// this records the state around each action and runs the undo as normal,
/// logged git commands.
extension RepoModel {
    /// Where HEAD is right now, read from git (the cached status may lag a
    /// change made in a terminal a moment ago).
    func currentHead() async -> HeadState {
        async let sha = git.tryRun(["rev-parse", "-q", "--verify", "HEAD"], in: root)
        async let branch = git.tryRun(["symbolic-ref", "-q", "--short", "HEAD"], in: root)
        func clean(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }
        return await HeadState(sha: clean(sha), branch: clean(branch))
    }

    /// Runs `args` like `perform`, and on success remembers how to take it back.
    @discardableResult
    func performUndoable(_ action: UndoRecord.Action, _ label: String, _ args: [String]) async -> Bool {
        guard busy == nil else { return await perform(label, args) }   // perform explains why not
        let before = await currentHead()
        guard await perform(label, args) else { return false }
        lastUndo = UndoRecord(action: action, before: before,
                              after: HeadState(sha: status.headOID, branch: status.branch),
                              afterChanges: status.changeKeys)
        return true
    }

    func recordDeletedBranch(_ ref: Ref) {
        let head = HeadState(sha: status.headOID, branch: status.branch)
        lastUndo = UndoRecord(action: .deleteBranch(name: ref.name, sha: ref.target, upstream: ref.upstream),
                              before: head, after: head)
    }

    var undoContext: UndoContext {
        UndoContext(head: HeadState(sha: status.headOID, branch: status.branch),
                    localBranches: Dictionary(localBranches.map { ($0.name, $0.target) }, uniquingKeysWith: { a, _ in a }),
                    remoteBranches: Set(remoteBranches.map(\.name)),
                    changes: status.changeKeys,
                    operationInProgress: operation != nil)
    }

    /// "Undo Commit" etc. when the last action can be taken back now, else nil.
    var undoTitle: String? {
        guard let record = lastUndo, record.check(in: undoContext).commands != nil else { return nil }
        return record.title
    }

    func undoLastAction() async {
        guard let record = lastUndo else { return }
        // Check against git itself, not the cached status.
        await refresh()
        lastUndo = nil
        switch record.check(in: undoContext) {
        case .blocked(let why):
            alert = AlertItem(title: "\(record.title) isn't possible anymore", message: why)
        case .ready(let commands):
            for args in commands {
                guard await perform(record.title, args) else { return }
            }
        }
    }
}
