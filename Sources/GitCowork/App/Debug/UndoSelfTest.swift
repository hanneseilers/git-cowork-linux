import AppKit
import Foundation
import GitCoworkCore

// Debug builds only (see DebugSnapshot.swift).
#if DEBUG

/// End-to-end check of Edit > Undo with real git, no UI:
///     GITCOWORK_UNDO_SELFTEST=/tmp/some-empty-dir .build/debug/GitCowork
/// Builds a throwaway repo and runs each undoable action through RepoModel,
/// then its undo, checking HEAD, branches and the working copy.
@MainActor
enum UndoSelfTest {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["GITCOWORK_UNDO_SELFTEST"] else { return }
        Task {
            let ok = await run(in: URL(fileURLWithPath: dir))
            print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
            exit(ok ? 0 : 1)
        }
    }

    private static var failures = 0

    private static func check(_ cond: Bool, _ what: String) {
        print((cond ? "  ok   " : "  FAIL ") + what)
        if !cond { failures += 1 }
    }

    @discardableResult
    private static func sh(_ args: [String], in dir: URL) async -> String {
        let r = await GitRunner.shared.execute(args, in: dir)
        if r.exitCode != 0 { print("  git \(args.joined(separator: " ")) -> \(r.stderr)") }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func write(_ text: String, _ name: String, in dir: URL) {
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// reset and deleteBranch run in their own Task; wait until `done` holds.
    private static func settle(_ model: RepoModel, until done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            try? await Task.sleep(for: .milliseconds(25))
        }
        while model.busy != nil { try? await Task.sleep(for: .milliseconds(25)) }
    }

    static func run(in dir: URL) async -> Bool {
        let fm = FileManager.default
        // Only ever delete a folder this test created itself (it holds a marker file).
        let marker = dir.appendingPathComponent(".git-cowork-undo-selftest")
        let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        if !contents.isEmpty {
            guard fm.fileExists(atPath: marker.path) else {
                print("Refusing to use \(dir.path): it isn't empty and wasn't created by the self-test.")
                return false
            }
            try? fm.removeItem(at: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fm.createFile(atPath: marker.path, contents: nil)
        let remote = dir.appendingPathComponent("remote.git")
        let repo = dir.appendingPathComponent("repo")

        await sh(["init", "-q", "--bare", "-b", "main", remote.path], in: dir)
        await sh(["init", "-q", "-b", "main", repo.path], in: dir)
        await sh(["config", "user.email", "test@x.com"], in: repo)
        await sh(["config", "user.name", "Test"], in: repo)
        await sh(["remote", "add", "origin", remote.path], in: repo)
        write("one\n", "a.txt", in: repo)
        await sh(["add", "."], in: repo)
        await sh(["commit", "-qm", "one"], in: repo)
        let c1 = await sh(["rev-parse", "HEAD"], in: repo)

        let model = RepoModel(root: repo)
        await model.load()
        func head() async -> String { await sh(["rev-parse", "HEAD"], in: repo) }
        func branch() async -> String { await sh(["branch", "--show-current"], in: repo) }

        print("1. commit and amend")
        write("two\n", "a.txt", in: repo)
        _ = await model.stageAll()
        _ = await model.commit(message: "two", amend: false)
        let c2 = await head()
        check(c2 != c1, "commit made")
        check(model.undoTitle == "Undo Commit", "menu reads Undo Commit")
        await model.undoLastAction()
        check(await head() == c1, "undo commit: branch back at previous tip")
        check(model.status.staged.map(\.path) == ["a.txt"], "undo commit: changes still staged")
        check(model.undoTitle == nil, "nothing left to undo")
        _ = await model.commit(message: "two", amend: false)
        let c2b = await head()
        _ = await model.commit(message: "two, amended", amend: true)
        check(model.undoTitle == "Undo Amend", "menu reads Undo Amend")
        await model.undoLastAction()
        check(await head() == c2b, "undo amend: back at the commit before amending")

        print("2. reset soft / mixed / hard")
        model.reset(to: c1, mode: .soft)
        await settle(model) { model.lastUndo != nil }
        check(await head() == c1, "soft reset moved the branch")
        check(model.undoTitle == "Undo Reset", "menu reads Undo Reset")
        await model.undoLastAction()
        check(await head() == c2b, "undo soft reset")
        check(model.status.isClean, "undo soft reset: working copy clean")

        model.reset(to: c1, mode: .mixed)
        await settle(model) { model.lastUndo != nil }
        await model.undoLastAction()
        check(await head() == c2b && model.status.isClean, "undo mixed reset")

        model.reset(to: c1, mode: .hard)
        await model.confirmation?.action()
        model.confirmation = nil
        check(await head() == c1, "hard reset moved the branch")
        check(model.undoTitle == "Undo Reset", "hard reset is undoable while the working copy is untouched")
        await model.undoLastAction()
        check(await head() == c2b, "undo hard reset")
        check((try? String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)) == "two\n", "undo hard reset: file content back")

        model.reset(to: c1, mode: .hard)
        await model.confirmation?.action()
        model.confirmation = nil
        write("new\n", "b.txt", in: repo)
        await model.refresh()
        check(model.undoTitle == nil, "hard reset not undoable after a new file was written")
        try? fm.removeItem(at: repo.appendingPathComponent("b.txt"))
        await sh(["reset", "-q", "--hard", c2b], in: repo)
        await model.refresh()

        print("3. checkout")
        await sh(["branch", "dev", c1], in: repo)
        await model.refresh()
        guard let dev = model.localBranches.first(where: { $0.name == "dev" }) else { check(false, "dev branch"); return false }
        await model.checkout(dev)
        check(await branch() == "dev", "checked out dev")
        check(model.undoTitle == "Undo Checkout", "menu reads Undo Checkout")
        await model.undoLastAction()
        check(await branch() == "main", "undo checkout: back on main")
        await model.checkoutCommit(c1)
        await model.undoLastAction()
        check(await branch() == "main", "undo detached checkout: back on main")

        print("4. delete branch")
        await sh(["push", "-q", "-u", "origin", "dev"], in: repo)
        await sh(["fetch", "-q", "origin"], in: repo)
        await model.refresh()
        guard let devRef = model.localBranches.first(where: { $0.name == "dev" }) else { check(false, "dev branch"); return false }
        model.deleteBranch(devRef)    // merged into main: deleted without asking
        await settle(model) { model.lastUndo != nil }
        check(!model.localBranches.contains { $0.name == "dev" }, "dev deleted")
        check(model.undoTitle == "Undo Delete Branch", "menu reads Undo Delete Branch")
        await model.undoLastAction()
        check(await sh(["rev-parse", "dev"], in: repo) == c1, "undo delete: dev back at its old commit")
        check(await sh(["rev-parse", "--abbrev-ref", "dev@{upstream}"], in: repo) == "origin/dev", "undo delete: upstream restored")

        await sh(["switch", "-q", "-c", "wip"], in: repo)
        write("wip\n", "c.txt", in: repo)
        await sh(["add", "."], in: repo)
        await sh(["commit", "-qm", "wip"], in: repo)
        let wipSHA = await head()
        await sh(["switch", "-q", "main"], in: repo)
        await model.refresh()
        guard let wip = model.localBranches.first(where: { $0.name == "wip" }) else { check(false, "wip branch"); return false }
        model.deleteBranch(wip)       // not merged: asks first
        await settle(model) { model.confirmation != nil }
        await model.confirmation?.action()
        model.confirmation = nil
        check(!model.localBranches.contains { $0.name == "wip" }, "unmerged wip deleted")
        await model.undoLastAction()
        check(await sh(["rev-parse", "wip"], in: repo) == wipSHA, "undo delete unmerged: wip back")

        print("5. push drops the undo")
        write("three\n", "a.txt", in: repo)
        _ = await model.stageAll()
        _ = await model.commit(message: "three", amend: false)
        check(model.undoTitle == "Undo Commit", "commit undoable before pushing")
        await model.push()
        check(model.undoTitle == nil, "no undo after push")

        let log = CommandLog.shared.entries.map(\.commandLine)
        check(log.contains("git reset --soft \(c1)"), "undo shows in the command log")
        model.stopWatching()
        return failures == 0
    }
}

#endif
