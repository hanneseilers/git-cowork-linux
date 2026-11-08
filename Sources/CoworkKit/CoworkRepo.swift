import Foundation
import GitCoworkCore

/// Reads, writes and syncs the shared tasks/reviews on `refs/cowork/main`.
/// Used by the app (through CoworkStore) and by the `git-cowork` tool.
///
/// Writes go through a temporary index and git plumbing (hash-object,
/// update-index, write-tree, commit-tree, update-ref), so the working tree,
/// the real index and HEAD are never touched.
public struct CoworkRepo: Sendable {
    public let root: URL
    public let git: GitExecutor
    /// Who commits are written as. Empty email: git's own identity.
    public var me: TeamMember

    public init(root: URL, git: GitExecutor, me: TeamMember = TeamMember(handle: "", name: "", email: "")) {
        self.root = root
        self.git = git
        self.me = me
    }

    public struct Failure: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// `git config user.email` / `user.name` as a team member.
    public static func identity(root: URL, git: GitExecutor) async -> TeamMember {
        let email = await git.git(["config", "user.email"], in: root).line
        let name = await git.git(["config", "user.name"], in: root).line
        return TeamMember(handle: String(email.split(separator: "@").first ?? ""), name: name.isEmpty ? email : name, email: email)
    }

    // MARK: Reading

    /// Commit sha of a revision, or nil if it doesn't exist.
    public func sha(_ rev: String) async -> String? {
        let r = await git.git(["rev-parse", "--verify", "-q", rev + "^{commit}"], in: root)
        return r.ok && !r.line.isEmpty ? r.line : nil
    }

    /// Tip of the local cowork ref.
    public func tip() async -> String? { await sha(CoworkPaths.ref) }

    /// path -> blob sha for every file in a commit's tree.
    public func listTree(_ commit: String) async -> [String: String] {
        let r = await git.git(["ls-tree", "-r", "-z", "--full-tree", commit], in: root)
        guard r.ok else { return [:] }
        var result: [String: String] = [:]
        for entry in r.text.split(separator: "\0") {
            // "<mode> blob <sha>\t<path>"
            guard let tab = entry.firstIndex(of: "\t") else { continue }
            let meta = entry[..<tab].split(separator: " ")
            guard meta.count == 3, meta[1] == "blob" else { continue }
            result[String(entry[entry.index(after: tab)...])] = String(meta[2])
        }
        return result
    }

    /// Reads many blobs in one `git cat-file --batch` call. Sizes are in bytes,
    /// so the output is parsed as bytes and each blob decoded on its own.
    public func readBlobs(_ shas: [String]) async -> [String: String] {
        guard !shas.isEmpty else { return [:] }
        let r = await git.git(["cat-file", "--batch"], in: root, input: Data((shas.joined(separator: "\n") + "\n").utf8))
        guard r.ok else { return [:] }
        let data = r.stdout
        var result: [String: String] = [:]
        var i = data.startIndex
        while i < data.endIndex {
            guard let nl = data[i...].firstIndex(of: 0x0A) else { break }
            let header = String(decoding: data[i..<nl], as: UTF8.self).split(separator: " ")
            i = data.index(after: nl)
            guard header.count == 3, let size = Int(header[2]) else { continue }   // "<sha> missing"
            let end = data.index(i, offsetBy: size)
            result[String(header[0])] = String(decoding: data[i..<end], as: UTF8.self)
            i = min(data.endIndex, data.index(after: end))   // trailing newline
        }
        return result
    }

    /// Every file at `commit` (path -> text).
    public func readAll(at commit: String) async -> [String: String] {
        let tree = await listTree(commit)
        let blobs = await readBlobs(Array(Set(tree.values)))
        var files: [String: String] = [:]
        for (path, sha) in tree { files[path] = blobs[sha] }
        return files
    }

    /// Everything on the local ref, decoded.
    public func snapshot() async -> CoworkSnapshot {
        guard let tip = await tip() else { return CoworkSnapshot() }
        return CoworkCodec.decode(files: await readAll(at: tip))
    }

    /// Current content of a few files at `commit` (missing files are left out).
    public func readFiles(_ paths: [String], at commit: String?) async -> [String: String] {
        guard let commit, !paths.isEmpty else { return [:] }
        var files: [String: String] = [:]
        for path in paths {
            let r = await git.git(["cat-file", "blob", "\(commit):\(path)"], in: root)
            if r.ok { files[path] = r.text }
        }
        return files
    }

    // MARK: Writing

    /// Commits file changes (path -> new content; nil removes) on top of `base`.
    /// Returns the new commit sha, or nil when a single-parent commit would
    /// not change the tree (nothing to write).
    public func writeCommit(base: String?, parents: [String], changes: [String: String?], message: String) async throws -> String? {
        #if os(Linux)
        // Not in the shared /tmp (see PrivateDirectory).
        let tempDir = PrivateDirectory.app() ?? FileManager.default.temporaryDirectory
        #else
        let tempDir = FileManager.default.temporaryDirectory
        #endif
        let indexFile = tempDir.appendingPathComponent("git-cowork-index-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: indexFile) }
        let env = ["GIT_INDEX_FILE": indexFile]

        try check(await git.git(base.map { ["read-tree", $0] } ?? ["read-tree", "--empty"], in: root, input: nil, env: env), "read-tree")

        var indexInfo = ""
        for (path, content) in changes.sorted(by: { $0.key < $1.key }) {
            if let content {
                let r = try check(await git.git(["hash-object", "-w", "--stdin"], in: root, input: Data(content.utf8)), "hash-object")
                indexInfo += "100644 \(r.line)\t\(path)\n"
            } else {
                // mode 0 removes the path from the index
                indexInfo += "0 0000000000000000000000000000000000000000\t\(path)\n"
            }
        }
        if !indexInfo.isEmpty {
            try check(await git.git(["update-index", "--index-info"], in: root, input: Data(indexInfo.utf8), env: env), "update-index")
        }
        let tree = try check(await git.git(["write-tree"], in: root, input: nil, env: env), "write-tree").line
        if parents.count <= 1, let base, await git.git(["rev-parse", base + "^{tree}"], in: root).line == tree {
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
        return try check(await git.git(args, in: root, input: nil, env: commitEnv), "commit-tree").line
    }

    /// Moves refs/cowork/main from `old` to `new`, failing if someone else moved it meanwhile.
    public func updateRef(to new: String, from old: String?) async throws {
        try check(await git.git(["update-ref", "-m", "git-cowork", CoworkPaths.ref, new,
                                 old ?? String(repeating: "0", count: 40)], in: root), "update-ref")
    }

    public func tryUpdateRef(to new: String, from old: String?) async -> Bool {
        (try? await updateRef(to: new, from: old)) != nil
    }

    /// Writes one commit on the local ref. `build` gets the current content of
    /// `paths` at the tip the commit is built on (re-read on every retry) and
    /// returns the changes (path -> content; nil removes), so an edit always
    /// applies to the latest stored file. Returns false if nothing needed writing.
    @discardableResult
    public func commit(reading paths: [String], message: String,
                       _ build: ([String: String]) -> [String: String?]) async throws -> Bool {
        for attempt in 0..<3 {
            let tip = await tip()
            let changes = build(await readFiles(paths, at: tip))
            if changes.isEmpty { return false }
            guard let commit = try await writeCommit(base: tip, parents: tip.map { [$0] } ?? [],
                                                     changes: changes, message: message) else { return false }
            if await tryUpdateRef(to: commit, from: tip) { return true }
            if attempt == 2 { break }   // another writer moved the ref; rebuild on the new tip
        }
        throw Failure("Couldn't save: the cowork ref kept changing. Try again.")
    }

    // MARK: Sync

    /// Fetches the remote's cowork ref, merges it with ours, and pushes the
    /// result. Returns false if the remote kept moving (try again later).
    @discardableResult
    public func sync(remote: String) async throws -> Bool {
        for _ in 0..<3 {
            let remoteRef = CoworkPaths.remoteRef(remote)
            // --no-write-fetch-head: don't clobber the user's FETCH_HEAD.
            let fetch = await git.git(["fetch", "--no-tags", "--no-write-fetch-head", remote,
                                       "+\(CoworkPaths.ref):\(remoteRef)"], in: root)
            let remoteMissing = !fetch.ok && fetch.errorText.contains("couldn't find remote ref")
            if !fetch.ok && !remoteMissing { throw Failure(Self.message(fetch, "fetch")) }

            let local = await tip()
            let theirs = remoteMissing ? nil : await sha(remoteRef)

            // A local write can move the ref while we fetch or merge; then
            // update-ref fails its old-value check and we simply go again.
            switch (local, theirs) {
            case (nil, nil):
                return true
            case (nil, let t?):
                if await tryUpdateRef(to: t, from: nil) { return true }
            case (let l?, nil):
                if try await push(l, remote: remote) { return true }
            case (let l?, let t?) where l == t:
                return true
            case (let l?, let t?):
                if await isAncestor(l, of: t) {
                    if await tryUpdateRef(to: t, from: l) { return true }
                } else if await isAncestor(t, of: l) {
                    if try await push(l, remote: remote) { return true }
                } else {
                    let merged = try await merge(local: l, theirs: t)
                    if await tryUpdateRef(to: merged, from: l), try await push(merged, remote: remote) { return true }
                }
            }
        }
        return false
    }

    public func isAncestor(_ a: String, of b: String) async -> Bool {
        await git.git(["merge-base", "--is-ancestor", a, b], in: root).ok
    }

    /// Pushes; returns false when the remote moved (caller fetches again).
    /// Throws for anything else, including a server that refuses the ref.
    public func push(_ commit: String, remote: String) async throws -> Bool {
        // --no-verify: the cowork ref only holds task metadata; the user's
        // pre-push hooks (tests, lint) are for their branches.
        let r = await git.git(["push", "--porcelain", "--no-verify", remote, "\(commit):\(CoworkPaths.ref)"], in: root)
        if r.ok { return true }
        // Porcelain: "!\t<src>:<dst>\t[rejected] (fetch first)" for a lost race,
        // "[remote rejected] (...)" when the server refuses.
        let lostRace = r.text.split(separator: "\n").contains { line in
            line.hasPrefix("!") && line.contains("[rejected]")
                && (line.contains("non-fast-forward") || line.contains("fetch first") || line.contains("stale info"))
        }
        if lostRace { return false }
        throw Failure(Self.message(r, "push"))
    }

    /// Three-way merge of two diverged cowork commits, file by file.
    public func merge(local: String, theirs: String) async throws -> String {
        let base = await git.git(["merge-base", local, theirs], in: root).line
        let bt = base.isEmpty ? [:] : await listTree(base)
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
            throw Failure("Couldn't write the cowork merge")
        }
        return merged
    }

    // MARK: Helpers

    @discardableResult
    private func check(_ r: GitOutput, _ what: String) throws -> GitOutput {
        guard r.ok else { throw Failure(Self.message(r, what)) }
        return r
    }

    /// git's own error text, or the command and exit code.
    public static func message(_ r: GitOutput, _ what: String) -> String {
        let err = r.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = r.line
        return out.isEmpty ? "git \(what) exited with code \(r.exitCode)" : out
    }
}
