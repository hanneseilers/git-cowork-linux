import AppKit

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

// Column sizing and visibility.
extension HistoryTableCoordinator {

    func column(_ c: HistoryColumn) -> NSTableColumn? {
        table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(c.rawValue))
    }

    /// Fits the graph column to the widest row of the whole loaded history
    /// (re-run after every reload) until the user resizes it by hand.
    /// It never pushes the message column below its minimum (lanes past the
    /// edge are clipped with a fade, and nodes stay pinned inside).
    func sizeGraphColumn() {
        fitMessageColumn()
    }

    func autoSizeGraphColumn() {
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

    func refreshBands() {
        table?.enumerateAvailableRowViews { view, row in
            (view as? HistoryRowView)?.band = self.band(forRow: row)
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
