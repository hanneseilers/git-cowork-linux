import Foundation
import GitCoworkCore
import Observation

/// Reads and writes the shared tasks/reviews on `refs/cowork/main` and syncs
/// them with the remote. Writes go through a temporary index and git plumbing
/// (hash-object, update-index, write-tree, commit-tree, update-ref), so the
/// working tree, the real index and HEAD are never touched.
@MainActor @Observable
final class CoworkStore {
    let root: URL
    private let git = GitRunner.shared

    private(set) var snapshot = CoworkSnapshot()
    private(set) var me = TeamMember(handle: "", name: "", email: "")
    private(set) var loaded = false
    private(set) var syncing = false
    private(set) var lastSync: Date?
    private(set) var syncError: String?
    /// Bumped whenever snapshot changes.
    private(set) var version = 0
    /// Remote used for syncing (set by the repo model).
    var remote: String?
    /// Unsent comment / review-note text per thing ("comment:tasks/CW-a3f9"),
    /// so it survives selection changes.
    var drafts: [String: String] = [:]
    /// Emails seen in commit history; used for assignee pickers and @mentions.
    var knownAuthors: [(name: String, email: String)] = []

    private var localTip: String?
    private var pushTask: Task<Void, Never>?

    init(root: URL) {
        self.root = root
    }

    // MARK: Reading

    func load() async {
        if me.email.isEmpty {
            let email = (await git.tryRun(["config", "user.email"], in: root) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (await git.tryRun(["config", "user.name"], in: root) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            me = TeamMember(handle: String(email.split(separator: "@").first ?? ""), name: name.isEmpty ? email : name, email: email)
        }
        await reload()
        loaded = true
    }

    /// Re-reads the local ref if it moved (or always, with `force`). Edits
    /// still being written are applied on top, so the UI never flickers back.
    func reload(force: Bool = false) async {
        let tip = await revParse(CoworkPaths.ref)
        guard tip != localTip || !loaded || force else { return }
        localTip = tip
        var snap = CoworkSnapshot()
        if let tip {
            let files = await readTree(tip)
            snap = await Task.detached { CoworkCodec.decode(files: files) }.value
        }
        for p in pending { p.change(&snap) }
        snapshot = snap
        version += 1
    }

    private func revParse(_ ref: String) async -> String? {
        let out = await git.tryRun(["rev-parse", "--verify", "-q", ref + "^{commit}"], in: root)
        let s = out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    /// path -> blob sha for every file in a commit's tree.
    private func listTree(_ commit: String) async -> [String: String] {
        guard let out = await git.tryRun(["ls-tree", "-r", "-z", "--full-tree", commit], in: root) else { return [:] }
        var result: [String: String] = [:]
        for entry in out.split(separator: "\0") {
            // "<mode> blob <sha>\t<path>"
            guard let tab = entry.firstIndex(of: "\t") else { continue }
            let meta = entry[..<tab].split(separator: " ")
            guard meta.count == 3, meta[1] == "blob" else { continue }
            result[String(entry[entry.index(after: tab)...])] = String(meta[2])
        }
        return result
    }

    /// Reads many blobs in one `git cat-file --batch` call.
    private func readBlobs(_ shas: [String]) async -> [String: String] {
        guard !shas.isEmpty else { return [:] }
        let input = Data((shas.joined(separator: "\n") + "\n").utf8)
        let r = await git.execute(["cat-file", "--batch"], in: root, input: input)
        guard r.exitCode == 0 else { return [:] }
        let data = Data(r.stdout.utf8)
        var result: [String: String] = [:]
        var i = data.startIndex
        while i < data.endIndex {
            guard let nl = data[i...].firstIndex(of: 0x0A) else { break }
            let header = String(decoding: data[i..<nl], as: UTF8.self).split(separator: " ")
            i = data.index(after: nl)
            guard header.count == 3, let size = Int(header[2]) else { continue }   // "<sha> missing"
            let end = data.index(i, offsetBy: size)
            result[String(header[0])] = String(decoding: data[i..<end], as: UTF8.self)
            i = data.index(after: end)   // trailing newline
        }
        return result
    }

    private func readTree(_ commit: String) async -> [String: String] {
        let tree = await listTree(commit)
        let blobs = await readBlobs(Array(Set(tree.values)))
        var files: [String: String] = [:]
        for (path, sha) in tree { files[path] = blobs[sha] }
        return files
    }

    /// Current content of a few files at `commit` (missing files are left out).
    private func readFiles(_ paths: [String], at commit: String?) async -> [String: String] {
        guard let commit, !paths.isEmpty else { return [:] }
        var files: [String: String] = [:]
        for path in paths {
            let r = await git.execute(["cat-file", "blob", "\(commit):\(path)"], in: root)
            if r.exitCode == 0 { files[path] = r.stdout }
        }
        return files
    }

    // MARK: Writing

    struct StoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Commits file changes (path -> new content; nil removes) on top of `parents[0]`.
    /// Returns the new commit sha, or nil when a single-parent commit would
    /// not change the tree (nothing to write).
    private func writeCommit(base: String?, parents: [String], changes: [String: String?], message: String) async throws -> String? {
        let indexFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-cowork-index-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: indexFile) }
        let env = ["GIT_INDEX_FILE": indexFile]

        if let base {
            try await git.run(["read-tree", base], in: root, env: env)
        } else {
            try await git.run(["read-tree", "--empty"], in: root, env: env)
        }

        var indexInfo = ""
        for (path, content) in changes.sorted(by: { $0.key < $1.key }) {
            if let content {
                let sha = try await git.run(["hash-object", "-w", "--stdin"], in: root, input: Data(content.utf8))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                indexInfo += "100644 \(sha)\t\(path)\n"
            } else {
                // mode 0 removes the path from the index
                indexInfo += "0 0000000000000000000000000000000000000000\t\(path)\n"
            }
        }
        if !indexInfo.isEmpty {
            try await git.run(["update-index", "--index-info"], in: root, input: Data(indexInfo.utf8), env: env)
        }
        let tree = try await git.run(["write-tree"], in: root, env: env).trimmingCharacters(in: .whitespacesAndNewlines)
        if parents.count <= 1, let base,
           await git.tryRun(["rev-parse", base + "^{tree}"], in: root)?.trimmingCharacters(in: .whitespacesAndNewlines) == tree {
            return nil
        }

        var args = ["commit-tree", tree]
        for p in parents { args += ["-p", p] }
        args += ["-m", message]
        // commit-tree needs an identity even if the repo has none configured.
        var commitEnv: [String: String] = [:]
        if !me.email.isEmpty {
            commitEnv = ["GIT_AUTHOR_NAME": me.name, "GIT_AUTHOR_EMAIL": me.email,
                         "GIT_COMMITTER_NAME": me.name, "GIT_COMMITTER_EMAIL": me.email]
        }
        return try await git.run(args, in: root, env: commitEnv).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Moves refs/cowork/main from `old` to `new`, failing if someone else moved it meanwhile.
    private func updateRef(to new: String, from old: String?) async throws {
        try await git.run(["update-ref", "-m", "git-cowork", CoworkPaths.ref, new, old ?? String(repeating: "0", count: 40)], in: root)
    }

    /// An edit shown in `snapshot` right away, before its commit is written.
    private struct PendingEdit {
        let token: Int
        let change: (inout CoworkSnapshot) -> Void
    }
    private var pending: [PendingEdit] = []
    private var nextToken = 0
    private var writeChain: Task<Bool, Never>?

    /// Writes new files / removals as one commit, then pushes in the background.
    @discardableResult
    func apply(_ changes: [String: String?], message: String) async -> Bool {
        await write(reading: [], message: message) { _ in changes }
    }

    /// Writes one commit on refs/cowork/main. `build` gets the current content
    /// of `paths` at the tip the commit is built on (re-read on every retry),
    /// and returns the changes (path -> content; nil removes). So an edit
    /// always applies to the latest stored file, never to a stale copy.
    /// `optimistic` shows the edit in `snapshot` until the write lands.
    /// Writes run one at a time, in call order.
    @discardableResult
    private func write(reading paths: [String], message: String,
                       optimistic: ((inout CoworkSnapshot) -> Void)? = nil,
                       _ build: @escaping ([String: String]) -> [String: String?]) async -> Bool {
        nextToken += 1
        let token = nextToken
        if let optimistic {
            pending.append(PendingEdit(token: token, change: optimistic))
            optimistic(&snapshot)
            version += 1
        }
        let previous = writeChain
        let task = Task { @MainActor in
            _ = await previous?.value
            return await self.writeOnce(reading: paths, message: message, build)
        }
        writeChain = task
        let ok = await task.value
        let hadPending = pending.contains { $0.token == token }
        pending.removeAll { $0.token == token }
        await reload(force: hadPending)
        if ok { schedulePush() }
        return ok
    }

    private func writeOnce(reading paths: [String], message: String,
                           _ build: ([String: String]) -> [String: String?]) async -> Bool {
        do {
            for attempt in 0..<3 {
                let tip = await revParse(CoworkPaths.ref)
                let changes = build(await readFiles(paths, at: tip))
                if changes.isEmpty { return true }
                guard let commit = try await writeCommit(base: tip, parents: tip.map { [$0] } ?? [],
                                                         changes: changes, message: message) else { return true }
                do {
                    try await updateRef(to: commit, from: tip)
                    return true
                } catch where attempt < 2 {
                    continue   // another window or a sync moved the ref; rebuild on the new tip
                }
            }
            return false
        } catch {
            syncError = error.localizedDescription
            return false
        }
    }

    // MARK: Sync

    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    private var syncChain: Task<Void, Never>?

    /// Fetch the remote's cowork ref, merge with ours, push the result.
    /// Calls queue up behind a running sync, so when this returns a full
    /// sync has happened after the call.
    func sync() async {
        let previous = syncChain
        let task = Task { @MainActor in
            await previous?.value
            await syncOnce()
        }
        syncChain = task
        await task.value
    }

    private func syncOnce() async {
        guard let remote else { await reload(); return }
        syncing = true
        defer { syncing = false }

        do {
            var done = false
            attempts: for _ in 0..<3 {
                let remoteRef = CoworkPaths.remoteRef(remote)
                // --no-write-fetch-head: don't clobber the user's FETCH_HEAD (or wake the file watcher).
                let fetch = await git.execute(["fetch", "--no-tags", "--no-write-fetch-head", remote,
                                               "+\(CoworkPaths.ref):\(remoteRef)"], in: root)
                let remoteMissing = fetch.exitCode != 0 && fetch.stderr.contains("couldn't find remote ref")
                if fetch.exitCode != 0 && !remoteMissing {
                    throw StoreError(message: GitError(command: "fetch", result: fetch).localizedDescription)
                }

                let local = await revParse(CoworkPaths.ref)
                let theirs = remoteMissing ? nil : await revParse(remoteRef)

                // A local write can move the ref while we fetch or merge; then
                // update-ref fails its old-value check and we simply go again.
                switch (local, theirs) {
                case (nil, nil):
                    done = true
                case (nil, let t?):
                    guard await tryUpdateRef(to: t, from: nil) else { continue attempts }
                    done = true
                case (let l?, nil):
                    done = try await push(l, remote: remote)
                case (let l?, let t?) where l == t:
                    done = true
                case (let l?, let t?):
                    if await isAncestor(l, of: t) {
                        guard await tryUpdateRef(to: t, from: l) else { continue attempts }
                        done = true
                    } else if await isAncestor(t, of: l) {
                        done = try await push(l, remote: remote)
                    } else {
                        let merged = try await merge(local: l, theirs: t)
                        guard await tryUpdateRef(to: merged, from: l) else { continue attempts }
                        done = try await push(merged, remote: remote)
                    }
                }
                if done { break }
            }
            if done {
                syncError = nil
                lastSync = Date()
            } else {
                syncError = "Couldn't push cowork changes: the remote kept moving. Will retry."
            }
        } catch {
            syncError = error.localizedDescription
        }
        await reload()
    }

    private func tryUpdateRef(to new: String, from old: String?) async -> Bool {
        do { try await updateRef(to: new, from: old); return true } catch { return false }
    }

    private func isAncestor(_ a: String, of b: String) async -> Bool {
        await git.execute(["merge-base", "--is-ancestor", a, b], in: root).exitCode == 0
    }

    /// Pushes; returns false when the remote moved (caller fetches again).
    /// Throws for anything else, including a server that refuses the ref.
    private func push(_ commit: String, remote: String) async throws -> Bool {
        // --no-verify: the cowork ref only holds task metadata; the user's
        // pre-push hooks (tests, lint) are for their branches.
        let r = await git.execute(["push", "--porcelain", "--no-verify", remote, "\(commit):\(CoworkPaths.ref)"], in: root)
        if r.exitCode == 0 { return true }
        // Porcelain: "!\t<src>:<dst>\t[rejected] (fetch first)" for a lost race,
        // "[remote rejected] (...)" when the server refuses.
        let lostRace = r.stdout.split(separator: "\n").contains { line in
            line.hasPrefix("!") && line.contains("[rejected]")
                && (line.contains("non-fast-forward") || line.contains("fetch first") || line.contains("stale info"))
        }
        if lostRace { return false }
        throw StoreError(message: GitError(command: "push", result: r).localizedDescription)
    }

    /// Three-way merge of two diverged cowork commits, file by file.
    private func merge(local: String, theirs: String) async throws -> String {
        let baseOut = await git.tryRun(["merge-base", local, theirs], in: root)
        let base = baseOut?.trimmingCharacters(in: .whitespacesAndNewlines)
        var bt: [String: String] = [:]
        if let base { bt = await listTree(base) }
        let o = await listTree(local)
        let t = await listTree(theirs)

        var changes: [String: String?] = [:]
        var needed = Set<String>()
        var conflicted: [String] = []
        for path in Set(o.keys).union(t.keys).union(bt.keys) {
            let bs = bt[path], os = o[path], ts = t[path]
            if os == ts || ts == bs { continue }             // nothing new from them
            if os == bs { changes[path] = .some(nil); needed.insert(ts ?? ""); continue }   // take theirs below
            conflicted.append(path)
            [bs, os, ts].compactMap { $0 }.forEach { needed.insert($0) }
        }
        let blobs = await readBlobs(Array(needed.filter { !$0.isEmpty }))

        for path in changes.keys {
            changes[path] = t[path].flatMap { blobs[$0] }      // nil = they deleted it
        }
        for path in conflicted {
            changes[path] = CoworkMerge.mergeFile(path: path,
                                                  base: bt[path].flatMap { blobs[$0] },
                                                  ours: o[path].flatMap { blobs[$0] },
                                                  theirs: t[path].flatMap { blobs[$0] })
        }
        guard let merged = try await writeCommit(base: local, parents: [local, theirs], changes: changes,
                                                 message: "Merge cowork changes") else {
            throw StoreError(message: "Couldn't write the cowork merge")
        }
        return merged
    }

    // MARK: Lookups

    var tasks: [CoworkTask] { snapshot.tasks }
    var reviews: [ReviewRequest] { snapshot.reviews }

    func task(_ id: String) -> CoworkTask? { snapshot.tasks.first { $0.id == id } }
    func review(_ id: String) -> ReviewRequest? { snapshot.reviews.first { $0.id == id } }
    func comments(on parent: String) -> [CoworkComment] { snapshot.comments[parent] ?? [] }

    /// Team members plus everyone seen in commits, one entry per email.
    var people: [TeamMember] {
        var byEmail: [String: TeamMember] = [:]
        for a in knownAuthors where !a.email.isEmpty {
            byEmail[a.email.lowercased()] = TeamMember(handle: String(a.email.split(separator: "@").first ?? ""), name: a.name, email: a.email)
        }
        for m in snapshot.team { byEmail[m.id] = m }
        if !me.email.isEmpty, byEmail[me.id] == nil { byEmail[me.id] = me }
        return byEmail.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func person(_ email: String?) -> TeamMember? {
        guard let email, !email.isEmpty else { return nil }
        if snapshot.team.isEmpty, let known = knownAuthors.first(where: { $0.email.lowercased() == email.lowercased() }) {
            return TeamMember(handle: String(email.split(separator: "@").first ?? ""), name: known.name, email: known.email)
        }
        return snapshot.team.first { $0.id == email.lowercased() }
            ?? knownAuthors.first { $0.email.lowercased() == email.lowercased() }
                .map { TeamMember(handle: String(email.split(separator: "@").first ?? ""), name: $0.name, email: $0.email) }
            ?? (email.lowercased() == me.id ? me : nil)
            ?? TeamMember(handle: String(email.split(separator: "@").first ?? ""), name: email, email: email)
    }

    var inbox: [InboxItem] {
        guard !me.email.isEmpty else { return [] }
        var names: [String: String] = [:]
        for p in people { names[p.id] = p.name }
        return CoworkInbox.items(for: me.email, in: snapshot, knownEmails: people.map(\.email), names: names)
    }

    // MARK: Mutations

    @discardableResult
    func createTask(title: String, status: TaskStatus = .backlog, assignee: String? = nil,
                    labels: [String] = [], body: String = "") async -> CoworkTask? {
        let now = Date()
        let id = CoworkCodec.newID(prefix: "CW-", existing: Set(snapshot.tasks.map(\.id)))
        let rank = (snapshot.tasks.filter { $0.status == status }.compactMap(\.rank).min() ?? 0) - 1
        let t = CoworkTask(id: id, title: title, status: status, assignee: assignee, labels: labels,
                           author: me.email, created: now, updated: now, body: body, rank: rank)
        let ok = await apply([t.path: CoworkCodec.encode(t)], message: "Create \(id): \(title)")
        return ok ? t : nil
    }

    /// Changes one task. `change` runs on the task as stored at the tip the
    /// commit is built on, so other fields changed meanwhile (here or in
    /// another window) are kept. No commit when nothing changed.
    @discardableResult
    func updateTask(_ id: String, _ change: @escaping (inout CoworkTask) -> Void) async -> Bool {
        await updateTasks([id: change], message: "Update \(id)")
    }

    /// Changes several tasks in one commit.
    @discardableResult
    func updateTasks(_ edits: [String: (inout CoworkTask) -> Void], message: String) async -> Bool {
        let now = Date()
        return await write(reading: edits.keys.map(CoworkPaths.task), message: message, optimistic: { snap in
            for (id, change) in edits {
                if let i = snap.tasks.firstIndex(where: { $0.id == id }) { change(&snap.tasks[i]) }
            }
        }) { current in
            var changes: [String: String?] = [:]
            for (id, change) in edits {
                let path = CoworkPaths.task(id)
                // Deleted meanwhile: don't bring it back.
                guard let text = current[path], var t = CoworkCodec.decodeTask(text, id: id) else { continue }
                let before = t
                change(&t)
                guard t != before else { continue }
                t.updated = now
                changes[path] = CoworkCodec.encode(t)
            }
            return changes
        }
    }

    func deleteTask(_ t: CoworkTask) async {
        var changes: [String: String?] = [t.path: nil]
        for c in comments(on: t.commentParent) { changes[c.path] = .some(nil) }
        await write(reading: [], message: "Delete \(t.id)", optimistic: { snap in
            snap.tasks.removeAll { $0.id == t.id }
        }) { _ in changes }
    }

    /// Returns false when the comment couldn't be written.
    @discardableResult
    func addComment(on parent: String, body: String) async -> Bool {
        let now = Date()
        let c = CoworkComment(id: CoworkCodec.newCommentID(date: now), parent: parent, author: me.email,
                              authorName: me.name, created: now, body: body)
        return await apply([c.path: CoworkCodec.encode(c)], message: "Comment on \(parent)")
    }

    @discardableResult
    func requestReview(branch: String, base: String, title: String, reviewers: [String],
                       body: String, taskID: String?) async -> ReviewRequest? {
        let now = Date()
        let id = CoworkCodec.newID(prefix: "R-", existing: Set(snapshot.reviews.map(\.id)))
        var rv: [String: ReviewVerdict] = [:]
        for r in reviewers { rv[r.lowercased()] = .requested }
        let r = ReviewRequest(id: id, title: title, branch: branch, base: base, requester: me.email,
                              reviewers: rv, taskID: taskID, created: now, updated: now, body: body)
        let paths = taskID.map { [CoworkPaths.task($0)] } ?? []
        let ok = await write(reading: paths, message: "Request review of \(branch)") { current in
            var changes: [String: String?] = [r.path: CoworkCodec.encode(r)]
            // Move the linked task to "In Review".
            if let taskID, let text = current[CoworkPaths.task(taskID)],
               var t = CoworkCodec.decodeTask(text, id: taskID), t.status != .review, t.status != .done {
                t.status = .review
                t.updated = now
                changes[t.path] = CoworkCodec.encode(t)
            }
            return changes
        }
        return ok ? r : nil
    }

    /// Changes one review, applied to the stored copy at the tip (see updateTask).
    @discardableResult
    func updateReview(_ id: String, extra: [String: String?] = [:], message: String? = nil,
                      _ change: @escaping (inout ReviewRequest) -> Void) async -> Bool {
        let now = Date()
        let path = CoworkPaths.review(id)
        return await write(reading: [path], message: message ?? "Update review \(id)", optimistic: { snap in
            if let i = snap.reviews.firstIndex(where: { $0.id == id }) { change(&snap.reviews[i]) }
        }) { current in
            guard let text = current[path], var r = CoworkCodec.decodeReview(text, id: id) else { return [:] }
            let before = r
            change(&r)
            var changes = extra
            if r != before {
                r.updated = now
                changes[path] = CoworkCodec.encode(r)
            }
            return changes
        }
    }

    @discardableResult
    func setVerdict(_ verdict: ReviewVerdict, on review: ReviewRequest, comment: String) async -> Bool {
        let now = Date()
        var extra: [String: String?] = [:]
        if !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let c = CoworkComment(id: CoworkCodec.newCommentID(date: now), parent: review.commentParent, author: me.email,
                                  authorName: me.name, created: now, body: comment)
            extra[c.path] = CoworkCodec.encode(c)
        }
        let myID = me.id, myEmail = me.email
        return await updateReview(review.id, extra: extra, message: "\(verdict.rawValue) \(review.branch)") { r in
            // Reuse the key the requester wrote, whatever its case.
            let key = r.reviewers.keys.first { $0.lowercased() == myID } ?? myEmail.lowercased()
            r.reviewers[key] = verdict
        }
    }

    /// Saves the team list, merged with whatever is stored at the tip now
    /// (so members another window or teammate added or removed meanwhile stay that way).
    func saveTeam(_ members: [TeamMember]) async {
        let base = CoworkCodec.encodeTeam(snapshot.team)
        let ours = CoworkCodec.encodeTeam(members)
        await write(reading: [CoworkPaths.team], message: "Update team", optimistic: { $0.team = members }) { current in
            let merged = CoworkMerge.mergeFile(path: CoworkPaths.team, base: base, ours: ours,
                                               theirs: current[CoworkPaths.team] ?? base)
            return [CoworkPaths.team: merged ?? ours]
        }
    }
}
