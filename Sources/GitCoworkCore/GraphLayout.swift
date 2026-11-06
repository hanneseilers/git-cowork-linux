import Foundation

/// One line segment in a row of the commit graph.
/// Vertical positions: `top` (row's top edge), `middle` (the commit dot), `bottom`.
public struct GraphLine: Hashable, Sendable {
    public enum Anchor: UInt8, Sendable { case top, middle, bottom }
    public let fromLane: Int
    public let from: Anchor
    public let toLane: Int
    public let to: Anchor
    public let color: Int
}

public struct GraphRow: Hashable, Sendable {
    public let lane: Int        // column of the commit dot
    public let color: Int       // color index of the commit's lane
    public let lines: [GraphLine]
    public let laneCount: Int   // columns needed to draw this row
}

/// Assigns each commit a lane (column) and works out the lines to draw.
///
/// Input must be in an order where children come before parents
/// (`git log --date-order` or `--topo-order`). Each lane remembers which commit
/// it is waiting for; when that commit shows up, the lane ends at its dot.
/// Lanes never move sideways, so a line is always either straight down or a
/// single bend from a commit to its parent's lane.
public enum GraphLayout {
    public static func layout(_ commits: [Commit]) -> [GraphRow] {
        var lanes: [String?] = []     // sha each lane is waiting for
        var laneColors: [Int] = []
        var nextColor = 0
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)

        func freeLane() -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil)
            laneColors.append(0)
            return lanes.count - 1
        }

        for commit in commits {
            var lines: [GraphLine] = []
            let widthBefore = lanes.count

            // Which lane does this commit sit in?
            var lane: Int
            let isTip: Bool
            if let i = lanes.firstIndex(where: { $0 == commit.id }) {
                lane = i
                isTip = false
            } else {
                lane = freeLane()
                lanes[lane] = commit.id
                laneColors[lane] = nextColor
                nextColor += 1
                isTip = true
            }
            let color = laneColors[lane]

            // Lines coming in from the row above.
            for (j, waiting) in lanes.enumerated() {
                guard let waiting else { continue }
                if waiting == commit.id {
                    if j == lane && isTip { continue }
                    lines.append(GraphLine(fromLane: j, from: .top, toLane: lane, to: .middle, color: laneColors[j]))
                } else {
                    lines.append(GraphLine(fromLane: j, from: .top, toLane: j, to: .bottom, color: laneColors[j]))
                }
            }

            // Other lanes that were also waiting for this commit end here.
            for j in lanes.indices where j != lane && lanes[j] == commit.id {
                lanes[j] = nil
            }

            // Lines going out to the parents.
            if let first = commit.parents.first {
                lanes[lane] = first
                lines.append(GraphLine(fromLane: lane, from: .middle, toLane: lane, to: .bottom, color: color))
                for parent in commit.parents.dropFirst() {
                    let target: Int
                    if let k = lanes.firstIndex(where: { $0 == parent }) {
                        target = k
                    } else {
                        target = freeLane()
                        lanes[target] = parent
                        laneColors[target] = nextColor
                        nextColor += 1
                    }
                    lines.append(GraphLine(fromLane: lane, from: .middle, toLane: target, to: .bottom, color: laneColors[target]))
                }
            } else {
                lanes[lane] = nil
            }

            let widthAfter = lanes.count
            while let last = lanes.last, last == nil {
                lanes.removeLast()
                laneColors.removeLast()
            }

            rows.append(GraphRow(lane: lane, color: color, lines: lines,
                                 laneCount: max(widthBefore, widthAfter, lane + 1)))
        }
        return rows
    }
}
