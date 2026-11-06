import GitCoworkCore
import SwiftUI

/// Right-click menu for any sidebar item.
struct SidebarMenu: View {
    let model: RepoModel
    let id: String
    let openHere: (String) -> Void
    let openInNewTab: (String) -> Void

    var body: some View {
        if id.hasPrefix("ref:"), let ref = model.refs.first(where: { "ref:" + $0.fullName == id }) {
            switch ref.kind {
            case .localBranch: localBranch(ref)
            case .remoteBranch: remoteBranch(ref)
            case .tag: tag(ref)
            }
        } else if id.hasPrefix("wt:"), let wt = model.worktrees.first(where: { "wt:" + $0.path == id }) {
            worktree(wt)
        } else if id.hasPrefix("stash:"), let s = model.stashes.first(where: { "stash:" + $0.selector == id }) {
            Button("Apply") { Task { await model.applyStash(s) } }
            Button("Pop") { Task { await model.popStash(s) } }
            Divider()
            Button("Delete…", role: .destructive) { model.dropStash(s) }
        } else if id.hasPrefix("task:"), let task = model.cowork.task(String(id.dropFirst(5))) {
            Button("Open Task") { openTask(task.id) }
            if let branch = task.branch, let ref = model.localBranches.first(where: { $0.name == branch }), !ref.isHead {
                if let wt = model.sidebarOtherWorktree(for: branch) {
                    Button("Open Worktree for \(branch)") { openHere(wt.path) }
                } else {
                    Button("Checkout \(branch)") { Task { await model.checkout(ref) } }
                }
            }
            Divider()
            Button("Copy ID") { External.copy(task.id) }
        } else if id.hasPrefix("review:"), let review = model.cowork.review(String(id.dropFirst(7))) {
            Button("Open Review") {
                model.centerMode = .reviews
                model.coworkSelection = .review(review.id)
            }
            if let taskID = review.taskID {
                Button("Open Task \(taskID)") { openTask(taskID) }
            }
            Divider()
            Button("Copy Branch Name") { External.copy(review.branch) }
        }
    }

    private var current: String { model.currentBranch ?? "HEAD" }

    @ViewBuilder
    private func localBranch(_ ref: Ref) -> some View {
        // A branch checked out in another worktree can't be switched to or deleted here.
        let otherWorktree = model.sidebarOtherWorktree(for: ref.name)
        if let wt = otherWorktree {
            Button("Open Worktree") { openHere(wt.path) }
            Button("Open Worktree in New Tab") { openInNewTab(wt.path) }
            Divider()
            Button("Merge \(ref.name) into \(current)") { Task { await model.merge(ref.name) } }
            Button("Rebase \(current) onto \(ref.name)") { Task { await model.rebase(onto: ref.name) } }
            Divider()
        } else if !ref.isHead {
            Button("Checkout") { Task { await model.checkout(ref) } }
            Button("Merge \(ref.name) into \(current)") { Task { await model.merge(ref.name) } }
            Button("Rebase \(current) onto \(ref.name)") { Task { await model.rebase(onto: ref.name) } }
            Divider()
        } else {
            Button("Pull") { Task { await model.pull() } }
            Button("Push") { Task { await model.push() } }
            Divider()
        }
        Button("New Branch from \(ref.name)…") { model.sheet = .newBranch(from: ref.name, label: ref.name) }
        // Git won't add a second worktree for a branch that is already checked out somewhere.
        if !model.worktrees.contains(where: { $0.branch == ref.name }) {
            Button("Create Worktree…") { model.sheet = .addWorktree(base: ref.name) }
        }
        Button("Rename…") { model.sheet = .renameBranch(ref.name) }
        if otherWorktree != nil {
            Button("Delete… (checked out in a worktree)") {}.disabled(true)
        } else if !ref.isHead {
            Button("Delete…", role: .destructive) { model.deleteBranch(ref) }
        }
        Divider()
        cowork(branch: ref.name)
        hostLinks(branch: ref.name, remote: ref.upstream?.split(separator: "/").first.map(String.init))
        Button("Copy Name") { External.copy(ref.name) }
    }

    @ViewBuilder
    private func remoteBranch(_ ref: Ref) -> some View {
        let local = ref.branchNameWithoutRemote
        if let wt = model.sidebarOtherWorktree(for: local) {
            Button("Open Worktree for \(local)") { openHere(wt.path) }
        } else {
            Button("Checkout as Local Branch") { Task { await model.checkout(ref) } }
        }
        Button("Merge \(ref.name) into \(current)") { Task { await model.merge(ref.name) } }
        Button("Rebase \(current) onto \(ref.name)") { Task { await model.rebase(onto: ref.name) } }
        Divider()
        Button("Create Worktree…") { model.sheet = .addWorktree(base: ref.name) }
        Button("New Branch from \(ref.name)…") { model.sheet = .newBranch(from: ref.name, label: ref.name) }
        Divider()
        cowork(branch: local)
        hostLinks(branch: local, remote: ref.remoteName)
        Button("Copy Name") { External.copy(ref.name) }
        Divider()
        Button("Delete on \(ref.remoteName ?? "remote")…", role: .destructive) { model.deleteBranch(ref) }
    }

    /// "Request Review…" and "Open Task CW-…" for tasks linked to the branch.
    @ViewBuilder
    private func cowork(branch: String) -> some View {
        Button("Request Review…") { model.sheet = .requestReview(branch: branch) }
        ForEach(model.sidebarTasks(forBranch: branch)) { task in
            Button("Open Task \(task.id)") { openTask(task.id) }
        }
        Divider()
    }

    private func openTask(_ id: String) {
        openCoworkTarget("tasks/\(id)", model: model)
    }

    @ViewBuilder
    private func tag(_ ref: Ref) -> some View {
        Button("Checkout (detached)") { Task { await model.checkout(ref) } }
        Button("Push Tag") { Task { await model.pushTag(ref.name) } }
        Button("Copy Name") { External.copy(ref.name) }
        Divider()
        Button("Delete…", role: .destructive) { model.deleteTag(ref.name) }
    }

    @ViewBuilder
    private func worktree(_ wt: Worktree) -> some View {
        if !model.sidebarIsCurrent(wt) {
            Button("Open Here") { openHere(wt.path) }
            Button("Open in New Tab") { openInNewTab(wt.path) }
            Divider()
        }
        Button("Open in Terminal") { External.openTerminal(wt.path) }
        Button("Open in Editor") { External.openEditor(wt.path) }
        Button("Reveal in Finder") { External.reveal(wt.path) }
        Button("Copy Path") { External.copy(wt.path) }
        if let branch = wt.branch {
            Divider()
            hostLinks(branch: branch, remote: nil)
        }
        if !wt.isMain {
            Divider()
            Button("Prune Stale Worktrees") { Task { await model.pruneWorktrees() } }
            Button("Remove Worktree…", role: .destructive) { model.removeWorktree(wt) }
                .disabled(model.sidebarIsCurrent(wt))
        }
    }

    @ViewBuilder
    private func hostLinks(branch: String, remote: String?) -> some View {
        if let links = model.links(for: remote) {
            let base = model.baseBranch()?.name
            if branch != base, let url = links.newPullRequestURL(branch: branch, base: base) {
                Button("Create \(links.pullRequestTerm) on \(links.host)") { External.browse(url) }
            }
            if let url = links.branchURL(branch) {
                Button("Open Branch on \(links.host)") { External.browse(url) }
            }
        }
    }
}
