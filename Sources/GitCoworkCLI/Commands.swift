import CoworkKit
import Foundation
import GitCoworkCore

/// One run of `git cowork <command>`.
struct Commands {
    let args: Args
    let repo: CoworkRepo
    let remote: String?
    var json: Bool { args.flag("json") }

    // MARK: Reading

    func list() async throws {
        if args.flag("sync") { await syncQuietly() }
        let snap = await repo.snapshot()
        var tasks = snap.tasks
        if let s = args.value("status") {
            let status = try Self.status(s)
            tasks = tasks.filter { $0.status == status }
        } else if !args.flag("all") {
            tasks = tasks.filter { $0.status != .done }
        }
        if args.flag("mine") { tasks = tasks.filter { $0.assignee?.lowercased() == repo.me.id } }
        if let a = args.value("assignee") {
            let email = resolve(a)
            tasks = tasks.filter { $0.assignee?.lowercased() == email?.lowercased() }
        }
        for l in args.all("label") { tasks = tasks.filter { $0.labels.contains(l) } }
        tasks.sort { ($0.status.order, $0.rank ?? .greatestFiniteMagnitude, $1.updated) < ($1.status.order, $1.rank ?? .greatestFiniteMagnitude, $0.updated) }
        if json { return Output.json(tasks.map { Output.task($0) }) }
        if tasks.isEmpty { print("No tasks."); return }
        tasks.forEach { print(Output.taskLine($0)) }
    }

    func show() async throws {
        if args.flag("sync") { await syncQuietly() }
        let id = try args.arg(1, "task or review id")
        let snap = await repo.snapshot()
        if let t = snap.tasks.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
            let comments = snap.comments[t.commentParent] ?? []
            return json ? Output.json(Output.task(t, comments: comments)) : Output.showTask(t, comments: comments)
        }
        if let r = snap.reviews.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
            let comments = snap.comments[r.commentParent] ?? []
            return json ? Output.json(Output.review(r, comments: comments)) : Output.showReview(r, comments: comments)
        }
        throw CLIError.failed("No task or review \(id).")
    }

    func reviews() async throws {
        if args.flag("sync") { await syncQuietly() }
        var list = await repo.snapshot().reviews
        let me = repo.me.id
        if args.flag("waiting") {
            list = list.filter { $0.status == .open && $0.reviewers.contains { $0.key.lowercased() == me && $0.value == .requested } }
        } else if args.flag("mine") {
            list = list.filter { $0.requester.lowercased() == me }
        } else if !args.flag("all") {
            list = list.filter { $0.status == .open }
        }
        list.sort { $0.updated > $1.updated }
        if json { return Output.json(list.map { Output.review($0) }) }
        if list.isEmpty { print("No reviews."); return }
        list.forEach { print(Output.reviewLine($0)) }
    }

    func inbox() async throws {
        if args.flag("sync") { await syncQuietly() }
        let snap = await repo.snapshot()
        let known = Array(Set(snap.tasks.flatMap { [$0.author, $0.assignee].compactMap { $0 } } + snap.reviews.map(\.requester)))
        let items = CoworkInbox.items(for: repo.me.email, in: snap, knownEmails: known)
        if json { return Output.json(items.map(Output.inbox)) }
        if items.isEmpty { print("Nothing new."); return }
        for i in items { print("\(Output.date(i.date))  \(i.title)  — \(i.detail)") }
    }

    // MARK: Writing

    func new() async throws {
        let title = try args.arg(1, "task title")
        let status = try args.value("status").map(Self.status) ?? .todo
        let snap = await repo.snapshot()
        let (t, edit) = CoworkEdit.newTask(title: title, status: status, assignee: args.value("assign").flatMap(resolve),
                                           labels: args.all("label"), body: args.value("body") ?? "",
                                           author: repo.me.email, in: snap)
        try await repo.apply(edit)
        await syncAfterWrite()
        json ? Output.json(Output.task(t)) : print(t.id)
    }

    /// `edit <id>`, plus the shortcuts `move`, `assign`, `done`.
    func edit(status: TaskStatus? = nil, assignee: String?? = nil) async throws {
        let id = try await taskID(args.arg(1, "task id"))
        let newStatus = try status ?? args.value("status").map(Self.status)
        let newAssignee: String?? = assignee ?? args.value("assign").map(resolve)
        let title = args.value("title"), body = args.value("body"), branch = args.value("branch")
        let labels = args.all("label")
        let changed = try await repo.apply(CoworkEdit.updateTasks([id: { t in
            if let title { t.title = title }
            if let body { t.body = body }
            if let newStatus { t.status = newStatus }
            if let newAssignee { t.assignee = newAssignee }
            if let branch { t.branch = branch == "none" ? nil : branch }
            for l in labels {
                if l.hasPrefix("-") { t.labels.removeAll { $0 == String(l.dropFirst()) } }
                else {
                    let name = l.hasPrefix("+") ? String(l.dropFirst()) : l
                    if !t.labels.contains(name) { t.labels.append(name) }
                }
            }
        }], message: "Update \(id)"))
        if changed { await syncAfterWrite() }
        try await printTask(id)
    }

    func comment() async throws {
        let id = try args.arg(1, "task or review id")
        let body = args.positional.dropFirst(2).joined(separator: " ")
        guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { throw CLIError.usage("missing comment text") }
        let snap = await repo.snapshot()
        let parent: String
        if let t = snap.tasks.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) { parent = t.commentParent }
        else if let r = snap.reviews.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) { parent = r.commentParent }
        else { throw CLIError.failed("No task or review \(id).") }
        let (c, edit) = CoworkEdit.comment(on: parent, body: body, by: repo.me)
        try await repo.apply(edit)
        await syncAfterWrite()
        json ? Output.json(Output.comment(c)) : print("Commented on \(id).")
    }

    func requestReview() async throws {
        let branch = try args.arg(1, "branch")
        let reviewers = args.all("to").flatMap { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
            .compactMap(resolve)
        guard !reviewers.isEmpty else { throw CLIError.usage("--to needs at least one reviewer email") }
        let localTip = await repo.sha(branch)
        let remoteTip = remote == nil ? nil : await repo.sha("\(remote!)/\(branch)")
        guard localTip != nil || remoteTip != nil else { throw CLIError.failed("No branch \(branch) here.") }
        let base = await baseName()
        let snap = await repo.snapshot()
        let task = try args.value("task").map(taskIDIn(snap)) ?? snap.tasks.first { $0.branch == branch }?.id
        let lastSubject = await repo.git.git(["log", "-1", "--format=%s", localTip ?? remoteTip!], in: repo.root).line
        let title = args.value("title") ?? lastSubject
        let (r, edit) = CoworkEdit.requestReview(branch: branch, base: args.value("base") ?? base, title: title,
                                                 reviewers: reviewers, body: args.value("body") ?? "",
                                                 taskID: task, requester: repo.me.email, in: snap)
        try await repo.apply(edit)
        await syncAfterWrite()
        json ? Output.json(Output.review(r)) : print(r.id)
    }

    func verdict(_ v: ReviewVerdict) async throws {
        let id = try args.arg(1, "review id")
        let text = args.positional.dropFirst(2).joined(separator: " ")
        if v == .changesRequested && text.isEmpty { throw CLIError.usage("say what should change") }
        guard let r = await repo.snapshot().reviews.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw CLIError.failed("No review \(id).")
        }
        try await repo.apply(CoworkEdit.verdict(v, on: r, comment: text, by: repo.me))
        await syncAfterWrite()
        print(v == .approved ? "Approved \(r.branch)." : "Asked for changes on \(r.branch).")
    }

    /// Checks out (or creates) the task's branch, here or in a new worktree,
    /// links it, moves the task to In Progress and assigns it to me.
    func start() async throws {
        let snap = await repo.snapshot()
        let id = try taskIDIn(snap)(args.arg(1, "task id"))
        let t = snap.tasks.first { $0.id == id }!
        let name = t.branch ?? RefName.branch(for: t)
        let local = await repo.sha("refs/heads/\(name)") != nil
        let tracking = remote.map { "\($0)/\(name)" }
        let onRemote = await tracking.asyncFlatMap { await repo.sha("refs/remotes/\($0)") } != nil
        let base = await startBase()

        var path: String?
        if args.flag("worktree") || args.value("worktree-path") != nil {
            let suggested = await suggestedWorktreePath(branch: name)
            let p = args.value("worktree-path") ?? suggested
            let cmd: [String] = local ? ["worktree", "add", p, name]
                : onRemote ? ["worktree", "add", "--track", "-b", name, p, tracking!]
                : ["worktree", "add", "--no-track", "-b", name, p, base]
            try await run(cmd)
            path = p
        } else {
            let cmd: [String] = local ? ["switch", name]
                : onRemote ? ["switch", "--track", tracking!]
                : ["switch", "--no-track", "-c", name, base]
            try await run(cmd)
        }
        let top = snap.tasks.filter { $0.status == .doing }.compactMap(\.rank).min()
        let me = repo.me.email
        try await repo.apply(CoworkEdit.updateTasks([id: { t in
            t.branch = name
            if t.status == .backlog || t.status == .todo {
                t.status = .doing
                t.rank = (top ?? 0) - 1
            }
            if t.assignee == nil, !me.isEmpty { t.assignee = me }
        }], message: "Start \(id)"))
        await syncAfterWrite()
        if json {
            var o: [String: Any] = ["id": id, "branch": name]
            o["worktree"] = path ?? NSNull()
            return Output.json(o)
        }
        print(path.map { "Started \(id) on \(name) in \($0)" } ?? "Started \(id) on \(name)")
    }

    func sync() async throws {
        guard let remote else { throw CLIError.failed("No remote to sync with.") }
        if try await repo.sync(remote: remote) { print("Synced with \(remote).") }
        else { throw CLIError.failed("The remote kept changing; try again.") }
    }

    // MARK: Helpers

    static func status(_ s: String) throws -> TaskStatus {
        switch s.lowercased() {
        case "backlog": .backlog
        case "todo", "to-do", "to do": .todo
        case "doing", "progress", "in-progress", "in progress", "started": .doing
        case "review", "in-review", "in review": .review
        case "done", "closed": .done
        default: throw CLIError.usage("unknown status \(s) (backlog, todo, doing, review, done)")
        }
    }

    /// "me" -> my email, "none" -> nil, an email stays, a handle maps to a known email.
    func resolve(_ who: String) -> String? {
        switch who.lowercased() {
        case "me": repo.me.email
        case "none", "nobody", "-": nil
        default: who
        }
    }

    private func taskID(_ id: String) async throws -> String {
        try taskIDIn(await repo.snapshot())(id)
    }

    private func taskIDIn(_ snap: CoworkSnapshot) -> (String) throws -> String {
        { id in
            guard let t = snap.tasks.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
                throw CLIError.failed("No task \(id).")
            }
            return t.id
        }
    }

    private func printTask(_ id: String) async throws {
        let snap = await repo.snapshot()
        guard let t = snap.tasks.first(where: { $0.id == id }) else { return }
        json ? Output.json(Output.task(t)) : print(Output.taskLine(t))
    }

    private func run(_ cmd: [String]) async throws {
        let r = await repo.git.git(cmd, in: repo.root)
        guard r.ok else { throw CLIError.failed(CoworkRepo.message(r, cmd.first ?? "git")) }
    }

    /// "origin/main" if the remote's default branch is known, else HEAD.
    private func startBase() async -> String {
        if let remote {
            let head = await repo.git.git(["symbolic-ref", "-q", "--short", "refs/remotes/\(remote)/HEAD"], in: repo.root).line
            if !head.isEmpty, await repo.sha(head) != nil { return head }
        }
        return "HEAD"
    }

    /// Plain name of the default branch ("main"), for review bases.
    private func baseName() async -> String {
        let b = await startBase()
        if b == "HEAD" { return "main" }
        return b.split(separator: "/", maxSplits: 1).last.map(String.init) ?? b
    }

    /// Sibling folder of the main checkout: "<repo>-<branch>".
    private func suggestedWorktreePath(branch: String) async -> String {
        let list = await repo.git.git(["worktree", "list", "--porcelain"], in: repo.root).text
        let main = list.split(separator: "\n").first.map { String($0.dropFirst("worktree ".count)) } ?? repo.root.path
        let url = URL(fileURLWithPath: main)
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent)-\(branch.replacingOccurrences(of: "/", with: "-"))").path
    }

    /// Writes push right away so teammates see them; a failed push is only a warning
    /// (the change is saved locally and goes out with the next sync).
    private func syncAfterWrite() async {
        guard !args.flag("no-sync"), let remote else { return }
        do {
            if try await repo.sync(remote: remote) == false {
                FileHandle.standardError.write(Data("git-cowork: saved locally; the remote kept changing, run `git cowork sync` later.\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("git-cowork: saved locally, but sync failed: \(error.localizedDescription)\n".utf8))
        }
    }

    private func syncQuietly() async {
        guard let remote else { return }
        _ = try? await repo.sync(remote: remote)
    }
}

private extension TaskStatus {
    var order: Int { TaskStatus.allCases.firstIndex(of: self) ?? 0 }
}

private extension Optional {
    func asyncFlatMap<T>(_ f: (Wrapped) async -> T?) async -> T? {
        guard let w = self else { return nil }
        return await f(w)
    }
}
