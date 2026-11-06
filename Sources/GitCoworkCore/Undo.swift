import Foundation

public enum ResetMode: String, CaseIterable, Sendable {
    case soft, mixed, hard
}

/// Where HEAD points: the commit, and the branch when one is checked out.
public struct HeadState: Hashable, Sendable {
    public var sha: String?      // nil before the first commit
    public var branch: String?   // nil when detached

    public init(sha: String?, branch: String?) {
        self.sha = sha
        self.branch = branch
    }
}

/// One git action that Edit > Undo can take back. Holds what the repo looked
/// like before the action and what the action left, so a later check can tell
/// whether the repo has moved on since.
public struct UndoRecord: Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        case commit
        case amend
        case reset(ResetMode)
        case checkout
        /// A local branch, with the commit it pointed at and its upstream.
        case deleteBranch(name: String, sha: String, upstream: String?)
    }

    public let action: Action
    public let before: HeadState
    public let after: HeadState
    /// Working copy right after the action (see `WorkingStatus.changeKeys`).
    /// A hard reset can only be undone while this is unchanged.
    public let afterChanges: Set<String>

    /// Nil when the action left nothing that can be taken back safely:
    /// HEAD didn't move, the commit was the first one, or the branch changed
    /// underneath (which these actions never do).
    public init?(action: Action, before: HeadState, after: HeadState, afterChanges: Set<String> = []) {
        switch action {
        case .commit, .amend, .reset:
            guard before.sha != nil, after.sha != nil, before.sha != after.sha,
                  before.branch == after.branch else { return nil }
        case .checkout:
            guard before.sha != nil, before != after else { return nil }
        case .deleteBranch:
            break
        }
        self.action = action
        self.before = before
        self.after = after
        self.afterChanges = afterChanges
    }

    /// Edit menu title, e.g. "Undo Commit".
    public var title: String {
        switch action {
        case .commit: "Undo Commit"
        case .amend: "Undo Amend"
        case .reset: "Undo Reset"
        case .checkout: "Undo Checkout"
        case .deleteBranch: "Undo Delete Branch"
        }
    }

    /// The git commands that take the action back, or why it can't be now.
    public func check(in repo: UndoContext) -> UndoCheck {
        if case .deleteBranch(let name, let sha, let upstream) = action {
            guard repo.localBranches[name] == nil else { return .blocked("A branch named \(name) exists again.") }
            var commands = [["branch", "--no-track", name, sha]]
            if let upstream, repo.remoteBranches.contains(upstream) {
                commands.append(["branch", "--set-upstream-to=\(upstream)", name])
            }
            return .ready(commands)
        }

        // Everything else moved HEAD: only undo while HEAD is still where it was left.
        guard repo.head == after else { return .blocked("HEAD moved since.") }
        guard !repo.operationInProgress else { return .blocked("A merge, rebase, cherry-pick or revert is in progress.") }
        guard let old = before.sha else { return .blocked("Nothing to go back to.") }

        switch action {
        case .commit, .amend:
            // Back to the previous tip; the commit's changes stay staged.
            return .ready([["reset", "--soft", old]])
        case .reset(let mode):
            switch mode {
            case .soft:
                return .ready([["reset", "--soft", old]])
            case .mixed:
                // The working tree still has the old content; match the index to it.
                return .ready([["reset", "--mixed", old]])
            case .hard:
                // reset --hard would overwrite anything written since.
                guard repo.changes == afterChanges else { return .blocked("The working copy changed since the reset.") }
                return .ready([["reset", "--hard", old]])
            }
        case .checkout:
            if let branch = before.branch {
                guard repo.localBranches[branch] != nil else { return .blocked("\(branch) no longer exists.") }
                return .ready([["switch", branch]])
            }
            return .ready([["switch", "--detach", old]])
        case .deleteBranch:
            return .blocked("")   // handled above
        }
    }

    /// Whether a recorded undo stays valid after the app ran `args` (a command
    /// that changes the repo). Commands that only touch the index, the working
    /// copy, stashes, tags or remote-tracking refs keep it; the undo's own
    /// checks cover what they change. Everything else drops it, above all push:
    /// once a commit is on the remote, taking it back is no longer local.
    public static func survives(_ args: [String]) -> Bool {
        guard let cmd = args.first else { return true }
        return ["add", "restore", "rm", "apply", "clean", "stash", "tag", "fetch", "checkout"].contains(cmd)
    }
}

/// The parts of the repo an undo check looks at.
public struct UndoContext: Sendable {
    public var head: HeadState
    public var localBranches: [String: String]   // name -> sha
    public var remoteBranches: Set<String>        // origin/main
    public var changes: Set<String>               // WorkingStatus.changeKeys
    public var operationInProgress: Bool

    public init(head: HeadState, localBranches: [String: String] = [:], remoteBranches: Set<String> = [],
                changes: Set<String> = [], operationInProgress: Bool = false) {
        self.head = head
        self.localBranches = localBranches
        self.remoteBranches = remoteBranches
        self.changes = changes
        self.operationInProgress = operationInProgress
    }
}

public enum UndoCheck: Equatable, Sendable {
    /// git commands to run in order.
    case ready([[String]])
    case blocked(String)

    public var commands: [[String]]? {
        if case .ready(let c) = self { return c }
        return nil
    }
}

extension WorkingStatus {
    /// Every change as "area:status:path", for telling whether the working
    /// copy changed between two moments.
    public var changeKeys: Set<String> {
        Set((staged + unstaged + untracked + conflicted).map { "\($0.area.rawValue):\($0.status.rawValue):\($0.path)" })
    }
}
