import Foundation

/// Parsers for git's machine-readable output. Each matches a format string
/// defined next to it, so the command and the parser stay in sync.
public enum Parsers {
    static let fieldSep: Character = "\u{1f}"
    static let recordSep: Character = "\u{1e}"

    // MARK: log

    public static let logFormat = "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%b%x1e"

    public static func parseLog(_ output: String) -> [Commit] {
        var commits: [Commit] = []
        commits.reserveCapacity(2048)
        for record in output.split(separator: recordSep, omittingEmptySubsequences: true) {
            let rec = record.drop(while: { $0 == "\n" })
            if rec.isEmpty { continue }
            let f = rec.split(separator: fieldSep, maxSplits: 6, omittingEmptySubsequences: false)
            guard f.count >= 6 else { continue }
            var body = ""
            if f.count == 7 {
                body = f[6].split(whereSeparator: \.isNewline).first
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            }
            let parents = f[1].split(separator: " ").map(String.init)
            commits.append(Commit(
                id: String(f[0]),
                parents: parents,
                authorName: String(f[2]),
                authorEmail: String(f[3]),
                date: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0),
                subject: String(f[5]),
                bodyPreview: body
            ))
        }
        return commits
    }

    // MARK: commit detail

    public static let detailFormat = "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%ct%x1f%B"

    public static func parseCommitDetail(_ output: String) -> CommitDetail? {
        let f = output.split(separator: fieldSep, maxSplits: 8, omittingEmptySubsequences: false)
        guard f.count == 9 else { return nil }
        return CommitDetail(
            id: String(f[0]),
            parents: f[1].split(separator: " ").map(String.init),
            authorName: String(f[2]),
            authorEmail: String(f[3]),
            authorDate: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0),
            committerName: String(f[5]),
            committerEmail: String(f[6]),
            committerDate: Date(timeIntervalSince1970: TimeInterval(f[7]) ?? 0),
            message: String(f[8]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: refs

    public static let refFormat = "--format=%(refname)%1f%(objectname)%1f%(*objectname)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(HEAD)%1f%(symref)"

    public struct RefList: Sendable {
        public var refs: [Ref] = []
        /// remote name -> default branch (from refs/remotes/<remote>/HEAD), e.g. "origin" -> "main"
        public var remoteDefaults: [String: String] = [:]
    }

    public static func parseRefs(_ output: String) -> RefList {
        var list = RefList()
        for line in output.split(separator: "\n") {
            let f = line.split(separator: fieldSep, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7 else { continue }
            let full = f[0], sha = f[1], peeled = f[2], upstream = f[3], track = f[4], head = f[5], symref = f[6]

            if !symref.isEmpty {
                // refs/remotes/origin/HEAD -> refs/remotes/origin/main
                if full.hasPrefix("refs/remotes/"), full.hasSuffix("/HEAD") {
                    let remote = String(full.dropFirst("refs/remotes/".count).dropLast("/HEAD".count))
                    let prefix = "refs/remotes/\(remote)/"
                    if symref.hasPrefix(prefix) {
                        list.remoteDefaults[remote] = String(symref.dropFirst(prefix.count))
                    }
                }
                continue
            }

            let kind: RefKind
            let name: String
            if full.hasPrefix("refs/heads/") {
                kind = .localBranch; name = String(full.dropFirst("refs/heads/".count))
            } else if full.hasPrefix("refs/remotes/") {
                kind = .remoteBranch; name = String(full.dropFirst("refs/remotes/".count))
            } else if full.hasPrefix("refs/tags/") {
                kind = .tag; name = String(full.dropFirst("refs/tags/".count))
            } else {
                continue
            }

            let (ahead, behind, gone) = parseTrack(track)
            list.refs.append(Ref(
                fullName: full,
                name: name,
                kind: kind,
                target: peeled.isEmpty ? sha : peeled,
                upstream: upstream.isEmpty ? nil : upstream,
                ahead: ahead,
                behind: behind,
                upstreamGone: gone,
                isHead: head == "*"
            ))
        }
        return list
    }

    /// "ahead 1, behind 2" / "gone" / ""
    static func parseTrack(_ s: String) -> (Int, Int, Bool) {
        if s == "gone" { return (0, 0, true) }
        var ahead = 0, behind = 0
        for part in s.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard p.count == 2, let n = Int(p[1]) else { continue }
            if p[0] == "ahead" { ahead = n } else if p[0] == "behind" { behind = n }
        }
        return (ahead, behind, false)
    }

    // MARK: status (porcelain v2, -z, --branch)

    public static func parseStatus(_ output: String) -> WorkingStatus {
        var st = WorkingStatus()
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: false)
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            i += 1
            if t.isEmpty { continue }
            let type = t.first!

            switch type {
            case "#":
                let parts = t.split(separator: " ", maxSplits: 2)
                guard parts.count >= 3 else { continue }
                let key = parts[1], value = String(parts[2])
                switch key {
                case "branch.oid": st.headOID = value == "(initial)" ? nil : value
                case "branch.head": st.branch = value == "(detached)" ? nil : value
                case "branch.upstream": st.upstream = value
                case "branch.ab":
                    for v in value.split(separator: " ") {
                        if v.hasPrefix("+") { st.ahead = Int(v.dropFirst()) ?? 0 }
                        if v.hasPrefix("-") { st.behind = Int(v.dropFirst()) ?? 0 }
                    }
                default: break
                }

            case "1", "2":
                // 1 XY sub mH mI mW hH hI path
                // 2 XY sub mH mI mW hH hI Xscore path \0 origPath
                let fieldCount = type == "1" ? 9 : 10
                let f = t.split(separator: " ", maxSplits: fieldCount - 1, omittingEmptySubsequences: false)
                guard f.count == fieldCount else { continue }
                let xy = Array(f[1])
                let path = String(f[fieldCount - 1])
                var oldPath: String?
                if type == "2", i < tokens.count {
                    oldPath = String(tokens[i]); i += 1
                }
                if xy.count == 2 {
                    if xy[0] != "." {
                        st.staged.append(FileChange(path: path, oldPath: oldPath, status: FileStatus(code: xy[0]), area: .staged))
                    }
                    if xy[1] != "." {
                        st.unstaged.append(FileChange(path: path, oldPath: nil, status: FileStatus(code: xy[1]), area: .unstaged))
                    }
                }

            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let f = t.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard f.count == 11 else { continue }
                st.conflicted.append(FileChange(path: String(f[10]), status: .conflicted, area: .conflicted))

            case "?":
                let path = String(t.dropFirst(2))
                st.untracked.append(FileChange(path: path, status: .untracked, area: .untracked))

            default:
                continue
            }
        }
        return st
    }

    // MARK: worktrees (git worktree list --porcelain)

    public static func parseWorktrees(_ output: String) -> [Worktree] {
        var result: [Worktree] = []
        var path: String?
        var head: String?
        var branch: String?
        var bare = false, locked = false, prunable = false

        func flush() {
            if let p = path {
                result.append(Worktree(path: p, head: head, branch: branch, isBare: bare,
                                       isLocked: locked, isPrunable: prunable, isMain: result.isEmpty))
            }
            path = nil; head = nil; branch = nil; bare = false; locked = false; prunable = false
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("worktree ") { flush(); path = String(line.dropFirst(9)) }
            else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
            else if line.hasPrefix("branch ") {
                let full = String(line.dropFirst(7))
                branch = full.hasPrefix("refs/heads/") ? String(full.dropFirst(11)) : full
            }
            else if line == "bare" { bare = true }
            else if line.hasPrefix("locked") { locked = true }
            else if line.hasPrefix("prunable") { prunable = true }
        }
        flush()
        return result
    }

    // MARK: name-status (-z)

    /// Parses `git diff-tree -r -z --name-status -M` output.
    public static func parseNameStatus(_ output: String) -> [FileChange] {
        var result: [FileChange] = []
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < tokens.count {
            let code = tokens[i]
            i += 1
            guard let c = code.first else { continue }
            if c == "R" || c == "C" {
                guard i + 1 < tokens.count else { break }
                let old = tokens[i], new = tokens[i + 1]
                i += 2
                result.append(FileChange(path: new, oldPath: old, status: FileStatus(code: c), area: .staged))
            } else {
                guard i < tokens.count else { break }
                result.append(FileChange(path: tokens[i], status: FileStatus(code: c), area: .staged))
                i += 1
            }
        }
        return result
    }

    // MARK: stash list

    public static let stashFormat = "--format=%H%x1f%gd%x1f%s"

    public static func parseStashes(_ output: String) -> [Stash] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: fieldSep, maxSplits: 2, omittingEmptySubsequences: false)
            guard f.count == 3 else { return nil }
            return Stash(sha: String(f[0]), selector: String(f[1]), message: String(f[2]))
        }
    }

    // MARK: remotes (git remote -v)

    public static func parseRemotes(_ output: String) -> [Remote] {
        var seen = Set<String>()
        var result: [Remote] = []
        for line in output.split(separator: "\n") {
            let f = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard f.count >= 2 else { continue }
            let name = String(f[0])
            if seen.insert(name).inserted {
                result.append(Remote(name: name, url: String(f[1])))
            }
        }
        return result
    }
}
