import AppKit
import GitCoworkCore
import SwiftUI

/// Commit history with the branch graph. Backed by NSTableView so it stays
/// smooth with tens of thousands of rows; cells draw themselves directly.
struct HistoryTable: NSViewRepresentable {
    let model: RepoModel
    // Passed in explicitly so SwiftUI calls updateNSView when they change.
    let version: Int
    let filter: String
    let wipCount: Int
    let selection: HistorySelection?
    let revealToken: Int
    /// Changes when another worktree's dirty count changes (for its "// WIP" row).
    let worktreeInfoVersion: Int
    /// Shown inside the "// WIP" row, like GitKraken's inline commit summary.
    let draftSummary: String

    func makeCoordinator() -> HistoryTableCoordinator { HistoryTableCoordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = HistoryTableView()
        table.style = .plain
        table.rowHeight = GraphStyle.rowHeight
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing   // the message column fills the rest, see fitMessageColumn

        let header = HistoryHeaderView(frame: NSRect(x: 0, y: 0, width: 600, height: GraphStyle.Header.height))
        table.headerView = header

        let hidden = HistoryColumn.hiddenColumns
        for col in HistoryColumn.allCases {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
            c.headerCell = HistoryHeaderCell(textCell: col.title)
            c.width = col.width
            c.minWidth = col.minWidth
            c.resizingMask = .userResizingMask
            c.isHidden = hidden.contains(col)
            table.addTableColumn(c)
        }

        let coordinator = context.coordinator
        coordinator.table = table
        table.coordinator = coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(HistoryTableCoordinator.doubleClicked)

        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu

        let headerMenu = NSMenu()
        headerMenu.delegate = coordinator.headerMenuDelegate
        header.menu = headerMenu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(coordinator, selector: #selector(HistoryTableCoordinator.fitMessageColumn),
                                               name: NSView.frameDidChangeNotification, object: scroll.contentView)
        sync(context.coordinator)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        sync(context.coordinator)
    }

    private func sync(_ coordinator: HistoryTableCoordinator) {
        coordinator.sync(version: version, filter: filter, wipCount: wipCount, selection: selection,
                         revealToken: revealToken, worktreeInfoVersion: worktreeInfoVersion, draftSummary: draftSummary)
    }
}

enum HistoryColumn: String, CaseIterable {
    case refs, graph, message, author, date, sha

    var title: String {
        switch self {
        case .refs: "Branch / tag"
        case .graph: "Graph"
        case .message: "Commit message"
        case .author: "Author"
        case .date: "Date"
        case .sha: "SHA"
        }
    }

    var width: CGFloat {
        switch self {
        case .refs: 180
        case .graph: 120
        case .message: 300
        case .author: 140
        case .date: 92
        case .sha: 76
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .refs: 60
        case .graph: 40
        case .message: 160
        default: 50
        }
    }

    /// Columns the user can show or hide from the header menu.
    static let optional: [HistoryColumn] = [.author, .date, .sha]

    private static let hiddenKey = "history.hiddenColumns"

    static var hiddenColumns: Set<HistoryColumn> {
        get {
            guard let names = UserDefaults.standard.stringArray(forKey: hiddenKey) else { return [.author, .sha] }
            return Set(names.compactMap(HistoryColumn.init(rawValue:)))
        }
        set { UserDefaults.standard.set(newValue.map(\.rawValue).sorted(), forKey: hiddenKey) }
    }
}

/// Table subclass for Return on the "// WIP" row.
final class HistoryTableView: NSTableView {
    weak var coordinator: HistoryTableCoordinator?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, let coordinator, coordinator.focusSummaryIfWIP(row: selectedRow) { return }
        super.keyDown(with: event)
    }
}

@MainActor
final class HistoryTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let model: RepoModel
    weak var table: NSTableView?
    private(set) var rows: [HistoryRow] = []
    /// Drawing info for WIP rows, by row index.
    private(set) var wipInfo: [Int: HistoryWIPInfo] = [:]
    /// Dashed WIP lines that enter a commit row from a lane of their own, by commit index.
    private(set) var wipJoins: [Int: [HistoryWIPJoin]] = [:]
    private(set) var draftSummary = ""

    // History as of the last rebuildRows. `rows` index into these, so cells and
    // actions always see the same commits the table shows, even in the moment
    // between the model loading new history and the next sync.
    private(set) var commits: [Commit] = []
    private(set) var graph: [GraphRow] = []
    private var ancestry: [Bool] = []
    private var commitIndex: [String: Int] = [:]
    private var refsByCommit: [String: [Ref]] = [:]
    private(set) var headSHA: String?
    /// HEAD is part of the loaded history. When it isn't (an old branch in a
    /// big repo), nothing is dimmed rather than everything.
    private var headLoaded = false
    /// Lanes the widest row needs, including extra WIP lanes.
    private var maxLanes = 1

    private var version = -1
    private var filter = ""
    private var wipCount = -1
    private var worktreeInfoVersion = -1
    private var revealToken = 0
    private var applyingSelection = false
    private var fittingColumns = false
    /// The user dragged the graph column; stop auto-sizing it.
    private var graphUserResized = false
    /// rows.count when "load more" was last requested; asks once per history size.
    private var loadMoreRequestedAt = -1
    private var badgeCache: [Int: [GraphBadge]] = [:]
    private var initialsCache: [String: String] = [:]
    private var authorColorCache: [String: NSColor] = [:]
    private var wipCountsCache: [WIPCount]?
    lazy var headerMenuDelegate = HistoryHeaderMenu(coordinator: self)

    // Cowork: tasks and reviews linked to branches, rebuilt when the store changes.
    private var coworkVersion = -1
    private var tasksByBranch: [String: [CoworkTask]] = [:]
    private var reviewByBranch: [String: ReviewRequest] = [:]
    private var coworkCache: [Int: HistoryCoworkInfo] = [:]

    var isFiltering: Bool { !filter.isEmpty }

    init(model: RepoModel) {
        self.model = model
        super.init()
        observeCowork()
    }

    func sync(version: Int, filter: String, wipCount: Int, selection: HistorySelection?, revealToken: Int,
              worktreeInfoVersion: Int, draftSummary: String) {
        guard let table else { return }
        let summaryChanged = draftSummary != self.draftSummary
        self.draftSummary = draftSummary
        refreshCoworkIfNeeded()
        if version != self.version || filter != self.filter || wipCount != self.wipCount
            || worktreeInfoVersion != self.worktreeInfoVersion {
            let firstLoad = self.version == -1
            self.version = version
            self.filter = filter
            self.wipCount = wipCount
            self.worktreeInfoVersion = worktreeInfoVersion
            wipCountsCache = nil
            rebuildRows()
            table.reloadData()
            sizeGraphColumn()
            if firstLoad {
                applySelection(selection, scroll: true)
                DispatchQueue.main.async { self.fitMessageColumn() }
            }
        } else if summaryChanged {
            // Typing in the commit summary: only the WIP message changes.
            redrawWIPRow(onlyMessage: true)
        } else {
            // Cheap: the WIP row's counts follow the working copy.
            wipCountsCache = nil
            redrawWIPRow(onlyMessage: false)
        }
        let reveal = revealToken != self.revealToken
        self.revealToken = revealToken
        applySelection(selection, scroll: reveal)
    }

    private func redrawWIPRow(onlyMessage: Bool) {
        guard let table, let r = rows.firstIndex(of: .wip) else { return }
        if onlyMessage {
            let c = table.column(withIdentifier: NSUserInterfaceItemIdentifier(HistoryColumn.message.rawValue))
            if c >= 0 { table.view(atColumn: c, row: r, makeIfNecessary: false)?.needsDisplay = true }
            return
        }
        for c in 0..<table.numberOfColumns {
            table.view(atColumn: c, row: r, makeIfNecessary: false)?.needsDisplay = true
        }
    }

    /// Commit shown in a row, or nil for WIP rows and out-of-range rows.
    func commit(atRow row: Int) -> Commit? {
        guard row >= 0, row < rows.count, case .commit(let i) = rows[row], i < commits.count else { return nil }
        return commits[i]
    }

    // MARK: Rows

    private func rebuildRows() {
        badgeCache = [:]
        coworkCache = [:]
        commits = model.commits
        graph = model.graph
        ancestry = model.headAncestry
        commitIndex = model.commitIndex
        refsByCommit = model.refsByCommit
        headSHA = model.headSHA
        headLoaded = headSHA.map { commitIndex[$0] != nil } ?? false
        wipJoins = [:]
        maxLanes = graph.lazy.map(\.laneCount).max() ?? 1

        var r: [HistoryRow] = []
        var info: [Int: HistoryWIPInfo] = [:]
        r.reserveCapacity(commits.count + 1)

        guard filter.isEmpty else {
            let q = filter.lowercased()
            for (i, c) in commits.enumerated() {
                if c.subject.lowercased().contains(q) || c.authorName.lowercased().contains(q)
                    || c.id.hasPrefix(q) || c.bodyPreview.lowercased().contains(q) {
                    r.append(.commit(i))
                }
            }
            rows = r
            wipInfo = [:]
            return
        }

        // WIP rows waiting to be placed above a commit index; nil = top of the list.
        var above: [Int?: [(HistoryRow, HistoryWIPInfo)]] = [:]
        for wt in model.worktrees where wt.path != model.root.path && !wt.isBare {
            guard let changes = model.worktreeInfo[wt.path]?.changes, changes > 0,
                  let head = wt.head, let i = commitIndex[head] else { continue }
            var w = wipRowInfo(target: i)
            w.branch = wt.branch ?? wt.displayName
            w.changes = changes
            above[i, default: []].append((.otherWIP(wt.path), w))
        }
        if wipCount > 0 {
            // Closest to HEAD, below other worktrees sitting on the same commit.
            let target = headSHA.flatMap { commitIndex[$0] }
            above[target, default: []].append((.wip, wipRowInfo(target: target)))
        }

        func place(_ list: [(HistoryRow, HistoryWIPInfo)]?, target: Int?) {
            guard var list else { return }
            // Several WIP rows on one commit: the nearest keeps the commit's lane,
            // the others get free lanes to its right and join the node directly.
            if list.count > 1, let target, target < graph.count {
                let g = graph[target]
                var taken = Set(list[0].1.passThrough.map(\.lane))
                taken.insert(g.lane)
                var lane = g.lane
                var joins: [HistoryWIPJoin] = []
                for k in stride(from: list.count - 2, through: 0, by: -1) {
                    repeat { lane += 1 } while taken.contains(lane)
                    list[k].1.lane = lane
                    joins.append(HistoryWIPJoin(lane: lane, color: list[k].1.color, dimmed: list[k].0 != .wip))
                    maxLanes = max(maxLanes, lane + 1)
                }
                wipJoins[target] = joins
                for k in 1..<list.count {
                    list[k].1.dashedThrough = list[..<k].map { ($0.1.lane, $0.1.color) }
                }
            }
            for (row, w) in list {
                info[r.count] = w
                r.append(row)
            }
        }
        place(above[Int?.none], target: nil)
        for i in commits.indices {
            place(above[i], target: i)
            r.append(.commit(i))
        }
        rows = r
        wipInfo = info
    }

    private func wipRowInfo(target: Int?) -> HistoryWIPInfo {
        guard let target, target < graph.count else {
            return HistoryWIPInfo(target: target, lane: 0, color: 0, passThrough: [])
        }
        let g = graph[target]
        var seen = Set<Int>()
        let through = g.lines.filter { $0.from == .top }.compactMap { line -> (lane: Int, color: Int)? in
            seen.insert(line.fromLane).inserted ? (line.fromLane, line.color) : nil
        }
        return HistoryWIPInfo(target: target, lane: g.lane, color: g.color, passThrough: through)
    }

    func badges(forCommit i: Int) -> [GraphBadge] {
        if let hit = badgeCache[i] { return hit }
        guard i < commits.count else { return [] }
        let refs = refsByCommit[commits[i].id] ?? []
        let b = refs.isEmpty ? [] : GraphBadge.make(refs, remoteNames: model.remotes.map(\.name))
        badgeCache[i] = b
        return b
    }

    func initials(_ name: String) -> String {
        if let hit = initialsCache[name] { return hit }
        let s = name.initials
        initialsCache[name] = s
        return s
    }

    /// Same color as the author's Avatar elsewhere in the app.
    func authorColor(_ email: String) -> NSColor {
        if let hit = authorColorCache[email] { return hit }
        let c = GraphStyle.authorColor(email: email)
        authorColorCache[email] = c
        return c
    }

    func wipCounts() -> [WIPCount] {
        if let hit = wipCountsCache { return hit }
        let c = WIPCount.make(model.status)
        wipCountsCache = c
        return c
    }

    /// Lane and color of the node drawn in a row (lane 0 while filtering).
    func node(forRow row: Int) -> (lane: Int, color: Int)? {
        guard row >= 0, row < rows.count else { return nil }
        switch rows[row] {
        case .wip, .otherWIP:
            guard let w = wipInfo[row] else { return (0, 0) }
            return (w.lane, w.color)
        case .commit(let i):
            guard i < graph.count else { return (0, 0) }
            let g = graph[i]
            return (isFiltering ? 0 : g.lane, g.color)
        }
    }

    func isDimmed(row: Int) -> Bool {
        guard row >= 0, row < rows.count else { return false }
        switch rows[row] {
        case .wip: return false
        case .otherWIP: return true
        case .commit(let i): return headLoaded && i < ancestry.count && !ancestry[i]
        }
    }

    // MARK: Cowork

    /// Re-arms itself after each change, so this costs nothing while idle.
    private func observeCowork() {
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

    private func refreshCoworkIfNeeded() {
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
                    info.tasks.append(.init(id: t.id, title: t.title, statusTitle: t.status.title, color: NSColor(t.status.color)))
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

    // MARK: Columns

    private func column(_ c: HistoryColumn) -> NSTableColumn? {
        table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(c.rawValue))
    }

    /// Fits the graph column to the widest row of the whole loaded history
    /// (re-run after every reload) until the user resizes it by hand.
    /// It never pushes the message column below its minimum (lanes past the
    /// edge are clipped with a fade, and nodes stay pinned inside).
    private func sizeGraphColumn() {
        fitMessageColumn()
    }

    private func autoSizeGraphColumn() {
        guard !graphUserResized, !graph.isEmpty, let table, let col = column(.graph), let message = column(.message),
              let clip = table.enclosingScrollView?.contentView, clip.bounds.width > 0 else { return }
        let lanes = isFiltering ? 1 : maxLanes
        let wanted = CGFloat(lanes) * GraphStyle.laneWidth + GraphStyle.graphInset * 2
        let others = table.tableColumns.filter { $0 !== message && $0 !== col && !$0.isHidden }.reduce(0) { $0 + $1.width }
        let room = clip.bounds.width - others - message.minWidth
        let target = max(GraphStyle.minGraphWidth, min(wanted, GraphStyle.maxGraphWidth, room))
        if abs(col.width - target) > 0.5 { col.width = target }
    }

    /// The message column takes whatever width the other columns leave.
    @objc func fitMessageColumn() {
        guard !fittingColumns, let table, let clip = table.enclosingScrollView?.contentView, let message = column(.message) else { return }
        fittingColumns = true
        defer { fittingColumns = false }
        autoSizeGraphColumn()
        let others = table.tableColumns.filter { $0 !== message && !$0.isHidden }.reduce(0) { $0 + $1.width }
        let width = max(message.minWidth, clip.bounds.width - others)
        if abs(message.width - width) > 0.5 { message.width = width }
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard let table, let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
        // A drag in the header (not our own sizing).
        let byUser = table.headerView?.resizedColumn == table.column(withIdentifier: column.identifier)
            && table.headerView?.resizedColumn != -1
        if !fittingColumns {
            if column.identifier.rawValue == HistoryColumn.graph.rawValue, byUser {
                graphUserResized = true
            }
            if column.identifier.rawValue == HistoryColumn.message.rawValue {
                // Dragging the message divider moves width to/from the next visible
                // column, so nothing ends up past the right edge.
                if byUser, let old = notification.userInfo?["NSOldWidth"] as? CGFloat,
                   let next = table.tableColumns.drop(while: { $0 !== column }).dropFirst().first(where: { !$0.isHidden }) {
                    fittingColumns = true
                    next.width = max(next.minWidth, next.width - (column.width - old))
                    fittingColumns = false
                }
                DispatchQueue.main.async { self.fitMessageColumn() }
            } else {
                fitMessageColumn()
            }
        }
        // Bands start at the node, which moves with the graph column.
        refreshBands()
    }

    func setColumn(_ c: HistoryColumn, visible: Bool) {
        guard let col = column(c) else { return }
        col.isHidden = !visible
        var hidden = HistoryColumn.hiddenColumns
        if visible { hidden.remove(c) } else { hidden.insert(c) }
        HistoryColumn.hiddenColumns = hidden
        fitMessageColumn()
        refreshBands()
    }

    func isColumnVisible(_ c: HistoryColumn) -> Bool { column(c).map { !$0.isHidden } ?? false }

    private func refreshBands() {
        table?.enumerateAvailableRowViews { view, row in
            (view as? HistoryRowView)?.band = self.band(forRow: row)
        }
    }

    // MARK: Selection

    private func row(for selection: HistorySelection?) -> Int? {
        switch selection {
        case .workingCopy: return rows.firstIndex(of: .wip)
        case .commit(let sha):
            guard let i = commitIndex[sha] else { return nil }
            return rows.firstIndex(of: .commit(i))
        case nil: return nil
        }
    }

    private func applySelection(_ selection: HistorySelection?, scroll: Bool) {
        guard let table else { return }
        let target = row(for: selection)
        applyingSelection = true
        if let target {
            if table.selectedRow != target {
                table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            }
            if scroll { table.scrollRowToVisible(target) }
        } else if table.selectedRow != -1 {
            table.deselectAll(nil)
        }
        applyingSelection = false
    }

    /// Other worktrees' WIP rows can't be selected; arrow keys step over them.
    /// Clicking empty space keeps the current selection (the inspector follows the table).
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        if proposed.isEmpty && !applyingSelection { return tableView.selectedRowIndexes }
        guard let r = proposed.first, r < rows.count, case .otherWIP = rows[r] else { return proposed }
        let isKey = NSApp.currentEvent?.type == .keyDown
        guard isKey else { return tableView.selectedRowIndexes }
        let step = r > tableView.selectedRow ? 1 : -1
        var next = r
        while next >= 0, next < rows.count, case .otherWIP = rows[next] { next += step }
        return next >= 0 && next < rows.count ? IndexSet(integer: next) : tableView.selectedRowIndexes
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection, let table else { return }
        let r = table.selectedRow
        guard r >= 0, r < rows.count else { return }
        // Rows map to the commits the table showed when clicked (see `commits`).
        switch rows[r] {
        case .wip: model.selection = .workingCopy
        case .otherWIP: break
        case .commit:
            if let c = commit(atRow: r) { model.selection = .commit(c.id) }
        }
    }

    /// Returns true when the row is the WIP row and focus moved to the summary field.
    func focusSummaryIfWIP(row: Int) -> Bool {
        guard row >= 0, row < rows.count, rows[row] == .wip else { return false }
        model.selection = .workingCopy
        model.focusSummaryToken += 1
        return true
    }

    @objc func doubleClicked() {
        guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
        if focusSummaryIfWIP(row: table.clickedRow) { return }
        guard let commit = commit(atRow: table.clickedRow) else { return }
        // Double-click a branch tip: check out that branch (a remote-only tip
        // gets a tracking branch). Otherwise do nothing.
        let refs = refsByCommit[commit.id] ?? []
        if refs.contains(where: { $0.kind == .localBranch && $0.isHead }) { return }
        if let local = refs.first(where: { $0.kind == .localBranch }) {
            Task { await model.checkout(local) }
        } else if let remote = refs.first(where: { $0.kind == .remoteBranch && !$0.name.hasSuffix("/HEAD") }) {
            Task { await model.checkout(remote) }
        }
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("HistoryRow")
        let view = (tableView.makeView(withIdentifier: id, owner: nil) as? HistoryRowView) ?? {
            let v = HistoryRowView()
            v.identifier = id
            return v
        }()
        view.band = band(forRow: row)
        return view
    }

    func band(forRow row: Int) -> HistoryBand? {
        guard let table, let node = node(forRow: row) else { return nil }
        let graphIndex = table.column(withIdentifier: NSUserInterfaceItemIdentifier(HistoryColumn.graph.rawValue))
        guard graphIndex >= 0 else { return nil }
        let rect = table.rect(ofColumn: graphIndex)
        let x = rect.minX + GraphStyle.nodeX(node.lane, width: rect.width)
        let isCommit: Bool = if case .commit = rows[row] { true } else { false }
        return HistoryBand(color: Theme.lane(node.color), nodeX: x, dimmed: isDimmed(row: row), showsResting: isCommit)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let column = HistoryColumn(rawValue: id.rawValue) else { return nil }
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? HistoryCell) ?? {
            let c = HistoryCell()
            c.identifier = id
            return c
        }()
        cell.configure(coordinator: self, column: column, row: row)

        // Near the end: load more history, once per history size.
        if row >= rows.count - 50, loadMoreRequestedAt != rows.count, model.hasMoreCommits, !isFiltering {
            loadMoreRequestedAt = rows.count
            model.loadMoreCommits()
        }
        return cell
    }

    // MARK: Context menu

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

/// Header menu: toggles the optional columns.
@MainActor
final class HistoryHeaderMenu: NSObject, NSMenuDelegate {
    private unowned let coordinator: HistoryTableCoordinator

    init(coordinator: HistoryTableCoordinator) {
        self.coordinator = coordinator
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "Columns", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        for c in HistoryColumn.optional {
            let visible = coordinator.isColumnVisible(c)
            let item = ActionItem(c.title) { [coordinator] in coordinator.setColumn(c, visible: !visible) }
            item.state = visible ? .on : .off
            menu.addItem(item)
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
