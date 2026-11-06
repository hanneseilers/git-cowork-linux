import AppKit
import GitCoworkCore

// Right-click menu on a row.
extension HistoryTableCoordinator {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
        let model = self.model
        let i: Int
        switch rows[table.clickedRow] {
        case .wip:
            let row = table.clickedRow
            menu.addItem(ActionItem("Write Commit Message") { [weak self] in _ = self?.focusSummaryIfWIP(row: row) })
            menu.addItem(ActionItem("Stash Changes…") { model.sheet = .stash })
            return
        case .otherWIP(let path):
            menu.addItem(ActionItem("Open in Terminal") { External.openTerminal(path) })
            menu.addItem(ActionItem("Open in Editor") { External.openEditor(path) })
            menu.addItem(ActionItem("Reveal in Finder") { External.reveal(path) })
            menu.addItem(.separator())
            menu.addItem(ActionItem("Copy Path") { External.copy(path) })
            return
        case .commit(let index):
            guard index < commits.count else { return }
            i = index
        }
        let commit = commits[i]
        let sha = commit.id
        let short = commit.shortID
        let current = model.currentBranch ?? "HEAD"
        let refs = refsByCommit[sha] ?? []

        // One group per branch badge: a local branch and its remote share items.
        for badge in badges(forCommit: i) where badge.kind == .branch {
            let local = refs.first { $0.kind == .localBranch && badge.refNames.contains($0.name) }
            let remote = refs.first { $0.kind == .remoteBranch && badge.refNames.contains($0.name) }
            if let local {
                if !local.isHead {
                    menu.addItem(ActionItem("Checkout \(local.name)") { Task { await model.checkout(local) } })
                }
            } else if let remote {
                // Remote-only here. If a local branch of that name exists elsewhere,
                // checking out switches to it, so say where it is.
                if let other = model.localBranches.first(where: { $0.name == badge.name }) {
                    if !other.isHead {
                        let at = other.target.prefix(7)
                        menu.addItem(ActionItem("Checkout \(other.name) (local, at \(at))") { Task { await model.checkout(other) } })
                    }
                } else {
                    menu.addItem(ActionItem("Checkout \(remote.name)") { Task { await model.checkout(remote) } })
                }
            }
            if !(local?.isHead ?? false) {
                let target = local?.name ?? remote?.name ?? badge.name
                menu.addItem(ActionItem("Merge \(target) into \(current)") { Task { await model.merge(target) } })
                menu.addItem(ActionItem("Rebase \(current) onto \(target)") { Task { await model.rebase(onto: target) } })
            }
            let branch = badge.name
            menu.addItem(ActionItem("Request Review of \(branch)…") { model.sheet = .requestReview(branch: branch) })
            for task in tasksByBranch[branch] ?? [] {
                let id = task.id
                menu.addItem(ActionItem("Open Task \(id)") {
                    model.centerMode = .board
                    model.coworkSelection = .task(id)
                })
            }
            menu.addItem(.separator())
        }

        menu.addItem(ActionItem("Checkout \(short) (detached)") { Task { await model.checkoutCommit(sha) } })
        menu.addItem(ActionItem("Create Branch Here…") { model.sheet = .newBranch(from: sha, label: short) })
        menu.addItem(ActionItem("Create Tag Here…") { model.sheet = .newTag(sha: sha) })
        menu.addItem(ActionItem("Create Worktree Here…") { model.sheet = .addWorktree(base: sha) })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Cherry-pick into \(current)") { Task { await model.cherryPick(sha) } })
        menu.addItem(ActionItem("Revert Commit") { Task { await model.revert(sha) } })

        let reset = NSMenuItem(title: "Reset \(current) to \(short)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(ActionItem("Soft – keep changes staged") { model.reset(to: sha, mode: .soft) })
        sub.addItem(ActionItem("Mixed – keep changes unstaged") { model.reset(to: sha, mode: .mixed) })
        sub.addItem(ActionItem("Hard – discard changes…") { model.reset(to: sha, mode: .hard) })
        reset.submenu = sub
        menu.addItem(reset)

        menu.addItem(.separator())
        menu.addItem(ActionItem("Copy SHA") { External.copy(sha) })
        menu.addItem(ActionItem("Copy Message") { External.copy(commit.subject) })
        if let links = model.links(for: nil), let url = links.commitURL(sha) {
            menu.addItem(ActionItem("Open Commit on \(links.host)") { External.browse(url) })
        }
    }
}

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
