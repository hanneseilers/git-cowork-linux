import AppKit
import GitCoworkCore

/// One cell of the history table. Draws directly with Core Graphics instead
/// of using subviews, which keeps scrolling cheap. The row band behind it is
/// drawn by HistoryRowView.
final class HistoryCell: NSTableCellView {
    private weak var coordinator: HistoryTableCoordinator?
    private var column: HistoryColumn = .message
    private var row = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true   // graph lanes past the column edge must not paint over the message
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(coordinator: HistoryTableCoordinator, column: HistoryColumn, row: Int) {
        self.coordinator = coordinator
        self.column = column
        self.row = row
        toolTip = nil
        if column == .refs, row < coordinator.rows.count, case .commit(let i) = coordinator.rows[row] {
            let names = coordinator.badges(forCommit: i).flatMap(\.refNames)
            if !names.isEmpty { toolTip = names.joined(separator: "\n") }
        }
        if column == .message, row < coordinator.rows.count, case .commit(let i) = coordinator.rows[row] {
            let info = coordinator.cowork(forCommit: i)
            if !info.isEmpty { toolTip = info.tooltip }
        }
        needsDisplay = true
    }

    private var dimmed = false
    /// Text color on the selected band (columns right of the node), nil otherwise.
    private var onBand: NSColor?
    private var primaryText: NSColor {
        if let onBand { return onBand }
        return dimmed ? NSColor.labelColor.withAlphaComponent(GraphStyle.dimmedAlpha) : .labelColor
    }
    private var secondaryText: NSColor {
        if let onBand { return onBand.withAlphaComponent(0.78) }
        return dimmed ? .tertiaryLabelColor : .secondaryLabelColor
    }
    private var midY: CGFloat { bounds.height / 2 }

    override func draw(_ dirtyRect: NSRect) {
        guard let coordinator, row < coordinator.rows.count else { return }
        let model = coordinator.model
        // The selected row is never dimmed and its text reads on the strong band.
        let rowView = superview as? NSTableRowView
        let selected = rowView?.isSelected ?? false
        dimmed = coordinator.isDimmed(row: row) && !selected
        onBand = nil
        if selected, column != .refs, column != .graph, let band = (rowView as? HistoryRowView)?.band {
            let fill = GraphStyle.selectedBandColor(band.color, emphasized: rowView?.isEmphasized ?? true)
            onBand = GraphStyle.readableText(on: fill)
        }
        switch coordinator.rows[row] {
        case .wip:
            guard let w = coordinator.wipInfo[row] else { return }
            if column == .graph { drawWIPGraph(w) }
            if column == .message { drawWIPMessage(model.status, summary: coordinator.draftSummary) }
        case .otherWIP:
            guard let w = coordinator.wipInfo[row] else { return }
            if column == .graph { drawWIPGraph(w) }
            if column == .message { drawOtherWIPMessage(w) }
        case .commit(let i):
            guard i < coordinator.commits.count else { return }
            drawCommit(i, coordinator: coordinator)
        }
    }

    private func drawCommit(_ i: Int, coordinator: HistoryTableCoordinator) {
        let commit = coordinator.commits[i]
        let g = i < coordinator.graph.count ? coordinator.graph[i] : nil
        let color = Theme.lane(g?.color ?? 0)
        switch column {
        case .refs:
            drawBadges(coordinator.badges(forCommit: i), lane: color)
        case .graph:
            let lane = coordinator.isFiltering ? 0 : g?.lane ?? 0
            let cx = GraphStyle.nodeX(lane, width: bounds.width)
            if !coordinator.badges(forCommit: i).isEmpty {
                drawConnector(from: 0, to: cx - GraphStyle.nodeDiameter / 2, color: color)
            }
            if let g, !coordinator.isFiltering {
                drawLines(g.lines)
                for join in coordinator.wipJoins[i] ?? [] { drawWIPJoin(join, into: cx) }
                drawClipFade(lanes: g.laneCount)
            }
            drawNode(cx: cx, color: color, author: coordinator.authorColor(commit.authorEmail),
                     initials: coordinator.initials(commit.authorName),
                     isHead: commit.id == coordinator.headSHA, isMerge: commit.isMerge)
        case .message:
            drawMessage(commit, cowork: coordinator.cowork(forCommit: i))
        case .author:
            drawText(commit.authorName, font: GraphStyle.Text.small, color: secondaryText)
        case .date:
            drawText(Formatters.relative(commit.date), font: GraphStyle.Text.small, color: secondaryText)
        case .sha:
            drawText(commit.shortID, font: GraphStyle.Text.sha, color: secondaryText)
        }
    }

    // MARK: Graph

    private func y(_ anchor: GraphLine.Anchor) -> CGFloat {
        switch anchor {
        case .top: 0
        case .middle: midY
        case .bottom: bounds.height
        }
    }

    private func drawLines(_ lines: [GraphLine]) {
        let r = GraphStyle.bendRadius
        for line in lines {
            let path = NSBezierPath()
            path.lineWidth = GraphStyle.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let x1 = GraphStyle.x(line.fromLane), y1 = y(line.from)
            let x2 = GraphStyle.x(line.toLane), y2 = y(line.to)
            path.move(to: NSPoint(x: x1, y: y1))
            if x1 == x2 {
                path.line(to: NSPoint(x: x2, y: y2))
            } else if line.from == .middle {
                // Out of a node sideways, then down into the parent's lane.
                let dir: CGFloat = x2 > x1 ? 1 : -1
                path.line(to: NSPoint(x: x2 - dir * r, y: y1))
                path.curve(to: NSPoint(x: x2, y: y1 + r), controlPoint1: NSPoint(x: x2, y: y1), controlPoint2: NSPoint(x: x2, y: y1))
                path.line(to: NSPoint(x: x2, y: y2))
            } else {
                // Down from above, then sideways into the node.
                let dir: CGFloat = x2 > x1 ? 1 : -1
                path.line(to: NSPoint(x: x1, y: y2 - r))
                path.curve(to: NSPoint(x: x1 + dir * r, y: y2), controlPoint1: NSPoint(x: x1, y: y2), controlPoint2: NSPoint(x: x1, y: y2))
                path.line(to: NSPoint(x: x2, y: y2))
            }
            Theme.lane(line.color).setStroke()
            path.stroke()
        }
    }

    /// Dimmed colors are blended toward the background so lines don't show through.
    private func faded(_ color: NSColor) -> NSColor {
        dimmed ? (color.blended(withFraction: 1 - GraphStyle.dimmedAlpha, of: .controlBackgroundColor) ?? color) : color
    }

    /// Commit node: filled with the author's color (same as their avatar
    /// everywhere else) inside a ring of the lane color. Merge dots stay lane-colored.
    private func drawNode(cx: CGFloat, color: NSColor, author: NSColor, initials: String, isHead: Bool, isMerge: Bool) {
        let ringColor = faded(color)
        let fill = isMerge ? ringColor : faded(author)
        let d = isMerge ? GraphStyle.mergeDotDiameter : GraphStyle.nodeDiameter
        let rect = NSRect(x: cx - d / 2, y: midY - d / 2, width: d, height: d)

        if isHead {
            let gap = GraphStyle.headRingGap + GraphStyle.headRingWidth / 2
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -gap, dy: -gap))
            ring.lineWidth = GraphStyle.headRingWidth
            ringColor.setStroke()
            ring.stroke()
        }
        fill.setFill()
        NSBezierPath(ovalIn: rect).fill()
        guard !isMerge else { return }
        let w = GraphStyle.nodeRingWidth
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: w / 2, dy: w / 2))
        ring.lineWidth = w
        ringColor.setStroke()
        ring.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: GraphStyle.Text.initials,
            .foregroundColor: GraphStyle.readableText(on: fill).withAlphaComponent(dimmed ? 0.8 : 1),
        ]
        let s = initials as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: cx - size.width / 2, y: midY - size.height / 2), withAttributes: attrs)
    }

    /// Dashed line of another worktree's WIP: down its own lane from the top,
    /// then sideways into the commit node.
    private func drawWIPJoin(_ join: HistoryWIPJoin, into cx: CGFloat) {
        let x = GraphStyle.x(join.lane)
        let r = GraphStyle.bendRadius
        let dir: CGFloat = cx > x ? 1 : -1
        let path = NSBezierPath()
        path.lineWidth = 2
        path.setLineDash(GraphStyle.wipDash, count: GraphStyle.wipDash.count, phase: 0)
        path.move(to: NSPoint(x: x, y: 0))
        path.line(to: NSPoint(x: x, y: midY - r))
        path.curve(to: NSPoint(x: x + dir * r, y: midY), controlPoint1: NSPoint(x: x, y: midY), controlPoint2: NSPoint(x: x, y: midY))
        path.line(to: NSPoint(x: cx, y: midY))
        let color = Theme.lane(join.color)
        (join.dimmed ? color.withAlphaComponent(0.6) : color).setStroke()
        path.stroke()
    }

    /// Lanes past the column edge are cut off; fade them out instead of a hard edge.
    private func drawClipFade(lanes: Int) {
        guard GraphStyle.x(lanes - 1) + GraphStyle.laneWidth / 2 > bounds.width else { return }
        let w = GraphStyle.clipFadeWidth
        let bg = NSColor.controlBackgroundColor
        NSGradient(starting: bg.withAlphaComponent(0), ending: bg)?
            .draw(in: NSRect(x: bounds.width - w, y: 0, width: w, height: bounds.height), angle: 0)
    }

    /// Thin line tying a branch badge to its node.
    private func drawConnector(from x1: CGFloat, to x2: CGFloat, color: NSColor) {
        guard x2 > x1 else { return }
        color.withAlphaComponent(dimmed ? 0.5 : 0.9).setFill()
        let h = GraphStyle.Badge.connectorWidth
        NSRect(x: x1, y: midY - h / 2, width: x2 - x1, height: h).fill()
    }

    // MARK: Working copy rows

    private func drawWIPGraph(_ w: HistoryWIPInfo) {
        let cx = GraphStyle.nodeX(w.lane, width: bounds.width)
        let r = GraphStyle.nodeDiameter / 2 - 1
        let color = Theme.lane(w.color)
        let width = GraphStyle.lineWidth

        // Keep the graph continuous: lanes entering the commit below pass straight through.
        for lane in w.passThrough {
            let path = NSBezierPath()
            path.lineWidth = width
            let x = GraphStyle.x(lane.lane)
            if lane.lane == w.lane {
                path.move(to: NSPoint(x: x, y: 0))
                path.line(to: NSPoint(x: x, y: midY - r))
            } else {
                path.move(to: NSPoint(x: x, y: 0))
                path.line(to: NSPoint(x: x, y: bounds.height))
            }
            Theme.lane(lane.color).setStroke()
            path.stroke()
        }

        let stroke = dimmed ? color.withAlphaComponent(0.6) : color
        stroke.setStroke()
        // WIP rows higher up on the same commit pass by in their own lanes.
        for other in w.dashedThrough {
            let path = NSBezierPath()
            path.lineWidth = 2
            path.setLineDash(GraphStyle.wipDash, count: GraphStyle.wipDash.count, phase: 0)
            let x = GraphStyle.x(other.lane)
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: bounds.height))
            Theme.lane(other.color).withAlphaComponent(0.6).setStroke()
            path.stroke()
        }

        stroke.setStroke()
        let dashed = NSBezierPath()
        dashed.lineWidth = 2
        dashed.setLineDash(GraphStyle.wipDash, count: GraphStyle.wipDash.count, phase: 0)
        if w.target != nil {
            dashed.move(to: NSPoint(x: cx, y: midY + r))
            dashed.line(to: NSPoint(x: cx, y: bounds.height))
        }
        dashed.stroke()

        let ring = NSBezierPath(ovalIn: NSRect(x: cx - r, y: midY - r, width: r * 2, height: r * 2))
        ring.lineWidth = 2
        ring.setLineDash(GraphStyle.wipDash, count: GraphStyle.wipDash.count, phase: 0)
        ring.stroke()
    }

    private func drawWIPMessage(_ st: WorkingStatus, summary: String) {
        let pad = GraphStyle.Text.padding
        let isEmpty = summary.isEmpty
        let attrs: [NSAttributedString.Key: Any] = [
            .font: GraphStyle.Text.body,
            .foregroundColor: isEmpty ? NSColor.placeholderTextColor : NSColor.labelColor,
            .paragraphStyle: Self.truncating,
        ]
        let text = (isEmpty ? "// WIP" : summary) as NSString
        let textSize = text.size(withAttributes: attrs)

        let counts = coordinator?.wipCounts() ?? []
        let countsWidth = counts.reduce(0) { $0 + countWidth($1) }
        let maxBox = max(60, min(bounds.width * GraphStyle.WIP.boxMaxFraction, bounds.width - pad * 2 - countsWidth))
        let boxWidth = min(max(textSize.width + pad * 2, GraphStyle.WIP.boxMinWidth), maxBox)
        let h = GraphStyle.WIP.boxHeight
        let box = NSRect(x: pad, y: midY - h / 2, width: boxWidth, height: h)

        let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.Radius.control, yRadius: Theme.Radius.control)
        NSColor.textBackgroundColor.withAlphaComponent(0.7).setFill()
        path.fill()
        NSColor.tertiaryLabelColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        text.draw(with: NSRect(x: box.minX + pad, y: midY - textSize.height / 2, width: box.width - pad * 2, height: textSize.height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)

        var x = box.maxX + GraphStyle.WIP.countSpacing
        for c in counts { x = drawCount(c, x: x) + GraphStyle.WIP.countSpacing }
    }

    private func drawOtherWIPMessage(_ w: HistoryWIPInfo) {
        let pad = GraphStyle.Text.padding
        var x = pad
        x = drawInline("// WIP", font: GraphStyle.Text.wip, color: primaryText, x: x) + GraphStyle.WIP.countSpacing
        x = drawCount(WIPCount.modified(w.changes), x: x) + GraphStyle.WIP.countSpacing
        if let branch = w.branch {
            let s = NSMutableAttributedString(string: "on ", attributes: [.font: GraphStyle.Text.small, .foregroundColor: secondaryText])
            s.append(NSAttributedString(string: branch, attributes: [.font: GraphStyle.Text.small, .foregroundColor: primaryText]))
            drawAttributed(s, inset: x)
        }
    }

    private static let countFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let countIconSize: CGFloat = 11

    private func countWidth(_ c: WIPCount) -> CGFloat {
        let text = ("\(c.count)" as NSString).size(withAttributes: [.font: Self.countFont]).width
        return GraphSymbols.width(c.symbol, size: Self.countIconSize, weight: .semibold) + 3 + text + GraphStyle.WIP.countSpacing
    }

    /// Icon + number in the icon's color. Returns the x after it.
    private func drawCount(_ c: WIPCount, x: CGFloat) -> CGFloat {
        let alpha: CGFloat = dimmed ? GraphStyle.dimmedAlpha + 0.2 : 1
        let w = GraphSymbols.draw(c.symbol, x: x, midY: midY, size: Self.countIconSize, color: c.color, weight: .semibold, alpha: alpha)
        return drawInline("\(c.count)", font: Self.countFont, color: c.color.withAlphaComponent(alpha), x: x + w + 3)
    }

    @discardableResult
    private func drawInline(_ text: String, font: NSFont, color: NSColor, x: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: x, y: midY - size.height / 2), withAttributes: attrs)
        return x + size.width
    }

    // MARK: Branch / Tag column

    private func drawBadges(_ badges: [GraphBadge], lane: NSColor) {
        guard let badge = badges.first else { return }
        let style = GraphStyle.Badge.self
        let pad = style.hPadding
        let lead = GraphStyle.Text.leadingPadding   // same inset as the column title
        let maxX = bounds.width - pad
        let h = style.height
        let top = midY - h / 2

        let remaining = badges.count - 1
        let more = remaining > 0 ? "+\(remaining)" : nil
        let moreAttrs: [NSAttributedString.Key: Any] = [.font: style.moreFont, .foregroundColor: NSColor.secondaryLabelColor]
        let moreWidth = more.map { ($0 as NSString).size(withAttributes: moreAttrs).width + 10 + style.gap } ?? 0

        let isStrong = badge.isLocal
        let fill: NSColor = isStrong ? GraphStyle.badgeFill(lane) : lane.withAlphaComponent(style.remoteOnlyAlpha)
        let fg: NSColor = isStrong ? GraphStyle.readableText(on: fill) : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [.font: style.font, .foregroundColor: fg, .paragraphStyle: Self.truncating]

        let leading = badge.leadingIcon
        let trailing = badge.trailingIcons
        let leadingWidth = leading.map { GraphSymbols.width($0, size: style.iconSize) + style.iconSpacing } ?? 0
        let trailingWidth = trailing.reduce(0) { $0 + style.iconSpacing + GraphSymbols.width($1, size: style.iconSize) }
        let nameWidth = (badge.name as NSString).size(withAttributes: attrs).width
        let available = maxX - lead - moreWidth - leadingWidth - trailingWidth - pad * 2
        let textWidth = min(nameWidth, max(available, 0))

        var x = lead
        let fits = textWidth >= 20
        if fits {
            let rect = NSRect(x: x, y: top, width: pad * 2 + leadingWidth + textWidth + trailingWidth, height: h)
            let path = NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.badge, yRadius: Theme.Radius.badge)
            fill.setFill()
            path.fill()
            if !isStrong {
                lane.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            var cx = rect.minX + pad
            if let leading {
                cx += GraphSymbols.draw(leading, x: cx, midY: midY, size: style.iconSize, color: fg) + style.iconSpacing
            }
            let th = (badge.name as NSString).size(withAttributes: attrs).height
            (badge.name as NSString).draw(with: NSRect(x: cx, y: midY - th / 2, width: textWidth, height: th),
                                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            cx += textWidth
            for icon in trailing {
                cx += style.iconSpacing
                cx += GraphSymbols.draw(icon, x: cx, midY: midY, size: style.iconSize, color: fg.withAlphaComponent(0.9))
            }
            x = rect.maxX + style.gap
        }
        // Too narrow for the first badge: everything goes into the counter.
        let counter = fits ? more : "+\(badges.count)"
        if let more = counter {
            let s = more as NSString
            let size = s.size(withAttributes: moreAttrs)
            let rect = NSRect(x: x, y: top + 2, width: size.width + 10, height: h - 4)
            let path = NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.badge, yRadius: Theme.Radius.badge)
            lane.withAlphaComponent(0.22).setFill()
            path.fill()
            s.draw(at: NSPoint(x: rect.midX - size.width / 2, y: midY - size.height / 2), withAttributes: moreAttrs)
            x = rect.maxX
        }
        drawConnector(from: x, to: bounds.width, color: lane)
    }

    // MARK: Text columns

    private static let truncating: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()

    private func drawMessage(_ commit: Commit, cowork: HistoryCoworkInfo) {
        var inset = GraphStyle.Text.padding
        if !cowork.isEmpty { inset = drawCoworkMarks(cowork, x: inset) + GraphStyle.Cowork.gap }
        let s = NSMutableAttributedString(string: commit.subject, attributes: [
            .font: GraphStyle.Text.subject,
            .foregroundColor: primaryText,
        ])
        if !commit.bodyPreview.isEmpty {
            s.append(NSAttributedString(string: GraphStyle.Text.bodySeparator + commit.bodyPreview, attributes: [
                .font: GraphStyle.Text.body,
                .foregroundColor: secondaryText,
            ]))
        }
        drawAttributed(s, inset: inset)
    }

    /// Review verdict icon and task-id chips for branches on this commit.
    /// Returns the x after them.
    private func drawCoworkMarks(_ info: HistoryCoworkInfo, x start: CGFloat) -> CGFloat {
        let style = GraphStyle.Cowork.self
        let alpha: CGFloat = dimmed ? GraphStyle.dimmedAlpha + 0.2 : 1
        var x = start
        if let review = info.review {
            // Keeps its verdict color on the selected band too; the color is the message.
            x += GraphSymbols.draw(review.symbol, x: x, midY: midY, size: style.iconSize, color: review.color,
                                   weight: .semibold, alpha: alpha, hierarchical: true)
            x += style.gap - 2
        }
        for (n, task) in info.tasks.prefix(2).enumerated() {
            if n > 0 { x += 4 }
            let fg = (onBand ?? task.color).withAlphaComponent(alpha)
            let attrs: [NSAttributedString.Key: Any] = [.font: style.chipFont, .foregroundColor: fg]
            let s = task.id as NSString
            let size = s.size(withAttributes: attrs)
            let rect = NSRect(x: x, y: midY - style.chipHeight / 2, width: size.width + style.chipPadding * 2, height: style.chipHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.badge, yRadius: Theme.Radius.badge)
            (onBand ?? task.color).withAlphaComponent(style.chipFillAlpha * alpha).setFill()
            path.fill()
            s.draw(at: NSPoint(x: rect.minX + style.chipPadding, y: midY - size.height / 2), withAttributes: attrs)
            x = rect.maxX
        }
        return x
    }

    private func drawText(_ text: String, font: NSFont, color: NSColor) {
        drawAttributed(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]), inset: GraphStyle.Text.padding)
    }

    private func drawAttributed(_ s: NSAttributedString, inset: CGFloat) {
        let m = NSMutableAttributedString(attributedString: s)
        m.addAttribute(.paragraphStyle, value: Self.truncating, range: NSRange(location: 0, length: m.length))
        let height = m.size().height
        let rect = NSRect(x: inset, y: midY - height / 2, width: max(0, bounds.width - inset - 4), height: height)
        m.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
