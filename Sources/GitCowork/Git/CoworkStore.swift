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
    let git = GitRunner.shared

    private(set) var snapshot = CoworkSnapshot()
    private(set) var me = TeamMember(handle: "", name: "", email: "")
    private(set) var loaded = false
    // Sync state; written by CoworkSync.swift.
    var syncing = false
    var lastSync: Date?
    var syncError: String?
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
    // Used by CoworkSync.swift.
    var pushTask: Task<Void, Never>?
    var syncChain: Task<Void, Never>?

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

    func revParse(_ ref: String) async -> String? {
        let out = await git.tryRun(["rev-parse", "--verify", "-q", ref + "^{commit}"], in: root)
        let s = out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    /// path -> blob sha for every file in a commit's tree.
    func listTree(_ commit: String) async -> [String: String] {
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
    func readBlobs(_ shas: [String]) async -> [String: String] {
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
    func writeCommit(base: String?, parents: [String], changes: [String: String?], message: String) async throws -> String? {
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
    func updateRef(to new: String, from old: String?) async throws {
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
    func write(reading paths: [String], message: String,
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

    /// Every label used on any task, most used first.
    var allLabels: [String] {
        var counts: [String: Int] = [:]
        for t in tasks { for l in t.labels { counts[l, default: 0] += 1 } }
        return counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
    }

    /// Lowercased handles that resolve to a person, for highlighting.
    var mentionHandles: Set<String> {
        Set(people.map { $0.mentionHandle.lowercased() })
    }

    /// Everyone in `people` except me, for assignee and reviewer pickers.
    var others: [TeamMember] { people.filter { $0.id != me.id } }

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
}
