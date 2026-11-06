import AppKit

/// What the row view needs to paint behind a history row.
struct HistoryBand {
    let color: NSColor
    let nodeX: CGFloat        // in table coordinates
    let dimmed: Bool
    let showsResting: Bool    // false for WIP rows: band only when selected or hovered
}

/// Row background: a lane-colored band from the commit's node to the right
/// edge, stronger when selected (instead of the system blue), plus a hover wash.
final class HistoryRowView: NSTableRowView {
    var band: HistoryBand? { didSet { needsDisplay = true } }
    private var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?

    // Cells draw differently on the selected band (full contrast, not dimmed),
    // so redraw them whenever selection or focus changes, whatever caused it.
    override var isSelected: Bool {
        didSet { if isSelected != oldValue { redrawCells() } }
    }
    override var isEmphasized: Bool {
        didSet { if isEmphasized != oldValue && isSelected { redrawCells() } }
    }

    func redrawCells() {
        for v in subviews { v.needsDisplay = true }
    }

    // Cells keep normal text colors on the colored selection band.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        // Rows get reused while scrolling; re-check where the mouse is.
        if let window {
            hovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func drawBackground(in dirtyRect: NSRect) {
        if hovered && !isSelected {
            NSColor.labelColor.withAlphaComponent(GraphStyle.Band.hoverAlpha).setFill()
            bounds.fill()
        }
        guard let band, !isSelected else { return }
        var alpha = band.showsResting ? GraphStyle.Band.alpha : 0
        if hovered && !band.showsResting { alpha = GraphStyle.Band.alpha }
        if band.dimmed { alpha *= GraphStyle.Band.dimFactor }
        guard alpha > 0 else { return }
        fillBand(band, alpha: alpha)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard let band else {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).setFill()
            bounds.fill()
            return
        }
        let strength: CGFloat = isEmphasized ? 1 : GraphStyle.Band.unemphasizedFactor
        band.color.withAlphaComponent(GraphStyle.Band.selectedWashAlpha * strength).setFill()
        NSRect(x: 0, y: 0, width: band.nodeX, height: bounds.height).fill()
        // Not dimmed when selected: the selected row is always shown at full strength.
        fillBand(band, alpha: GraphStyle.Band.selectedAlpha * strength)
    }

    /// Capsule-ended band that starts around the node and runs to the right edge.
    private func fillBand(_ band: HistoryBand, alpha: CGFloat) {
        let inset = GraphStyle.Band.verticalInset
        let h = bounds.height - inset * 2
        let rect = NSRect(x: band.nodeX - h / 2, y: inset, width: bounds.maxX - band.nodeX + h / 2, height: h)
        let path = NSBezierPath()
        let r = h / 2
        path.move(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX + r, y: rect.minY))
        path.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.midY), radius: r, startAngle: 270, endAngle: 90, clockwise: true)
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.close()
        band.color.withAlphaComponent(alpha).setFill()
        path.fill()
    }
}
