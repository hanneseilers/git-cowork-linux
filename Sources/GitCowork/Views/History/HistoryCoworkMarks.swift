import AppKit
import GitCoworkCore

// Tasks and reviews linked to the branches on each commit.
extension HistoryTableCoordinator {

    /// Re-arms itself after each change, so this costs nothing while idle.
    func observeCowork() {
        withObservationTracking {
            _ = model.cowork.version
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshCoworkIfNeeded()
                self.observeCowork()
            }
        }
    }

    func refreshCoworkIfNeeded() {
        let v = model.cowork.version
        guard v != coworkVersion else { return }
        coworkVersion = v
        var tasks: [String: [CoworkTask]] = [:]
        for t in model.cowork.tasks {
            guard let b = t.branch, !b.isEmpty else { continue }
            tasks[b, default: []].append(t)
        }
        var reviews: [String: ReviewRequest] = [:]
        for r in model.cowork.reviews where r.status == .open && !r.branch.isEmpty {
            if let old = reviews[r.branch], old.updated > r.updated { continue }
            reviews[r.branch] = r
        }
        let changed = tasks != tasksByBranch || reviews != reviewByBranch
        tasksByBranch = tasks
        reviewByBranch = reviews
        coworkCache = [:]
        guard changed, let table else { return }
        table.enumerateAvailableRowViews { view, _ in (view as? HistoryRowView)?.redrawCells() }
    }

    /// Tasks and the open review linked to the branches on a commit.
    func cowork(forCommit i: Int) -> HistoryCoworkInfo {
        if let hit = coworkCache[i] { return hit }
        var info = HistoryCoworkInfo()
        if !tasksByBranch.isEmpty || !reviewByBranch.isEmpty {
            var seen = Set<String>()
            for badge in badges(forCommit: i) where badge.kind == .branch {
                for t in tasksByBranch[badge.name] ?? [] where seen.insert(t.id).inserted {
                    info.tasks.append(.init(id: t.id, title: t.title, statusTitle: t.status.label, color: NSColor(t.status.color)))
                }
                if info.review == nil, let r = reviewByBranch[badge.name] {
                    let v = r.overall
                    info.review = .init(branch: r.branch, symbol: v.symbol, title: v.title, color: NSColor(v.color))
                }
            }
        }
        coworkCache[i] = info
        return info
    }
}
