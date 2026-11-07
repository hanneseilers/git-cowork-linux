import CoworkKit
import Foundation
import GitCoworkCore
import Observation

/// The app's view of the shared tasks/reviews on `refs/cowork/main`: the
/// decoded snapshot, edits shown before they're saved, and sync state.
/// Reading, writing and syncing the ref itself is `CoworkRepo` (CoworkKit),
/// shared with the `git-cowork` command-line tool.
@MainActor @Observable
final class CoworkStore {
    let root: URL
    /// The ref itself. `me` is filled in on load.
    private(set) var repo: CoworkRepo

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
        self.repo = CoworkRepo(root: root, git: AppGit())
    }

    // MARK: Reading

    func load() async {
        if me.email.isEmpty {
            me = await CoworkRepo.identity(root: root, git: repo.git)
            repo.me = me
        }
        await reload()
        loaded = true
    }

    /// Re-reads the local ref if it moved (or always, with `force`). Edits
    /// still being written are applied on top, so the UI never flickers back.
    func reload(force: Bool = false) async {
        let tip = await repo.tip()
        guard tip != localTip || !loaded || force else { return }
        localTip = tip
        var snap = CoworkSnapshot()
        if let tip {
            let files = await repo.readAll(at: tip)
            snap = await Task.detached { CoworkCodec.decode(files: files) }.value
        }
        for p in pending { p.change(&snap) }
        snapshot = snap
        version += 1
    }

    // MARK: Writing

    /// An edit shown in `snapshot` right away, before its commit is written.
    private struct PendingEdit {
        let token: Int
        let change: (inout CoworkSnapshot) -> Void
    }
    private var pending: [PendingEdit] = []
    private var nextToken = 0
    private var writeChain: Task<Bool, Never>?

    /// Writes one edit (see CoworkEdit) as a commit, then pushes in the
    /// background. `optimistic` shows the edit in `snapshot` until the write
    /// lands. Writes run one at a time, in call order. Returns false on failure.
    @discardableResult
    func write(_ edit: CoworkWrite, optimistic: ((inout CoworkSnapshot) -> Void)? = nil) async -> Bool {
        nextToken += 1
        let token = nextToken
        if let optimistic {
            pending.append(PendingEdit(token: token, change: optimistic))
            optimistic(&snapshot)
            version += 1
        }
        let previous = writeChain
        let repo = repo
        let task = Task { @MainActor in
            _ = await previous?.value
            do {
                try await repo.apply(edit)
                return true
            } catch {
                self.syncError = error.localizedDescription
                return false
            }
        }
        writeChain = task
        let ok = await task.value
        let hadPending = pending.contains { $0.token == token }
        pending.removeAll { $0.token == token }
        await reload(force: hadPending)
        if ok { schedulePush() }
        return ok
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
