import Foundation
import Testing
@testable import GitCoworkCore

private let a = String(repeating: "a", count: 40)
private let b = String(repeating: "b", count: 40)
private let c = String(repeating: "c", count: 40)

private func head(_ sha: String?, _ branch: String? = "main") -> HeadState { HeadState(sha: sha, branch: branch) }

@Suite struct UndoRecordTests {
    @Test func commitUndoesWithSoftReset() throws {
        let r = try #require(UndoRecord(action: .commit, before: head(a), after: head(b)))
        #expect(r.title == "Undo Commit")
        #expect(r.check(in: UndoContext(head: head(b))) == .ready([["reset", "--soft", a]]))
    }

    @Test func amendUndoesWithSoftReset() throws {
        let r = try #require(UndoRecord(action: .amend, before: head(a), after: head(b)))
        #expect(r.title == "Undo Amend")
        #expect(r.check(in: UndoContext(head: head(b))).commands == [["reset", "--soft", a]])
    }

    @Test func firstCommitIsNotUndoable() {
        #expect(UndoRecord(action: .commit, before: head(nil), after: head(a)) == nil)
    }

    @Test func actionsThatDidNotMoveHeadAreNotRecorded() {
        #expect(UndoRecord(action: .commit, before: head(a), after: head(a)) == nil)
        #expect(UndoRecord(action: .reset(.hard), before: head(a), after: head(a)) == nil)
        #expect(UndoRecord(action: .checkout, before: head(a), after: head(a)) == nil)
    }

    @Test func commitOnOtherBranchIsNotRecorded() {
        #expect(UndoRecord(action: .commit, before: head(a, "main"), after: head(b, "dev")) == nil)
    }

    @Test func blockedOnceHeadMoves() throws {
        let r = try #require(UndoRecord(action: .commit, before: head(a), after: head(b)))
        #expect(r.check(in: UndoContext(head: head(c))).commands == nil)          // new commit since
        #expect(r.check(in: UndoContext(head: head(b, "dev"))).commands == nil)   // switched branch
        #expect(r.check(in: UndoContext(head: head(b, nil))).commands == nil)     // detached
    }

    @Test func blockedDuringMergeOrRebase() throws {
        let r = try #require(UndoRecord(action: .commit, before: head(a), after: head(b)))
        #expect(r.check(in: UndoContext(head: head(b), operationInProgress: true)).commands == nil)
    }

    @Test func softAndMixedResetGoBackToOldTip() throws {
        let soft = try #require(UndoRecord(action: .reset(.soft), before: head(b), after: head(a)))
        let mixed = try #require(UndoRecord(action: .reset(.mixed), before: head(b), after: head(a)))
        // Working copy edits since don't matter: these resets never touch it.
        let ctx = UndoContext(head: head(a), changes: ["unstaged:M:x.txt"])
        #expect(soft.title == "Undo Reset")
        #expect(soft.check(in: ctx) == .ready([["reset", "--soft", b]]))
        #expect(mixed.check(in: ctx) == .ready([["reset", "--mixed", b]]))
    }

    @Test func hardResetOnlyWhileWorkingCopyIsUntouched() throws {
        let left: Set<String> = ["untracked:?:notes.txt"]
        let r = try #require(UndoRecord(action: .reset(.hard), before: head(b), after: head(a), afterChanges: left))
        #expect(r.check(in: UndoContext(head: head(a), changes: left)) == .ready([["reset", "--hard", b]]))
        // A file edited or created since would be overwritten: no undo.
        #expect(r.check(in: UndoContext(head: head(a), changes: left.union(["unstaged:M:x.txt"]))).commands == nil)
        #expect(r.check(in: UndoContext(head: head(a), changes: [])).commands == nil)
    }

    @Test func checkoutSwitchesBackToPreviousBranch() throws {
        let r = try #require(UndoRecord(action: .checkout, before: head(a, "main"), after: head(b, "dev")))
        #expect(r.title == "Undo Checkout")
        #expect(r.check(in: UndoContext(head: head(b, "dev"), localBranches: ["main": a, "dev": b]))
                == .ready([["switch", "main"]]))
        // Previous branch deleted since.
        #expect(r.check(in: UndoContext(head: head(b, "dev"), localBranches: ["dev": b])).commands == nil)
    }

    @Test func checkoutFromDetachedGoesBackToThatCommit() throws {
        let r = try #require(UndoRecord(action: .checkout, before: head(a, nil), after: head(a, "main")))
        #expect(r.check(in: UndoContext(head: head(a, "main"))) == .ready([["switch", "--detach", a]]))
    }

    @Test func deletedBranchIsRecreatedAtOldSHA() throws {
        let r = try #require(UndoRecord(action: .deleteBranch(name: "dev", sha: b, upstream: "origin/dev"),
                                        before: head(a), after: head(a)))
        #expect(r.title == "Undo Delete Branch")
        #expect(r.check(in: UndoContext(head: head(a), remoteBranches: ["origin/dev"]))
                == .ready([["branch", "--no-track", "dev", b], ["branch", "--set-upstream-to=origin/dev", "dev"]]))
        // Upstream gone: recreate without it.
        #expect(r.check(in: UndoContext(head: head(a))) == .ready([["branch", "--no-track", "dev", b]]))
        // HEAD moving doesn't matter for a branch that isn't checked out.
        #expect(r.check(in: UndoContext(head: head(c))).commands != nil)
    }

    @Test func deletedBranchBlockedWhenNameIsTakenAgain() throws {
        let r = try #require(UndoRecord(action: .deleteBranch(name: "dev", sha: b, upstream: nil), before: head(a), after: head(a)))
        #expect(r.check(in: UndoContext(head: head(a), localBranches: ["dev": c])).commands == nil)
    }

    @Test func pushAndHistoryChangesDropTheUndo() {
        #expect(!UndoRecord.survives(["push"]))
        #expect(!UndoRecord.survives(["push", "origin", "--delete", "dev"]))
        #expect(!UndoRecord.survives(["pull", "--rebase"]))
        #expect(!UndoRecord.survives(["merge", "dev"]))
        #expect(!UndoRecord.survives(["branch", "-m", "a", "b"]))
        #expect(UndoRecord.survives(["add", "--", "x"]))
        #expect(UndoRecord.survives(["fetch", "--all", "--prune"]))
        #expect(UndoRecord.survives(["stash", "push"]))
    }

    @Test func changeKeysCoverEveryArea() {
        var st = WorkingStatus()
        st.staged = [FileChange(path: "a", status: .modified, area: .staged)]
        st.unstaged = [FileChange(path: "a", status: .modified, area: .unstaged)]
        st.untracked = [FileChange(path: "n", status: .untracked, area: .untracked)]
        #expect(st.changeKeys == ["staged:M:a", "unstaged:M:a", "untracked:?:n"])
    }
}
