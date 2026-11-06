import AppKit

/// Flat header cell: small uppercase grey title, thin divider on the right.
final class HistoryHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSColor.controlBackgroundColor.setFill()
        cellFrame.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 10, width: 1, height: cellFrame.height - 21).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: GraphStyle.Text.header,
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.4,
        ]
        let title = stringValue.uppercased() as NSString
        let size = title.size(withAttributes: attrs)
        // Titles line up with the cell content below (first column uses the panel inset).
        let inset = cellFrame.minX < 1 ? GraphStyle.Text.leadingPadding : GraphStyle.Text.padding
        let rect = NSRect(x: cellFrame.minX + inset, y: cellFrame.midY - size.height / 2,
                          width: max(0, cellFrame.width - inset - GraphStyle.Text.padding), height: size.height)
        title.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    // Draws the same whether or not the column is "highlighted".
    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        draw(withFrame: cellFrame, in: controlView)
    }
}

/// Header with a gear at the right edge that opens the column menu
/// (same menu as right-clicking the header).
final class HistoryHeaderView: NSTableHeaderView {
    private var gearRect: NSRect {
        let s = GraphStyle.Header.gearSize + 8
        return NSRect(x: bounds.maxX - s - 4, y: (bounds.height - s) / 2, width: s, height: s)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
        let r = gearRect
        // Cover the column title underneath, then the gear.
        NSColor.controlBackgroundColor.setFill()
        r.insetBy(dx: -2, dy: 0).fill()
        GraphSymbols.draw("gearshape", x: r.minX + 4, midY: r.midY, size: GraphStyle.Header.gearSize,
                         color: .secondaryLabelColor, weight: .regular)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if gearRect.contains(p), let menu {
            menu.popUp(positioning: nil, at: NSPoint(x: gearRect.minX, y: gearRect.maxY + 2), in: self)
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(gearRect, cursor: .arrow)
    }
}
