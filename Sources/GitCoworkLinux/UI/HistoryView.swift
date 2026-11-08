import CGtk
import Foundation
import GitCoworkCore

/// The commit graph: lane-colored rows, author initials in the nodes, branch
/// badges, a "// WIP" row for this and every other dirty worktree, commits
/// outside the current branch dimmed. Drawn with Cairo, only visible rows,
/// so it stays fast with tens of thousands of commits.
@MainActor
final class HistoryView {
    enum Row: Equatable {
        case wip
        case otherWIP(String)
        case commit(Int)
    }

    struct Badge {
        enum Kind { case branch, tag }
        let name: String
        let kind: Kind
        var isHead = false
        var isLocal = false
        var isRemote = false
        var refNames: [String]
    }

    let root = Box.v(0)
    unowned let page: RepoPage
    private var model: RepoModel { page.model }

    private let filterEntry = Entry(placeholder: L("Filter commits (message, author, SHA)"), search: true)
    private let countLabel = Label("", "dim-label", "caption")
    private let canvas = Canvas()
    private let scrollbar = Scrollbar()

    private var rows: [Row] = []
    private var badgeCache: [Int: [Badge]] = [:]
    private var hoverRow: Int?
    private var lastReveal = -1
    private var filtering = false

    static let rowHeight: Double = 34
    static let laneWidth: Double = 24
    static let graphInset: Double = 6
    static let nodeRadius: Double = 10
    static let maxGraphWidth: Double = 360

    init(page: RepoPage) {
        self.page = page
        let header = Box.h(8)
        header.css("gc-panel-header")
        filterEntry.hexpand()
        filterEntry.onChanged { [weak self] in
            guard let self else { return }
            self.model.filterText = self.filterEntry.text
        }
        header.append(filterEntry)
        header.append(countLabel)
        root.append(header)

        let body = Box.h(0)
        canvas.hexpand().vexpand()
        canvas.label(L("Commit history"))
        body.append(canvas)
        body.append(scrollbar)
        body.vexpand()
        root.append(body)

        canvas.draw = { [weak self] cr, w, h in self?.paint(cr, w, h) }
        scrollbar.onChanged { [weak self] in
            self?.canvas.queueDraw()
            self?.maybeLoadMore()
        }
        canvas.onScroll { [weak self] _, dy in
            guard let self else { return false }
            self.scrollbar.value += dy * Self.rowHeight * 1.5
            return true
        }
        canvas.onMotion({ [weak self] _, y in
            guard let self else { return }
            let r = self.row(at: y)
            if r != self.hoverRow { self.hoverRow = r; self.canvas.queueDraw() }
        }, leave: { [weak self] in
            self?.hoverRow = nil
            self?.canvas.queueDraw()
        })
        canvas.onClick(button: 1) { [weak self] _, count, _, y in
            guard let self, let r = self.row(at: y) else { return }
            self.canvas.grabFocus()
            self.select(r)
            if count == 2, case .otherWIP(let path) = self.rows[r] { self.page.openInNewTab(path) }
        }
        canvas.onContextMenu { [weak self] x, y in
            guard let self, let r = self.row(at: y) else { return }
            self.select(r)
            self.contextMenu(r, x: x, y: y)
        }
        canvas.onKey { [weak self] key, _ in
            guard let self else { return false }
            switch Int32(key) {
            case GDK_KEY_Up: self.moveSelection(-1); return true
            case GDK_KEY_Down: self.moveSelection(1); return true
            case GDK_KEY_Page_Up: self.moveSelection(-15); return true
            case GDK_KEY_Page_Down: self.moveSelection(15); return true
            default: return false
            }
        }
        Signal.onIntInt(canvas.raw, "resize") { [weak self] _, _ in self?.updateScrollbar() }

        root.track { [weak self] in self?.reload() }
    }

    func focusFilter() { filterEntry.grabFocus() }

    // MARK: Data

    private func reload() {
        let m = model
        _ = m.historyVersion
        _ = m.worktreeInfoVersion
        let status = m.status
        let filter = m.filterText.trimmingCharacters(in: .whitespaces).lowercased()
        if filterEntry.text != m.filterText { filterEntry.text = m.filterText }
        _ = m.selection
        _ = m.cowork.version

        badgeCache = [:]
        filtering = !filter.isEmpty
        var newRows: [Row] = []
        if filter.isEmpty {
            if !status.isClean || status.headOID == nil { newRows.append(.wip) }
            for wt in m.worktrees where wt.path != m.root.path {
                if (m.worktreeInfo[wt.path]?.changes ?? 0) > 0 { newRows.append(.otherWIP(wt.path)) }
            }
            newRows += m.commits.indices.map { .commit($0) }
        } else {
            for (i, c) in m.commits.enumerated() where
                c.subject.lowercased().contains(filter) || c.authorName.lowercased().contains(filter)
                || c.authorEmail.lowercased().contains(filter) || c.id.hasPrefix(filter) || c.bodyPreview.lowercased().contains(filter) {
                newRows.append(.commit(i))
            }
        }
        rows = newRows
        countLabel.text = m.hasMoreCommits
            ? String(localized: "\(m.commits.count)+ commits")
            : String(localized: "\(m.commits.count) commits")
        updateScrollbar()
        if m.revealToken != lastReveal {
            lastReveal = m.revealToken
            revealSelection()
        }
        canvas.queueDraw()
    }

    private func updateScrollbar() {
        let h = Double(max(canvas.height, 1))
        scrollbar.configure(upper: Double(rows.count) * Self.rowHeight, page: h, step: Self.rowHeight)
    }

    private func maybeLoadMore() {
        let h = Double(canvas.height)
        if scrollbar.value + h > Double(rows.count - 50) * Self.rowHeight, model.hasMoreCommits, !filtering {
            model.loadMoreCommits()
        }
    }

    private func row(at y: Double) -> Int? {
        let r = Int((y + scrollbar.value) / Self.rowHeight)
        return rows.indices.contains(r) ? r : nil
    }

    private func selectedRow() -> Int? {
        switch model.selection {
        case .workingCopy?: return rows.firstIndex(of: .wip)
        case .commit(let sha)?:
            guard let i = model.commitIndex[sha] else { return nil }
            return rows.firstIndex(of: .commit(i))
        case nil: return nil
        }
    }

    private func select(_ r: Int) {
        switch rows[r] {
        case .wip: model.selection = .workingCopy
        case .otherWIP: break
        case .commit(let i): model.selection = .commit(model.commits[i].id)
        }
        model.openDiff = nil
        canvas.queueDraw()
    }

    private func moveSelection(_ step: Int) {
        let current = selectedRow() ?? -1
        var r = max(0, min(rows.count - 1, current + step))
        if case .otherWIP = rows[safe: r] ?? .wip { r = max(0, min(rows.count - 1, r + (step > 0 ? 1 : -1))) }
        guard rows.indices.contains(r) else { return }
        select(r)
        scrollTo(r)
    }

    private func revealSelection() {
        if let r = selectedRow() { scrollTo(r, center: true) }
    }

    private func scrollTo(_ r: Int, center: Bool = false) {
        let h = Double(canvas.height)
        let top = Double(r) * Self.rowHeight
        if center {
            scrollbar.value = max(0, top - h / 2)
        } else if top < scrollbar.value {
            scrollbar.value = top
        } else if top + Self.rowHeight > scrollbar.value + h {
            scrollbar.value = top + Self.rowHeight - h
        }
        canvas.queueDraw()
    }

    private func badges(_ i: Int) -> [Badge] {
        if let hit = badgeCache[i] { return hit }
        let refs = model.refsByCommit[model.commits[i].id] ?? []
        let b = refs.isEmpty ? [] : Self.makeBadges(refs, remoteNames: model.remotes.map(\.name))
        badgeCache[i] = b
        return b
    }

    /// A local branch and its remote share one badge; checked-out first, then local, remote-only, tags.
    static func makeBadges(_ refs: [Ref], remoteNames: [String]) -> [Badge] {
        var badges: [Badge] = []
        for ref in refs where ref.kind == .localBranch {
            badges.append(Badge(name: ref.name, kind: .branch, isHead: ref.isHead, isLocal: true, refNames: [ref.name]))
        }
        for ref in refs where ref.kind == .remoteBranch {
            let short = ref.branchNameWithoutRemote
            if short == "HEAD" { continue }
            let upstreamOwner = refs.first { $0.kind == .localBranch && $0.upstream == ref.name }?.name
            if let i = badges.firstIndex(where: { $0.kind == .branch && ($0.name == short || $0.name == upstreamOwner) }) {
                badges[i].isRemote = true
                badges[i].refNames.append(ref.name)
            } else {
                badges.append(Badge(name: remoteNames.count > 1 ? ref.name : short, kind: .branch, isRemote: true, refNames: [ref.name]))
            }
        }
        for ref in refs where ref.kind == .tag {
            badges.append(Badge(name: ref.name, kind: .tag, refNames: [ref.name]))
        }
        func rank(_ b: Badge) -> Int { b.isHead ? 0 : b.kind == .tag ? 3 : b.isLocal ? 1 : 2 }
        return badges.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    // MARK: Painting

    private func graphWidth() -> Double {
        if filtering { return Self.graphInset * 2 + Self.laneWidth }
        let lanes = model.graph.map(\.laneCount).max() ?? 1
        return min(Self.maxGraphWidth, max(60, Self.graphInset * 2 + Double(lanes) * Self.laneWidth))
    }

    private func laneX(_ lane: Int) -> Double { Self.graphInset + Double(lane) * Self.laneWidth + Self.laneWidth / 2 }

    private func paint(_ cr: OpaquePointer, _ width: Double, _ height: Double) {
        let p = Painter(cr: cr)
        p.rect(0, 0, width, height, Theme.background)
        guard !rows.isEmpty else {
            p.text(model.isLoaded ? L("No commits yet") : L("Loading…"), x: width / 2, midY: 40, color: Theme.secondaryText, align: 0.5)
            return
        }
        let gw = graphWidth()
        let dateW = 110.0, authorW = min(150.0, width * 0.14), shaW = 70.0
        let msgX = gw + 8
        let msgW = max(80, width - msgX - authorW - dateW - shaW - 24)
        let offset = scrollbar.value
        let first = max(0, Int(offset / Self.rowHeight))
        let last = min(rows.count - 1, Int((offset + height) / Self.rowHeight) + 1)
        let selected = selectedRow()
        guard first <= last else { return }

        for r in first...last {
            let top = Double(r) * Self.rowHeight - offset
            let mid = top + Self.rowHeight / 2
            let row = rows[r]
            var dim = false
            var laneColor = Theme.lane(0)
            if case .commit(let i) = row, i < model.graph.count {
                laneColor = Theme.lane(model.graph[i].color)
                dim = !filtering && i < model.headAncestry.count && !model.headAncestry[i]
            }
            // Row band
            if r == selected {
                p.rect(0, top + 1, width, Self.rowHeight - 2, Theme.accent.alpha(Theme.dark ? 0.35 : 0.18))
            } else if r == hoverRow {
                p.rect(0, top, width, Self.rowHeight, Theme.hover)
            }
            // Graph
            p.clip(0, top, gw, Self.rowHeight)
            drawGraph(p, row: row, rowIndex: r, top: top, dim: dim)
            p.restore()

            let textColor = dim ? Theme.text.alpha(0.45) : Theme.text
            let secondary = dim ? Theme.secondaryText.alpha(0.3) : Theme.secondaryText
            switch row {
            case .wip:
                let counts = ChangeCounts(model.status.staged + model.status.unstaged + model.status.untracked + model.status.conflicted)
                var x = msgX
                x += p.text("// WIP", x: x, midY: mid, font: "Sans Italic 10", color: Theme.secondaryText) + 10
                let draft = model.draftSummary.isEmpty ? L("Uncommitted changes") : model.draftSummary
                x += p.text(draft, x: x, midY: mid, maxWidth: msgW * 0.6, color: textColor) + 12
                drawCounts(p, counts, x: x, mid: mid)
            case .otherWIP(let path):
                var x = msgX
                x += p.text("// WIP", x: x, midY: mid, font: "Sans Italic 10", color: Theme.secondaryText) + 10
                let wt = model.worktrees.first { $0.path == path }
                let name = (path as NSString).lastPathComponent + (wt?.branch.map { " · \($0)" } ?? "")
                x += p.text(String(localized: "in \(name)"), x: x, midY: mid, maxWidth: msgW * 0.7, color: secondary) + 12
                if let n = model.worktreeInfo[path]?.changes {
                    p.text("●\(n)", x: x, midY: mid, color: Theme.orange)
                }
            case .commit(let i):
                let c = model.commits[i]
                var x = msgX
                for b in badges(i) {
                    guard x < msgX + msgW * 0.6 else { break }
                    x += drawBadge(p, b, x: x, mid: mid, color: laneColor, dim: dim) + 4
                }
                let subjectW = msgX + msgW - x
                if subjectW > 20 {
                    let w = p.text(c.subject, x: x, midY: mid, maxWidth: subjectW, color: textColor)
                    if !c.bodyPreview.isEmpty, subjectW - w > 60 {
                        p.text("   " + c.bodyPreview, x: x + w, midY: mid, maxWidth: subjectW - w, color: secondary)
                    }
                }
                let ax = msgX + msgW + 8
                p.text(c.authorName, x: ax, midY: mid, maxWidth: authorW - 8, color: secondary)
                p.text(relativeDate(c.date), x: ax + authorW, midY: mid, maxWidth: dateW - 8, color: secondary)
                p.text(c.shortID, x: ax + authorW + dateW, midY: mid, font: "Monospace 9", color: secondary)
            }
        }
    }

    private func drawCounts(_ p: Painter, _ c: ChangeCounts, x: Double, mid: Double) {
        var x = x
        for (n, sym, color) in [(c.modified, "~", Theme.orange), (c.added, "+", Theme.green), (c.deleted, "−", Theme.red),
                                (c.renamed, "→", Theme.blue), (c.conflicted, "!", Theme.pink)] where n > 0 {
            x += p.text("\(sym)\(n)", x: x, midY: mid, color: color, bold: true) + 8
        }
    }

    private func drawBadge(_ p: Painter, _ b: Badge, x: Double, mid: Double, color: RGBA, dim: Bool) -> Double {
        let h = 20.0
        let label = b.kind == .tag ? "🏷 " + b.name : (b.isHead ? "✓ " : "") + b.name + (b.isLocal && b.isRemote ? " ☁" : "")
        let w = min(220, Painter.measure(label, font: "Sans 9", bold: true, cr: p.cr) + 12)
        let alpha = dim ? 0.5 : 1.0
        if b.kind == .tag {
            p.roundRect(x, mid - h / 2, w, h, radius: 5, fill: Theme.background, stroke: Theme.secondaryText.alpha(alpha), lineWidth: 1)
            p.text(label, x: x + 6, midY: mid, maxWidth: w - 10, font: "Sans 9", color: Theme.text.alpha(alpha), bold: true)
        } else if b.isLocal {
            let fill = color.mix(RGBA(0, 0, 0), 0.2).alpha(alpha)
            p.roundRect(x, mid - h / 2, w, h, radius: 5, fill: fill)
            p.text(label, x: x + 6, midY: mid, maxWidth: w - 10, font: "Sans 9", color: fill.readableText, bold: true)
        } else {
            p.roundRect(x, mid - h / 2, w, h, radius: 5, fill: color.alpha(0.18 * alpha), stroke: color.alpha(0.6 * alpha))
            p.text(label, x: x + 6, midY: mid, maxWidth: w - 10, font: "Sans 9", color: Theme.text.alpha(0.8 * alpha), bold: true)
        }
        return w
    }

    private func drawGraph(_ p: Painter, row: Row, rowIndex r: Int, top: Double, dim: Bool) {
        let mid = top + Self.rowHeight / 2, bottom = top + Self.rowHeight
        func y(_ a: GraphLine.Anchor) -> Double { a == .top ? top : a == .middle ? mid : bottom }
        let lineAlpha = dim ? 0.45 : 1.0

        switch row {
        case .wip, .otherWIP:
            // Lines of the commit below pass through; a dashed node sits on HEAD's lane.
            let headLane = headNode()?.lane ?? 0
            let headColor = Theme.lane(headNode()?.color ?? 0)
            if let next = nextCommitRow(after: r), let g = model.graph[safe: next] {
                for line in g.lines where line.from == .top {
                    p.line(laneX(line.fromLane), top, laneX(line.fromLane), bottom, Theme.lane(line.color).alpha(0.5), width: 2.5)
                }
                _ = g
            }
            let x = laneX(row == .wip ? headLane : headLane)
            if row == .wip {
                p.line(x, mid, x, bottom, headColor, width: 2, dash: [3, 2.5])
            }
            p.circle(x, mid, Self.nodeRadius - 3, fill: Theme.background, stroke: headColor, lineWidth: 2)
            p.text(row == .wip ? "✎" : "↗", x: x, midY: mid, font: "Sans 8", color: headColor, align: 0.5)
        case .commit(let i):
            guard !filtering, let g = model.graph[safe: i] else {
                let c = model.commits[i]
                drawNode(p, x: laneX(0), mid: mid, commit: c, laneColor: Theme.lane(0), isMerge: c.isMerge, isHead: c.id == model.headSHA, dim: dim)
                return
            }
            for line in g.lines {
                let c = Theme.lane(line.color).alpha(lineAlpha)
                let x1 = laneX(line.fromLane), x2 = laneX(line.toLane)
                if x1 == x2 {
                    p.line(x1, y(line.from), x2, y(line.to), c, width: 2.5)
                } else {
                    p.bend(from: x1, y(line.from), to: x2, y(line.to), c, width: 2.5, radius: 10)
                }
            }
            let c = model.commits[i]
            drawNode(p, x: laneX(g.lane), mid: mid, commit: c, laneColor: Theme.lane(g.color), isMerge: c.isMerge,
                     isHead: c.id == model.headSHA, dim: dim)
        }
    }

    private func drawNode(_ p: Painter, x: Double, mid: Double, commit c: Commit, laneColor: RGBA, isMerge: Bool, isHead: Bool, dim: Bool) {
        let alpha = dim ? 0.45 : 1.0
        if isHead {
            p.circle(x, mid, Self.nodeRadius + 2.5, fill: nil, stroke: Theme.text.alpha(0.8), lineWidth: 2)
        }
        if isMerge {
            p.circle(x, mid, 4.5, fill: laneColor.alpha(alpha))
            return
        }
        let person = Theme.personColor(c.authorEmail).alpha(alpha)
        p.circle(x, mid, Self.nodeRadius, fill: person, stroke: laneColor.alpha(alpha), lineWidth: 2)
        p.text(c.authorName.initials, x: x, midY: mid, font: "Sans 7", color: person.readableText.alpha(alpha), bold: true, align: 0.5)
    }

    private func headNode() -> (lane: Int, color: Int)? {
        guard let head = model.headSHA, let i = model.commitIndex[head], let g = model.graph[safe: i] else { return nil }
        return (g.lane, g.color)
    }

    private func nextCommitRow(after r: Int) -> Int? {
        for k in (r + 1)..<rows.count { if case .commit(let i) = rows[k] { return i } }
        return nil
    }

    // MARK: Context menu

    private func contextMenu(_ r: Int, x: Double, y: Double) {
        let m = model
        var items: [MenuItem] = []
        switch rows[r] {
        case .wip:
            items = [MenuItem(L("Write Commit Message")) { [weak self] in self?.page.inspector.focusSummary() },
                     MenuItem(L("Stash Changes…")) { m.sheet = .stash }]
        case .otherWIP(let path):
            items = [MenuItem(L("Open in New Tab")) { [weak self] in self?.page.openInNewTab(path) },
                     MenuItem(L("Open in Terminal")) { External.openTerminal(path) },
                     MenuItem(L("Open in Editor")) { External.openEditor(path) },
                     MenuItem(L("Show in File Manager")) { External.reveal(path) },
                     .separator,
                     MenuItem(L("Copy Path")) { External.copy(path) }]
        case .commit(let i):
            let commit = m.commits[i]
            let sha = commit.id, short = commit.shortID
            let current = m.currentBranch ?? "HEAD"
            let refs = m.refsByCommit[sha] ?? []
            for badge in badges(i) where badge.kind == .branch {
                let local = refs.first { $0.kind == .localBranch && badge.refNames.contains($0.name) }
                let remote = refs.first { $0.kind == .remoteBranch && badge.refNames.contains($0.name) }
                if let local {
                    if !local.isHead { items.append(MenuItem(String(localized: "Checkout \(local.name)")) { [weak self] in self?.page.run { await $0.checkout(local) } }) }
                } else if let remote {
                    if let other = m.localBranches.first(where: { $0.name == badge.name }) {
                        if !other.isHead {
                            let at = String(other.target.prefix(7))
                            items.append(MenuItem(String(localized: "Checkout \(other.name) (local, at \(at))")) { [weak self] in self?.page.run { await $0.checkout(other) } })
                        }
                    } else {
                        items.append(MenuItem(String(localized: "Checkout \(remote.name)")) { [weak self] in self?.page.run { await $0.checkout(remote) } })
                    }
                }
                if !(local?.isHead ?? false) {
                    let target = local?.name ?? remote?.name ?? badge.name
                    items.append(MenuItem(String(localized: "Merge \(target) into \(current)")) { [weak self] in self?.page.run { await $0.merge(target) } })
                    items.append(MenuItem(String(localized: "Rebase \(current) onto \(target)")) { [weak self] in self?.page.run { await $0.rebase(onto: target) } })
                }
                let branch = badge.name
                items.append(MenuItem(String(localized: "Request Review of \(branch)…")) { m.sheet = .requestReview(branch: branch) })
                for t in m.cowork.tasks where t.branch == branch {
                    items.append(MenuItem(String(localized: "Open Task \(t.id)")) { [weak self] in
                        self?.page.setMode(.board); m.coworkSelection = .task(t.id)
                    })
                }
                items.append(.separator)
            }
            items += [
                MenuItem(String(localized: "Checkout \(short) (detached)")) { [weak self] in self?.page.run { await $0.checkoutCommit(sha) } },
                MenuItem(L("Create Branch Here…")) { m.sheet = .newBranch(from: sha, label: short) },
                MenuItem(L("Create Tag Here…")) { m.sheet = .newTag(sha: sha) },
                MenuItem(L("Create Worktree Here…")) { m.sheet = .addWorktree(base: sha) },
                .separator,
                MenuItem(String(localized: "Cherry-pick into \(current)")) { [weak self] in self?.page.run { await $0.cherryPick(sha) } },
                MenuItem(L("Revert Commit")) { [weak self] in self?.page.run { await $0.revert(sha) } },
                .header(String(localized: "Reset \(current) to \(short)")),
                MenuItem(L("Soft – keep changes staged")) { m.reset(to: sha, mode: .soft) },
                MenuItem(L("Mixed – keep changes unstaged")) { m.reset(to: sha, mode: .mixed) },
                MenuItem(L("Hard – discard changes…"), destructive: true) { m.reset(to: sha, mode: .hard) },
                .separator,
                MenuItem(L("Copy SHA")) { External.copy(sha) },
                MenuItem(L("Copy Message")) { External.copy(commit.subject) },
            ]
            if let links = m.links(for: nil), let url = links.commitURL(sha) {
                items.append(MenuItem(String(localized: "Open Commit on \(links.host)")) { External.browse(url) })
            }
        }
        Menus.popup(items, at: x, y, in: canvas)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
