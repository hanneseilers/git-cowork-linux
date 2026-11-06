import Foundation
import GitCoworkCore

/// Syncing refs/cowork/main with the remote: fetch, merge, push.
extension CoworkStore {
    func schedulePush() {
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

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

    func syncOnce() async {
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

    func tryUpdateRef(to new: String, from old: String?) async -> Bool {
        do { try await updateRef(to: new, from: old); return true } catch { return false }
    }

    func isAncestor(_ a: String, of b: String) async -> Bool {
        await git.execute(["merge-base", "--is-ancestor", a, b], in: root).exitCode == 0
    }

    /// Pushes; returns false when the remote moved (caller fetches again).
    /// Throws for anything else, including a server that refuses the ref.
    func push(_ commit: String, remote: String) async throws -> Bool {
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
    func merge(local: String, theirs: String) async throws -> String {
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
}
