import Foundation
import Testing
import CoworkKit
import GitCoworkCore

// Two teammates (anna, ben) with clones of one bare remote, syncing the
// cowork ref with real git. Same scenarios as the app's self-test, as tests.

private struct Team {
    let dir: URL
    let anna: CoworkRepo
    let ben: CoworkRepo
    let git = ProcessGit()

    init() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gc-kit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let git = ProcessGit()
        func run(_ args: [String], in d: URL) async throws {
            let r = await git.git(args, in: d)
            guard r.ok else { throw CoworkRepo.Failure("git \(args.joined(separator: " ")): \(r.errorText)") }
        }
        let remote = dir.appendingPathComponent("remote.git")
        let a = dir.appendingPathComponent("anna"), b = dir.appendingPathComponent("ben")
        try await run(["init", "-q", "--bare", "-b", "main", remote.path], in: dir)
        try await run(["clone", "-q", remote.path, a.path], in: dir)
        try "hello\n".write(to: a.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await run(["add", "."], in: a)
        try await run(["-c", "user.name=Anna", "-c", "user.email=anna@x.com", "commit", "-qm", "init"], in: a)
        try await run(["push", "-q", "origin", "main"], in: a)
        try await run(["clone", "-q", remote.path, b.path], in: dir)
        anna = CoworkRepo(root: a, git: git, me: TeamMember(handle: "anna", name: "Anna", email: "anna@x.com"))
        ben = CoworkRepo(root: b, git: git, me: TeamMember(handle: "ben", name: "Ben", email: "ben@x.com"))
    }
}

@Suite struct CoworkRepoTests {
    @Test func taskReachesTeammate() async throws {
        let team = try await Team()
        let (t, edit) = CoworkEdit.newTask(title: "Cache sessions", status: .todo, body: "@ben please",
                                           author: "anna@x.com", in: CoworkSnapshot())
        try await team.anna.apply(edit)
        #expect(try await team.anna.sync(remote: "origin"))
        #expect(try await team.ben.sync(remote: "origin"))
        let seen = await team.ben.snapshot().tasks.first { $0.id == t.id }
        #expect(seen?.title == "Cache sessions")
        let inbox = CoworkInbox.items(for: "ben@x.com", in: await team.ben.snapshot(), knownEmails: ["anna@x.com"])
        #expect(inbox.contains { $0.kind == .mention })
    }

    @Test func concurrentEditsAndCommentsMerge() async throws {
        let team = try await Team()
        let (t, edit) = CoworkEdit.newTask(title: "T", status: .todo, author: "anna@x.com", in: CoworkSnapshot())
        try await team.anna.apply(edit)
        try await team.anna.sync(remote: "origin")
        try await team.ben.sync(remote: "origin")

        // Both edit the same task (different fields) and comment, without syncing in between.
        try await team.anna.apply(CoworkEdit.updateTasks([t.id: { $0.status = .doing }], message: "a"))
        try await team.ben.apply(CoworkEdit.updateTasks([t.id: { $0.assignee = "ben@x.com" }], message: "b",
                                                        now: Date().addingTimeInterval(1)))
        try await team.anna.apply(CoworkEdit.comment(on: t.commentParent, body: "on it", by: team.anna.me).1)
        try await team.ben.apply(CoworkEdit.comment(on: t.commentParent, body: "me too", by: team.ben.me).1)

        try await team.anna.sync(remote: "origin")
        try await team.ben.sync(remote: "origin")     // diverged: merges
        try await team.anna.sync(remote: "origin")
        for repo in [team.anna, team.ben] {
            let snap = await repo.snapshot()
            let task = snap.tasks.first { $0.id == t.id }
            #expect(task?.status == .doing && task?.assignee == "ben@x.com")
            #expect(snap.comments[t.commentParent]?.count == 2)
        }
    }

    @Test func simultaneousApprovalsBothCount() async throws {
        let team = try await Team()
        let (r, edit) = CoworkEdit.requestReview(branch: "feat/x", base: "main", title: "X",
                                                 reviewers: ["anna@x.com", "ben@x.com"], body: "", taskID: nil,
                                                 requester: "carl@x.com", in: CoworkSnapshot())
        try await team.anna.apply(edit)
        try await team.anna.sync(remote: "origin")
        try await team.ben.sync(remote: "origin")
        try await team.anna.apply(CoworkEdit.verdict(.approved, on: r, comment: "", by: team.anna.me))
        try await team.ben.apply(CoworkEdit.verdict(.approved, on: r, comment: "LGTM", by: team.ben.me))
        try await team.anna.sync(remote: "origin")
        try await team.ben.sync(remote: "origin")
        try await team.anna.sync(remote: "origin")
        let merged = await team.anna.snapshot().reviews.first { $0.id == r.id }
        #expect(merged?.overall == .approved)
        #expect(await team.anna.snapshot().comments[r.commentParent]?.count == 1)
    }

    @Test func neverTouchesWorkingTreeOrHEAD() async throws {
        let team = try await Team()
        let root = team.ben.root
        try "wip\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let head = await team.git.git(["rev-parse", "HEAD"], in: root).line
        try await team.ben.apply(CoworkEdit.newTask(title: "T", author: "ben@x.com", in: CoworkSnapshot()).1)
        try await team.ben.sync(remote: "origin")
        #expect(await team.git.git(["rev-parse", "HEAD"], in: root).line == head)
        #expect(await team.git.git(["status", "--porcelain"], in: root).line == "M README.md")
        #expect(!(await team.git.git(["branch", "-a"], in: root).text.contains("cowork")))
    }

    @Test func unchangedEditWritesNothing() async throws {
        let team = try await Team()
        let (t, edit) = CoworkEdit.newTask(title: "T", status: .todo, author: "anna@x.com", in: CoworkSnapshot())
        try await team.anna.apply(edit)
        let tip = await team.anna.tip()
        let wrote = try await team.anna.apply(CoworkEdit.updateTasks([t.id: { $0.status = .todo }], message: "noop"))
        #expect(!wrote)
        #expect(await team.anna.tip() == tip)
    }
}
