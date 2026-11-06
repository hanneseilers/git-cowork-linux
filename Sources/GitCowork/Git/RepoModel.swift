import AppKit
import Foundation
import GitCoworkCore
import Observation

enum HistorySelection: Hashable {
    case workingCopy
    case commit(String)
}

struct WorktreeInfo: Hashable {
    var changes = 0
    var ahead = 0
    var behind = 0
}

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct Confirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    var destructive = true
    let action: () async -> Void
}

enum DiffTarget: Hashable {
    case working(FileChange)
    case commit(CommitDetail, FileChange)

    var file: FileChange {
        switch self {
        case .working(let f), .commit(_, let f): f
        }
    }
}

/// What the big middle area shows.
enum CenterMode: String, CaseIterable, Hashable {
    case history, board, reviews

    var title: String {
        switch self {
        case .history: "History"
        case .board: "Board"
        case .reviews: "Reviews"
        }
    }

    var symbol: String {
        switch self {
        case .history: "point.3.connected.trianglepath.dotted"
        case .board: "rectangle.split.3x1"
        case .reviews: "checkmark.bubble"
        }
    }
}

/// Selected task or review (shown in the right panel on Board / Reviews).
enum CoworkSelection: Hashable {
    case task(String)
    case review(String)
}

enum SheetKind: Identifiable {
    case newBranch(from: String, label: String)
    case newTag(sha: String)
    case renameBranch(String)
    case addWorktree(base: String?)
    case stash
    case newTask(status: TaskStatus)
    case requestReview(branch: String)
    case team

    var id: String {
        switch self {
        case .newBranch(let f, _): "branch:\(f)"
        case .newTag(let s): "tag:\(s)"
        case .renameBranch(let b): "rename:\(b)"
        case .addWorktree(let b): "wt:\(b ?? "")"
        case .stash: "stash"
        case .newTask(let s): "task:\(s.rawValue)"
        case .requestReview(let b): "review:\(b)"
        case .team: "team"
        }
    }
}

/// Resolves symlinks like realpath(3). Unlike URL.resolvingSymlinksInPath it keeps
/// /private, so paths match what git prints.
func realPath(_ path: String) -> String {
    guard let p = realpath(path, nil) else { return path }
    defer { free(p) }
    return String(cString: p)
}

/// State of one open worktree: refs, history, working copy, and the actions on it.
@MainActor @Observable
final class RepoModel {
    let root: URL
    let git = GitRunner.shared

    private(set) var gitDir: URL?
    private(set) var commonDir: URL?
    private(set) var loadError: String?
    private(set) var isLoaded = false

    // Repository data
    private(set) var commits: [Commit] = []
    private(set) var graph: [GraphRow] = []
    private(set) var commitIndex: [String: Int] = [:]
    private(set) var refs: [Ref] = []
    private(set) var refsByCommit: [String: [Ref]] = [:]
    private(set) var remoteDefaults: [String: String] = [:]
    private(set) var remotes: [Remote] = []
    private(set) var status = WorkingStatus()
    private(set) var worktrees: [Worktree] = []
    private(set) var worktreeInfo: [String: WorktreeInfo] = [:]
    /// Bumped whenever worktreeInfo changes (for views that aren't observing it directly).
    private(set) var worktreeInfoVersion = 0
    /// Per commit index: true when the commit is HEAD or one of its ancestors.
    /// GitKraken-style dimming of commits that aren't on the current branch.
    private(set) var headAncestry: [Bool] = []
    private(set) var stashes: [Stash] = []
    private(set) var operation: RepoOperation?
    private(set) var hasMoreCommits = false
    /// Bumped whenever history rows change, so the table knows to reload.
    private(set) var historyVersion = 0
    var commitLimit = 2000

    // UI state shared across views
    var selection: HistorySelection? = .workingCopy
    var revealToken = 0
    var filterText = ""
    var busy: String?
    var alert: AlertItem?
    var confirmation: Confirmation?
    var sheet: SheetKind?
    var openDiff: DiffTarget?
    var showCommandLog = false
    /// History graph, task board or review list in the middle.
    var centerMode: CenterMode = .history
    /// Task or review shown in the right panel while on Board / Reviews.
    var coworkSelection: CoworkSelection?
    /// Shared tasks, reviews and comments for this repository.
    let cowork: CoworkStore
    /// Commit message being written. Shared by the commit box and the "// WIP" row.
    var draftSummary = ""
    var draftDetails = ""
    /// Bump to move keyboard focus to the commit summary field.
    var focusSummaryToken = 0
    /// Bumped on every refresh; open working-copy diffs reload on it.
    private(set) var refreshCount = 0
    private var loadingMore = false

    private var fingerprint = ""
    private var watcher: FileWatcher?
    private var watchedPaths: [String] = []
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    private var debounce: Task<Void, Never>?

    init(root: URL) {
        // Resolve symlinks (/tmp -> /private/tmp) so paths match what git reports.
        self.root = URL(fileURLWithPath: realPath(root.path))
        self.cowork = CoworkStore(root: self.root)
    }

    var name: String { mainWorktreePath.map { ($0 as NSString).lastPathComponent } ?? root.lastPathComponent }
    var mainWorktreePath: String? { worktrees.first(where: \.isMain)?.path }
    var currentBranch: String? { status.branch }
    var headSHA: String? { status.headOID }
    var localBranches: [Ref] { refs.filter { $0.kind == .localBranch } }
    var remoteBranches: [Ref] { refs.filter { $0.kind == .remoteBranch } }
    var tags: [Ref] { refs.filter { $0.kind == .tag } }
    var currentRef: Ref? { refs.first { $0.kind == .localBranch && $0.isHead } }

    // MARK: Loading

    func load() async {
        do {
            let out = try await git.run(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], in: root)
            let lines = out.split(separator: "\n").map(String.init)
            guard lines.count >= 2 else { throw GitError(command: "rev-parse", result: GitResult(stdout: out, stderr: "Not a git repository", exitCode: 1)) }
            gitDir = URL(fileURLWithPath: lines[0])
            commonDir = URL(fileURLWithPath: lines[1])
        } catch {
            loadError = error.localizedDescription
            return
        }
        await refresh()
        isLoaded = true
        selection = status.isClean ? commits.first.map { .commit($0.id) } : .workingCopy
        // The window may have closed while loading; don't start anything then.
        guard !isStopped else { return }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
                if let self, Prefs.coworkAutoSync, (self.cowork.lastSync.map { Date().timeIntervalSince($0) > 30 } ?? true) { await self.syncCowork() }
            }
        }
        cowork.remote = await resolveCoworkRemote()
        updateKnownAuthors()
        await cowork.load()
        guard !isStopped else { return }
        startCoworkSync()
    }

    /// Called when the window closes: stops file watching, timers and observers.
    /// A cowork push already scheduled still finishes, so no edit stays local.
    func stopWatching() {
        isStopped = true
        watcher?.stop()
        watcher = nil
        coworkTimer?.cancel()
        coworkTimer = nil
        debounce?.cancel()
        debounce = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    private var isStopped = false
    private var activationObserver: NSObjectProtocol?

    // MARK: Cowork

    private var coworkTimer: Task<Void, Never>?

    /// Syncs tasks/reviews now, then every minute while the app is in front and
    /// every 3 minutes in the background, so teammates' mentions and review
    /// requests still arrive as notifications. Each sync is one small fetch of a
    /// single ref.
    private func startCoworkSync() {
        coworkTimer?.cancel()
        coworkTimer = Task { [weak self] in
            await self?.syncCowork()
            var lastSync = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                let interval: TimeInterval = NSApp.isActive ? 60 : 180
                guard Prefs.coworkAutoSync, Date().timeIntervalSince(lastSync) >= interval else { continue }
                lastSync = Date()
                await self.syncCowork()
            }
        }
    }

    /// Remote for cowork sync, independent of the checked-out branch (so a
    /// branch tracking a fork's `upstream` never sends the team's tasks there):
    /// the one chosen in Settings if it exists here, else the one picked
    /// for this repo before, else a remote that already has cowork data,
    /// else origin, else the first remote. The pick is remembered per repo.
    func resolveCoworkRemote() async -> String? {
        let names = remotes.map(\.name)
        if let r = Prefs.coworkRemote, names.contains(r) { return r }
        let key = "cowork.syncRemote." + (mainWorktreePath ?? root.path)
        if let r = UserDefaults.standard.string(forKey: key), names.contains(r) { return r }
        guard !names.isEmpty else { return nil }
        let out = await git.tryRun(["for-each-ref", "--format=%(refname)", "refs/cowork/remotes/"], in: root) ?? ""
        let withData = out.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: "/")    // refs/cowork/remotes/<r>/main
            return parts.count >= 5 ? parts[3...].dropLast().joined(separator: "/") : nil
        }
        let pick = (names.contains("origin") && withData.contains("origin") ? "origin" : nil)
            ?? withData.first { names.contains($0) }
            ?? (names.contains("origin") ? "origin" : names[0])
        UserDefaults.standard.set(pick, forKey: key)
        return pick
    }

    func syncCowork() async {
        cowork.remote = await resolveCoworkRemote()
        await cowork.sync()
        CoworkNotifier.shared.deliver(cowork.inbox, repo: mainWorktreePath ?? root.path, repoName: name)
    }

    private func updateKnownAuthors() {
        var seen = Set<String>()
        var authors: [(name: String, email: String)] = []
        for c in commits where seen.insert(c.authorEmail.lowercased()).inserted {
            authors.append((c.authorName, c.authorEmail))
        }
        cowork.knownAuthors = authors
    }

    /// Reloads everything that may have changed. Calls made while a refresh
    /// is running are merged into one more pass.
    /// When this returns, a full pass has run that started after the call
    /// (callers read status/refs right after a git command).
    func refresh() async {
        refreshPending = true
        if let running = refreshTask { await running.value; return }
        let task = Task { @MainActor in
            while refreshPending {
                refreshPending = false
                await refreshOnce()
            }
            refreshTask = nil   // same synchronous step as the last check, so no call slips in between
        }
        refreshTask = task
        await task.value
    }

    private func refreshOnce() async {
        defer { refreshCount += 1 }
        async let statusOut = git.tryRun(["status", "--porcelain=v2", "-z", "--branch", "-uall"], in: root)
        async let refsOut = git.tryRun(["for-each-ref", Parsers.refFormat, "refs/heads", "refs/remotes", "refs/tags"], in: root)
        async let stashOut = git.tryRun(["stash", "list", Parsers.stashFormat], in: root)
        async let worktreeOut = git.tryRun(["worktree", "list", "--porcelain"], in: root)
        async let remoteOut = git.tryRun(["remote", "-v"], in: root)

        let (s, r, st, wt, rem) = await (statusOut ?? "", refsOut ?? "", stashOut ?? "", worktreeOut ?? "", remoteOut ?? "")

        let newStatus = Parsers.parseStatus(s)
        if newStatus != status { status = newStatus }
        operation = detectOperation()

        let newRemotes = Parsers.parseRemotes(rem)
        if newRemotes != remotes { remotes = newRemotes }

        let fp = r + "|" + (newStatus.headOID ?? "") + "|" + st + "|\(commitLimit)"
        if fp != fingerprint {
            fingerprint = fp
            let list = Parsers.parseRefs(r)
            refs = list.refs
            remoteDefaults = list.remoteDefaults
            stashes = Parsers.parseStashes(st)
            await loadHistory()
        }

        let newWorktrees = Parsers.parseWorktrees(wt)
        if newWorktrees != worktrees {
            worktrees = newWorktrees
            restartWatcher()
            await refreshWorktreeInfo(paths: worktrees.map(\.path))
        } else {
            let info = WorktreeInfo(changes: status.changeCount, ahead: status.ahead, behind: status.behind)
            if worktreeInfo[root.path] != info {
                worktreeInfo[root.path] = info
                worktreeInfoVersion += 1
            }
        }
    }

    private func loadHistory() async {
        guard status.headOID != nil || !refs.isEmpty else {
            commits = []; graph = []; commitIndex = [:]; refsByCommit = [:]; headAncestry = []
            historyVersion += 1
            return
        }
        var args = ["log", "--date-order", "-n", "\(commitLimit)", Parsers.logFormat, "--branches", "--remotes", "--tags"]
        if status.headOID != nil { args.append("HEAD") }
        args.append("--")
        let out = await git.tryRun(args, in: root) ?? ""
        let (newCommits, newGraph) = await Task.detached(priority: .userInitiated) {
            let c = Parsers.parseLog(out)
            return (c, GraphLayout.layout(c))
        }.value

        var index: [String: Int] = [:]
        index.reserveCapacity(newCommits.count)
        for (i, c) in newCommits.enumerated() { index[c.id] = i }

        var byCommit: [String: [Ref]] = [:]
        for ref in refs { byCommit[ref.target, default: []].append(ref) }
        for key in byCommit.keys {
            byCommit[key]?.sort { a, b in
                if a.isHead != b.isHead { return a.isHead }
                if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
                return a.name < b.name
            }
        }

        // Mark HEAD and everything reachable from it through parents.
        var ancestry = [Bool](repeating: false, count: newCommits.count)
        if let head = status.headOID, let start = index[head] {
            var stack = [start]
            while let i = stack.popLast() {
                if ancestry[i] { continue }
                ancestry[i] = true
                for p in newCommits[i].parents {
                    if let j = index[p], !ancestry[j] { stack.append(j) }
                }
            }
        }

        commits = newCommits
        graph = newGraph
        headAncestry = ancestry
        commitIndex = index
        refsByCommit = byCommit
        hasMoreCommits = newCommits.count >= commitLimit
        historyVersion += 1
    }

    func loadMoreCommits() {
        // Only when the current limit has actually loaded; a refresh already
        // in flight must not let the limit grow several times.
        guard hasMoreCommits, !loadingMore, commits.count >= commitLimit else { return }
        loadingMore = true
        commitLimit += 3000
        Task {
            await refresh()
            loadingMore = false
        }
    }

    private func detectOperation() -> RepoOperation? {
        guard let dir = gitDir else { return nil }
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return nil
    }

    private func refreshWorktreeInfo(paths: [String]) async {
        await withTaskGroup(of: (String, WorktreeInfo?).self) { group in
            for path in paths {
                group.addTask { [git] in
                    guard let out = await git.tryRun(["status", "--porcelain=v2", "-z", "--branch"], in: URL(fileURLWithPath: path)) else {
                        return (path, nil)
                    }
                    let st = Parsers.parseStatus(out)
                    return (path, WorktreeInfo(changes: st.changeCount, ahead: st.ahead, behind: st.behind))
                }
            }
            // Collect first, then assign once: one view update instead of one per worktree.
            var updated = worktreeInfo
            for await (path, info) in group { updated[path] = info }
            if updated != worktreeInfo {
                worktreeInfo = updated
                worktreeInfoVersion += 1
            }
        }
    }

    // MARK: File watching

    private func restartWatcher() {
        var paths = [root.path]
        if let c = commonDir?.path { paths.append(c) }
        paths += worktrees.map(\.path).filter { !$0.isEmpty }
        // Drop duplicates and paths nested inside another watched path.
        let unique = Array(Set(paths)).sorted()
        let roots = unique.filter { p in !unique.contains { $0 != p && p.hasPrefix($0 + "/") } }
        guard roots != watchedPaths else { return }
        watchedPaths = roots
        watcher?.stop()
        watcher = FileWatcher(paths: roots) { [weak self] changed in
            MainActor.assumeIsolated { self?.handleFileEvents(changed) }
        }
    }

    private func handleFileEvents(_ paths: [String]) {
        let others = worktrees.map(\.path).filter { $0 != root.path }.sorted { $0.count > $1.count }
        var otherChanged = Set<String>()
        var needsFull = false
        var coworkChanged = false
        for p in paths {
            if p.contains("/.git/objects/") || p.hasSuffix(".lock") || p.contains("/.git/logs/") { continue }
            // Written by every fetch; nothing we show depends on it.
            if p.hasSuffix("/FETCH_HEAD") { continue }
            // Tasks and reviews (moved by this or another window): no graph refresh needed.
            if p.contains("/refs/cowork/") { coworkChanged = true; continue }
            let inGitDir = commonDir.map { p.hasPrefix($0.path) } ?? false
            if !inGitDir, let wt = others.first(where: { p == $0 || p.hasPrefix($0 + "/") }) {
                otherChanged.insert(wt)
                continue
            }
            needsFull = true
        }
        if !otherChanged.isEmpty {
            Task { await refreshWorktreeInfo(paths: Array(otherChanged)) }
        }
        if coworkChanged, cowork.loaded {
            Task { await cowork.reload() }
        }
        if needsFull {
            debounce?.cancel()
            debounce = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    // MARK: Lookups

    func commit(_ sha: String) -> Commit? {
        commitIndex[sha].map { commits[$0] }
    }

    func reveal(_ sha: String) {
        selection = .commit(sha)
        revealToken += 1
    }

    var defaultRemote: String? {
        if let up = status.upstream, let r = up.split(separator: "/").first { return String(r) }
        if remotes.contains(where: { $0.name == "origin" }) { return "origin" }
        return remotes.first?.name
    }

    func links(for remoteName: String?) -> RemoteLinks? {
        guard let name = remoteName ?? defaultRemote,
              let remote = remotes.first(where: { $0.name == name }) else { return nil }
        return RemoteLinks(remoteURL: remote.url, overrides: RemoteLinks.parseOverrides(Prefs.hostOverrides))
    }

    func defaultBranch(remote: String?) -> String? {
        remoteDefaults[remote ?? defaultRemote ?? "origin"]
    }

    // MARK: Details and diffs

    func commitDetail(_ sha: String) async -> CommitDetail? {
        guard let out = await git.tryRun(["show", "-s", Parsers.detailFormat, sha], in: root) else { return nil }
        return Parsers.parseCommitDetail(out)
    }

    func changedFiles(_ detail: CommitDetail) async -> [FileChange] {
        var args = ["diff-tree", "-r", "-z", "-M", "--name-status", "--no-commit-id"]
        if let p = detail.parents.first { args += [p, detail.id] } else { args += ["--root", detail.id] }
        return Parsers.parseNameStatus(await git.tryRun(args, in: root) ?? "")
    }

}
