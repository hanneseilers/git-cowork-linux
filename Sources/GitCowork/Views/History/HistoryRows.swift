import AppKit
import GitCoworkCore
import SwiftUI

enum HistoryRow: Equatable {
    case wip                    // this worktree's uncommitted changes
    case otherWIP(String)       // another worktree's uncommitted changes (its path)
    case commit(Int)            // index into model.commits
}

/// Drawing info for a "// WIP" row, worked out when rows are rebuilt.
struct HistoryWIPInfo {
    let target: Int?            // commit index the row sits above (the worktree's HEAD)
    /// Lane of this row's dashed node. The WIP nearest the commit uses the
    /// commit's lane; others on the same commit get a free lane of their own,
    /// so WIP rows never chain into each other.
    var lane: Int
    let color: Int
    /// Lanes (with colors) that enter the target row from the top; drawn straight through.
    let passThrough: [(lane: Int, color: Int)]
    /// Dashed lines of WIP rows higher up that pass this row on their way to the commit.
    var dashedThrough: [(lane: Int, color: Int)] = []
    var branch: String?
    var changes = 0
}

/// A dashed WIP line that enters a commit row from the top in `lane` and
/// bends into the commit's node.
struct HistoryWIPJoin {
    let lane: Int
    let color: Int
    let dimmed: Bool
}

/// Tasks and reviews linked to the branches on one commit.
struct HistoryCoworkInfo {
    struct TaskMark {
        let id: String
        let title: String
        let statusTitle: String
        let color: NSColor
    }
    struct ReviewMark {
        let branch: String
        let symbol: String
        let title: String
        let color: NSColor
    }
    var tasks: [TaskMark] = []
    var review: ReviewMark?
    var isEmpty: Bool { tasks.isEmpty && review == nil }

    /// Tooltip for the message cell.
    var tooltip: String {
        var lines = tasks.map { "\($0.id)  \($0.title) (\($0.statusTitle))" }
        if let review { lines.append("Review of \(review.branch): \(review.title)") }
        return lines.joined(separator: "\n")
    }
}

/// Counts shown in the "// WIP" row; cached by the coordinator.
struct WIPCount {
    let symbol: String
    let color: NSColor
    let count: Int

    static func make(_ st: WorkingStatus) -> [WIPCount] {
        ChangeCounts(st.conflicted + st.staged + st.unstaged + st.untracked).groups.map {
            WIPCount(symbol: $0.status.symbol, color: NSColor($0.status.color), count: $0.count)
        }
    }

    /// Another worktree's WIP row: only its total is known, shown as modified.
    static func modified(_ count: Int) -> WIPCount {
        WIPCount(symbol: FileStatus.modified.symbol, color: modifiedColor, count: count)
    }

    private static let modifiedColor = NSColor(FileStatus.modified.color)
}

/// One badge in the Branch / Tag column. A local branch and its remote
/// counterpart share a badge.
struct GraphBadge {
    enum Kind { case branch, tag }
    let name: String
    let kind: Kind
    var isHead = false
    var isLocal = false
    var isRemote = false
    var refNames: [String]

    static func make(_ refs: [Ref], remoteNames: [String]) -> [GraphBadge] {
        var badges: [GraphBadge] = []
        for ref in refs where ref.kind == .localBranch {
            badges.append(GraphBadge(name: ref.name, kind: .branch, isHead: ref.isHead, isLocal: true, refNames: [ref.name]))
        }
        for ref in refs where ref.kind == .remoteBranch {
            let short = shortRemoteName(ref.name, remoteNames: remoteNames)
            if short == "HEAD" { continue }
            let upstreamOwner = refs.first { $0.kind == .localBranch && $0.upstream == ref.name }?.name
            if let i = badges.firstIndex(where: { $0.kind == .branch && ($0.name == short || $0.name == upstreamOwner) }) {
                badges[i].isRemote = true
                badges[i].refNames.append(ref.name)
            } else {
                badges.append(GraphBadge(name: short, kind: .branch, isRemote: true, refNames: [ref.name]))
            }
        }
        for ref in refs where ref.kind == .tag {
            badges.append(GraphBadge(name: ref.name, kind: .tag, refNames: [ref.name]))
        }
        // Checked-out branch first, then local, remote-only, tags (stable otherwise).
        func rank(_ b: GraphBadge) -> Int { b.isHead ? 0 : b.kind == .tag ? 3 : b.isLocal ? 1 : 2 }
        return badges.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// "origin/feature/x" -> "feature/x" when "origin" is a known remote.
    private static func shortRemoteName(_ name: String, remoteNames: [String]) -> String {
        if let remote = remoteNames.filter({ name.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
            return String(name.dropFirst(remote.count + 1))
        }
        guard let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    /// Trailing icons: checked out, local, remote. Tags get a leading tag icon instead.
    var trailingIcons: [String] {
        guard kind == .branch else { return [] }
        var icons: [String] = []
        if isHead { icons.append("checkmark") }
        if isLocal { icons.append("laptopcomputer") }
        if isRemote { icons.append("cloud.fill") }
        return icons
    }

    var leadingIcon: String? { kind == .tag ? "tag.fill" : nil }
}
