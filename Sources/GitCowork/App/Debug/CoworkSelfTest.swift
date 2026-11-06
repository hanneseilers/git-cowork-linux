import AppKit
import Foundation
import GitCoworkCore

// Debug builds only (see DebugSnapshot.swift).
#if DEBUG

/// End-to-end check of cowork sync with real git, no UI:
///     GITCOWORK_SELFTEST=/tmp/some-empty-dir .build/debug/GitCowork
/// Creates a bare remote and two clones ("anna" and "ben"), makes
/// concurrent, conflicting edits, syncs, and checks nothing was lost.
@MainActor
enum CoworkSelfTest {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["GITCOWORK_SELFTEST"] else { return }
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

    private static func sh(_ args: [String], in dir: URL) async -> String {
        let r = await GitRunner.shared.execute(args, in: dir)
        if r.exitCode != 0 { print("  git \(args.joined(separator: " ")) -> \(r.stderr)") }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func run(in dir: URL) async -> Bool {
        let fm = FileManager.default
        // Only ever delete a folder this test created itself (it holds a marker file).
        let marker = dir.appendingPathComponent(".git-cowork-selftest")
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
        let a = dir.appendingPathComponent("anna"), b = dir.appendingPathComponent("ben")

        _ = await sh(["init", "-q", "--bare", "-b", "main", remote.path], in: dir)
        _ = await sh(["clone", "-q", remote.path, a.path], in: dir)
        for (repo, name) in [(a, "anna"), (b, "ben")] where repo == a {
            _ = await sh(["config", "user.email", "\(name)@x.com"], in: repo)
            _ = await sh(["config", "user.name", name.capitalized], in: repo)
        }
        try? "hello\n".write(to: a.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = await sh(["add", "."], in: a)
        _ = await sh(["commit", "-qm", "init"], in: a)
        _ = await sh(["push", "-q", "origin", "main"], in: a)
        _ = await sh(["clone", "-q", remote.path, b.path], in: dir)
        _ = await sh(["config", "user.email", "ben@x.com"], in: b)
        _ = await sh(["config", "user.name", "Ben"], in: b)
        // Uncommitted work that must survive untouched.
        try? "wip\n".write(to: b.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let headBefore = await sh(["rev-parse", "HEAD"], in: b)

        let anna = CoworkStore(root: a), ben = CoworkStore(root: b)
        anna.remote = "origin"; ben.remote = "origin"
        await anna.load(); await ben.load()

        print("1. create and share a task")
        guard let task = await anna.createTask(title: "Cache sessions", status: .todo, body: "Please check @ben") else {
            check(false, "create task"); return false
        }
        await anna.sync()
        await ben.sync()
        check(ben.task(task.id)?.title == "Cache sessions", "ben sees anna's task")
        check(ben.inbox.contains { $0.kind == .mention }, "ben's inbox has the @mention")

        print("2. concurrent edits to the same task (offline)")
        anna.remote = nil; ben.remote = nil            // no auto-push in between
        await anna.updateTask(task.id) { $0.status = .doing }
        try? await Task.sleep(for: .milliseconds(1100))
        await ben.updateTask(task.id) { $0.assignee = "ben@x.com" }
        await anna.addComment(on: task.commentParent, body: "on it")
        await ben.addComment(on: task.commentParent, body: "me too")
        anna.remote = "origin"; ben.remote = "origin"
        await anna.sync()
        await ben.sync()      // diverged: merges
        await anna.sync()
        let fa = anna.task(task.id), fb = ben.task(task.id)
        check(fa?.status == .doing && fa?.assignee == "ben@x.com", "anna has both field changes")
        check(fb?.status == .doing && fb?.assignee == "ben@x.com", "ben has both field changes")
        check(anna.comments(on: task.commentParent).count == 2 && ben.comments(on: task.commentParent).count == 2, "both comments kept")

        print("3. review request with two concurrent approvals")
        guard let review = await anna.requestReview(branch: "feat/cache", base: "main", title: "Cache",
                                                    reviewers: ["ben@x.com", "anna2@x.com"], body: "", taskID: task.id) else {
            check(false, "request review"); return false
        }
        await anna.sync(); await ben.sync()
        check(ben.inbox.contains { $0.kind == .reviewRequested }, "ben's inbox has the review request")
        check(ben.task(task.id)?.status == .review, "linked task moved to In Review")
        anna.remote = nil; ben.remote = nil
        await ben.setVerdict(.approved, on: ben.review(review.id)!, comment: "LGTM")
        // Simulate the second reviewer approving from anna's clone at the same time.
        await anna.updateReview(review.id) { $0.reviewers["anna2@x.com"] = .approved }
        anna.remote = "origin"; ben.remote = "origin"
        await anna.sync(); await ben.sync(); await anna.sync()
        check(anna.review(review.id)?.overall == .approved, "both approvals survive the merge")
        check(anna.inbox.contains { $0.kind == .reviewVerdict }, "anna's inbox shows ben's approval")

        print("4b. start a task in its own worktree")
        let repoModel = RepoModel(root: a)
        await repoModel.load()
        if let wtTask = await anna.createTask(title: "Agent: tidy logging", status: .todo) {
            // Saves are queued: wait until the commit has landed and this window sees it.
            for _ in 0..<50 where repoModel.cowork.task(wtTask.id) == nil {
                try? await Task.sleep(for: .milliseconds(100))
                await repoModel.cowork.reload()
            }
            let path = await repoModel.startTaskInWorktree(wtTask.id)
            if path == nil {
                print("  (task visible: \(repoModel.cowork.task(wtTask.id) != nil), busy: \(repoModel.busy ?? "-"), alert: \(repoModel.alert?.message ?? "-"))")
            }
            await repoModel.refresh()
            let branch = RefName.branch(for: wtTask)
            check(path.map { fm.fileExists(atPath: $0) } == true, "worktree folder created")
            check(repoModel.worktrees.contains { $0.branch == branch }, "worktree on branch \(branch)")
            let started = repoModel.cowork.task(wtTask.id)
            check(started?.branch == branch && started?.status == .doing, "task linked and In Progress")
            check(await repoModel.startTaskInWorktree(wtTask.id) == path, "second click reuses the worktree")
            if let path { _ = await sh(["worktree", "remove", "--force", path], in: a) }
        } else {
            check(false, "create task for worktree")
        }
        repoModel.stopWatching()

        print("4. nothing else touched")
        check(await sh(["rev-parse", "HEAD"], in: b) == headBefore, "HEAD unchanged")
        check(await sh(["status", "--porcelain"], in: b) == "M README.md", "working tree change still there, nothing staged")
        check(await sh(["branch", "-a"], in: b).contains("cowork") == false, "no cowork branches visible")
        check(anna.syncError == nil && ben.syncError == nil, "no sync errors (\(anna.syncError ?? "")\(ben.syncError ?? ""))")

        print("5. quick successive edits and a stale second window")
        anna.remote = nil
        guard let lt = await anna.createTask(title: "Labels", labels: ["a", "b", "c"]) else {
            check(false, "create label task"); return false
        }
        async let x: Bool = anna.updateTask(lt.id) { $0.labels.removeAll { $0 == "a" } }
        async let y: Bool = anna.updateTask(lt.id) { $0.labels.removeAll { $0 == "b" } }
        _ = await (x, y)
        check(anna.task(lt.id)?.labels == ["c"], "two quick label removals both stick (\(anna.task(lt.id)?.labels ?? []))")
        let window2 = CoworkStore(root: a)
        await window2.load()
        await anna.updateTask(lt.id) { $0.status = .done }
        await window2.updateTask(lt.id) { $0.title = "Renamed" }   // window2 hasn't seen the status change
        await anna.reload()
        check(anna.task(lt.id)?.status == .done && anna.task(lt.id)?.title == "Renamed", "stale window keeps the other window's change")
        await anna.deleteTask(anna.task(lt.id)!)
        await window2.updateTask(lt.id) { $0.title = "Again" }
        await anna.reload()
        check(anna.task(lt.id) == nil, "stale edit doesn't bring back a deleted task")
        anna.remote = "origin"
        await anna.sync()
        check(anna.syncError == nil, "sync after local edits (\(anna.syncError ?? ""))")

        if ProcessInfo.processInfo.environment["GITCOWORK_SELFTEST_SEED"] != nil { await seed(anna) }
        return failures == 0
    }

    /// Extra demo tasks so the board has something to show (GITCOWORK_SELFTEST_SEED=1).
    private static func seed(_ s: CoworkStore) async {
        let items: [(String, TaskStatus, String?, [String])] = [
            ("Rate-limit the public API", .todo, "ben@x.com", ["backend"]),
            ("Dark mode for the settings page", .backlog, nil, ["frontend", "design"]),
            ("Flaky test: webhook retries", .doing, "anna@x.com", ["ci"]),
            ("Migrate billing to the new provider", .backlog, "ben@x.com", ["backend", "billing"]),
            ("Write onboarding docs for agents", .todo, "anna@x.com", ["docs"]),
            ("Release 1.8.6", .done, "anna@x.com", ["release"]),
            ("Remove the legacy session store", .review, "ben@x.com", ["backend"]),
            ("Spike: WebRTC fallback", .backlog, nil, ["research"]),
        ]
        for (title, status, assignee, labels) in items {
            await s.createTask(title: title, status: status, assignee: assignee, labels: labels,
                               body: "Context and acceptance criteria go here. @ben please have a look.")
        }
        await s.saveTeam([TeamMember(handle: "anna", name: "Anna Berg", email: "anna@x.com"),
                          TeamMember(handle: "ben", name: "Ben Ortiz", email: "ben@x.com")])
        await s.sync()
    }
}

#endif
