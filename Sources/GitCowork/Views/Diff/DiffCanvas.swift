import AppKit

enum HunkAction: Hashable {
    case stage, unstage, discard

    /// Same tints as the Stage / Unstage / Discard buttons in the changes panel.
    var tint: NSColor {
        switch self {
        case .stage: .systemGreen
        case .unstage, .discard: .systemRed
        }
    }

    var title: String {
        switch self {
        case .stage: "Stage Hunk"
        case .unstage: "Unstage Hunk"
        case .discard: "Discard Hunk"
        }
    }
}

/// Draws a diff directly: one row per line, only the visible rows are drawn,
/// so 20k-line diffs scroll fast. Hunk rows carry custom-drawn buttons.
/// Rows are selected with click / shift-click / drag and copied with ⌘C.
/// Gutters stay put while the code scrolls sideways.
final class DiffCanvas: NSView, NSMenuItemValidation {
    var onHunkAction: ((HunkAction, Int) -> Void)?

    private enum Side { case left, right }
    private struct ButtonHit: Equatable {
        let row: Int
        let action: HunkAction
    }

    private var doc = DiffDocument()
    private var version = -1
    private var documentID = ""
    private var mode: DiffMode = .hunk
    private var actions: [HunkAction] = []
    private var actionsEnabled = true

    /// Top of each row plus the end of the last one.
    private var rowTops: [CGFloat] = [0]
    private var hOffset: CGFloat = 0
    private var selection: ClosedRange<Int>?
    private var anchor: Int?
    private var selectionSide: Side = .right
    private var hover: ButtonHit?
    private var pressed: ButtonHit?

    private var textCache: [Int: NSAttributedString] = [:]
    private var changeCache: [Int: (CGFloat, CGFloat)] = [:]
    private var buttonTitles: [HunkAction: NSAttributedString] = [:]

    private let charWidth = ("0" as NSString).size(withAttributes: [.font: DiffStyle.font]).width
    private let gutterCharWidth = ("0" as NSString).size(withAttributes: [.font: DiffStyle.gutterFont]).width
    private let textHeight = ceil(DiffStyle.font.ascender - DiffStyle.font.descender)
    private let gutterTextHeight = ceil(DiffStyle.gutterFont.ascender - DiffStyle.gutterFont.descender)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Content

    func update(document: DiffDocument, version: Int, documentID: String, mode: DiffMode,
                actions: [HunkAction], actionsEnabled: Bool) {
        let newFile = documentID != self.documentID
        let newContent = version != self.version || newFile
        let newMode = mode != self.mode
        guard newContent || newMode || actions != self.actions || actionsEnabled != self.actionsEnabled else { return }

        if newContent {
            doc = document
            self.version = version
            self.documentID = documentID
            textCache.removeAll()
            changeCache.removeAll()
        }
        if newContent || newMode {
            selection = nil
            anchor = nil
            hover = nil
        }
        self.mode = mode
        self.actions = actions
        self.actionsEnabled = actionsEnabled
        if newContent || newMode { computeRows() }
        if newFile {
            hOffset = 0
            scroll(.zero)
        }
        clampHOffset()
        needsDisplay = true
    }

    private var rowCount: Int { mode == .hunk ? doc.lines.count : doc.splitRows.count }

    private func computeRows() {
        var tops = [CGFloat]()
        tops.reserveCapacity(rowCount + 1)
        var y: CGFloat = 0
        for r in 0..<rowCount {
            tops.append(y)
            y += hunkIndex(row: r) != nil ? DiffStyle.hunkHeight : DiffStyle.lineHeight
        }
        tops.append(y)
        rowTops = tops
        fitToClipView()
    }

    private func fitToClipView() {
        guard let clip = superview else { return }
        let height = (rowTops.last ?? 0) + DiffStyle.lineHeight * 2
        let size = NSSize(width: clip.bounds.width, height: max(height, clip.bounds.height))
        if frame.size != size { setFrameSize(size) }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self)
        guard let clip = superview else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized),
                                               name: NSView.frameDidChangeNotification, object: clip)
        fitToClipView()
    }

    @objc private func clipResized() {
        fitToClipView()
        clampHOffset()
    }

    /// Hunk index when row `r` is a hunk header row.
    private func hunkIndex(row r: Int) -> Int? {
        switch mode {
        case .hunk:
            let line = doc.lines[r]
            return line.kind == .hunk ? line.hunk : nil
        case .split:
            let row = doc.splitRows[r]
            guard row.kind == .hunk, let l = row.left else { return nil }
            return doc.lines[l].hunk
        }
    }

    /// Hunk that row `r` belongs to (header or body).
    private func owningHunk(row r: Int) -> Int? {
        let index: Int? = switch mode {
        case .hunk: r
        case .split: doc.splitRows[r].left ?? doc.splitRows[r].right
        }
        guard let index, doc.lines[index].hunk >= 0 else { return nil }
        return doc.lines[index].hunk
    }

    private func row(atY y: CGFloat, clamped: Bool) -> Int? {
        let count = rowCount
        guard count > 0 else { return nil }
        if y < 0 { return clamped ? 0 : nil }
        if y >= rowTops[count] { return clamped ? count - 1 : nil }
        var lo = 0, hi = count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if rowTops[mid] <= y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func rowRect(_ r: Int) -> NSRect {
        NSRect(x: 0, y: rowTops[r], width: bounds.width, height: rowTops[r + 1] - rowTops[r])
    }

    // MARK: Geometry

    private var numberWidth: CGFloat {
        CGFloat(max(3, String(doc.maxLineNumber).count)) * gutterCharWidth + DiffStyle.numberPadding * 2
    }

    private var splitMid: CGFloat { floor(bounds.width / 2) }

    /// Width available to code text (after the sign) in the current mode.
    private var codeWidth: CGFloat {
        switch mode {
        case .hunk: bounds.width - numberWidth * 2 - DiffStyle.signWidth
        case .split: splitMid - numberWidth - DiffStyle.signWidth
        }
    }

    private var maxHOffset: CGFloat {
        let text = CGFloat(min(doc.maxColumns, DiffStyle.maxDrawnColumns)) * charWidth + DiffStyle.textInset * 2
        return max(0, ceil(text - codeWidth))
    }

    private func clampHOffset() {
        hOffset = min(max(0, hOffset), maxHOffset)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let first = row(atY: dirtyRect.minY, clamped: true) else { return }
        var r = first
        while r < rowCount, rowTops[r] < dirtyRect.maxY {
            switch mode {
            case .hunk: drawUnifiedRow(r)
            case .split: drawSplitRow(r)
            }
            r += 1
        }
    }

    private func drawUnifiedRow(_ r: Int) {
        let rect = rowRect(r)
        let line = doc.lines[r]
        let gutter = numberWidth * 2
        switch line.kind {
        case .hunk:
            drawHunkBar(row: r, header: line.text, in: rect)
        case .meta:
            DiffStyle.gutterBackground.setFill()
            NSRect(x: 0, y: rect.minY, width: gutter, height: rect.height).fill()
            drawSeparator(x: gutter, in: rect)
            if isSelected(r, side: .right) { fillSelection(rect) }
            drawMeta(r, x: gutter + DiffStyle.signWidth, in: rect)
        case .added, .removed, .context:
            let numbers = [
                (line.old, NSRect(x: 0, y: rect.minY, width: numberWidth, height: rect.height)),
                (line.new, NSRect(x: numberWidth, y: rect.minY, width: numberWidth, height: rect.height)),
            ]
            drawCell(line: r, numbers: numbers,
                     gutter: NSRect(x: 0, y: rect.minY, width: gutter, height: rect.height),
                     code: NSRect(x: gutter, y: rect.minY, width: rect.width - gutter, height: rect.height),
                     selected: isSelected(r, side: .right))
        }
    }

    private func drawSplitRow(_ r: Int) {
        let rect = rowRect(r)
        let row = doc.splitRows[r]
        switch row.kind {
        case .hunk:
            drawHunkBar(row: r, header: row.left.map { doc.lines[$0].text } ?? "", in: rect)
        case .meta:
            if isSelected(r, side: selectionSide) { fillSelection(rect) }
            if let l = row.left { drawMeta(l, x: DiffStyle.hunkInset, in: rect) }
        case .note:
            // "No newline at end of file" under the side it belongs to.
            let mid = splitMid
            let n = numberWidth
            for (side, index, x0, width) in [(Side.left, row.left, CGFloat(0), mid), (Side.right, row.right, mid, rect.width - mid)] {
                let gutter = NSRect(x: x0, y: rect.minY, width: n, height: rect.height)
                let code = NSRect(x: x0 + n, y: rect.minY, width: width - n, height: rect.height)
                if let index {
                    DiffStyle.gutterBackground.setFill()
                    gutter.fill()
                    drawSeparator(x: gutter.maxX, in: gutter)
                    if isSelected(r, side: side) { fillSelection(gutter.union(code)) }
                    NSGraphicsContext.saveGraphicsState()
                    code.clip()
                    drawMeta(index, x: code.minX + DiffStyle.signWidth, in: rect)
                    NSGraphicsContext.restoreGraphicsState()
                } else {
                    DiffStyle.emptySide.setFill()
                    gutter.union(code).fill()
                    drawSeparator(x: gutter.maxX, in: gutter)
                }
            }
            DiffStyle.separator.setFill()
            NSRect(x: mid - 0.5, y: rect.minY, width: 1, height: rect.height).fill()
        case .code:
            let mid = splitMid
            let n = numberWidth
            for (side, index, x0, width) in [(Side.left, row.left, CGFloat(0), mid), (Side.right, row.right, mid, rect.width - mid)] {
                let number = index.map { side == .left ? doc.lines[$0].old : doc.lines[$0].new } ?? nil
                drawCell(line: index,
                         numbers: [(number, NSRect(x: x0, y: rect.minY, width: n, height: rect.height))],
                         gutter: NSRect(x: x0, y: rect.minY, width: n, height: rect.height),
                         code: NSRect(x: x0 + n, y: rect.minY, width: width - n, height: rect.height),
                         selected: isSelected(r, side: side))
            }
            DiffStyle.separator.setFill()
            NSRect(x: mid - 0.5, y: rect.minY, width: 1, height: rect.height).fill()
        }
    }

    /// One side of a code row: gutter with numbers, sign, text and change highlight.
    /// A nil line is the padding opposite a one-sided change.
    private func drawCell(line index: Int?, numbers: [(Int?, NSRect)], gutter: NSRect, code: NSRect, selected: Bool) {
        guard let index else {
            DiffStyle.emptySide.setFill()
            gutter.union(code).fill()
            drawSeparator(x: gutter.maxX, in: gutter)
            return
        }
        let line = doc.lines[index]
        let (background, gutterTint, highlight): (NSColor?, NSColor, NSColor?) = switch line.kind {
        case .added: (DiffStyle.addedBackground, DiffStyle.addedGutter, DiffStyle.addedHighlight)
        case .removed: (DiffStyle.removedBackground, DiffStyle.removedGutter, DiffStyle.removedHighlight)
        default: (nil, DiffStyle.gutterBackground, nil)
        }
        if let background {
            background.setFill()
            code.fill()
        }
        gutterTint.setFill()
        gutter.fill()
        drawSeparator(x: gutter.maxX, in: gutter)
        if selected { fillSelection(gutter.union(code)) }

        for (number, rect) in numbers {
            guard let number else { continue }
            let s = NSAttributedString(string: String(number), attributes: gutterAttributes)
            let w = s.size().width
            s.draw(at: NSPoint(x: rect.maxX - DiffStyle.numberPadding - w,
                               y: rect.minY + (rect.height - gutterTextHeight) / 2))
        }

        if line.kind == .added || line.kind == .removed {
            let sign = NSAttributedString(string: line.kind == .added ? "+" : "−", attributes: [
                .font: DiffStyle.font,
                .foregroundColor: line.kind == .added ? DiffStyle.addedSign : DiffStyle.removedSign,
            ])
            sign.draw(at: NSPoint(x: code.minX + (DiffStyle.signWidth - charWidth) / 2,
                                  y: code.minY + (code.height - textHeight) / 2))
        }

        let textArea = NSRect(x: code.minX + DiffStyle.signWidth, y: code.minY,
                              width: max(0, code.width - DiffStyle.signWidth), height: code.height)
        let textX = textArea.minX + DiffStyle.textInset - hOffset
        NSGraphicsContext.saveGraphicsState()
        textArea.clip()
        if let highlight, !selected, let (x0, x1) = changeOffsets(index), x1 > x0 {
            highlight.setFill()
            NSBezierPath(roundedRect: NSRect(x: textX + x0, y: code.minY + 1, width: x1 - x0, height: code.height - 2),
                         xRadius: 2, yRadius: 2).fill()
        }
        attributed(index).draw(at: NSPoint(x: textX, y: code.minY + (code.height - textHeight) / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawMeta(_ index: Int, x: CGFloat, in rect: NSRect) {
        let s = attributed(index)
        s.draw(at: NSPoint(x: x + DiffStyle.textInset, y: rect.minY + (rect.height - s.size().height) / 2))
    }

    private func drawSeparator(x: CGFloat, in rect: NSRect) {
        DiffStyle.separator.setFill()
        NSRect(x: x - 1, y: rect.minY, width: 1, height: rect.height).fill()
    }

    private func fillSelection(_ rect: NSRect) {
        let active = window?.isKeyWindow == true && window?.firstResponder === self
        (active ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).setFill()
        rect.fill()
    }

    private func isSelected(_ r: Int, side: Side) -> Bool {
        guard let selection, selection.contains(r) else { return false }
        let kind = doc.splitRows[r].kind
        return mode == .hunk || side == selectionSide || kind == .hunk || kind == .meta
    }

    // MARK: Hunk bar

    private func drawHunkBar(row r: Int, header: String, in rect: NSRect) {
        DiffStyle.hunkBackground.setFill()
        rect.fill()
        // Top border between hunks; the first hunk sits right under the header's divider.
        if rect.minY > 0 {
            DiffStyle.separator.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: Theme.Metrics.hairline).fill()
        }
        if selection?.contains(r) == true { fillSelection(rect.insetBy(dx: 0, dy: 1)) }

        let buttons = buttonRects(in: rect)
        let textRight = (buttons.first?.1.minX ?? rect.maxX) - DiffStyle.buttonSpacing
        let title = NSAttributedString(string: header, attributes: [
            .font: DiffStyle.gutterFont, .foregroundColor: DiffStyle.secondaryText,
        ])
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: rect.minX, y: rect.minY, width: max(0, textRight - rect.minX), height: rect.height).clip()
        title.draw(at: NSPoint(x: DiffStyle.hunkInset, y: rect.minY + (rect.height - gutterTextHeight) / 2))
        NSGraphicsContext.restoreGraphicsState()

        for (action, frame) in buttons {
            let hit = ButtonHit(row: r, action: action)
            let alpha: CGFloat = !actionsEnabled ? 0.05 : pressed == hit ? 0.26 : hover == hit ? 0.18 : 0.10
            let path = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: DiffStyle.buttonRadius, yRadius: DiffStyle.buttonRadius)
            // Opaque base first so the hunk band doesn't show through the tint.
            DiffStyle.buttonBase.setFill()
            path.fill()
            action.tint.withAlphaComponent(alpha).setFill()
            path.fill()
            action.tint.withAlphaComponent(actionsEnabled ? 0.55 : 0.25).setStroke()
            path.lineWidth = 1
            path.stroke()
            let label = buttonTitle(action)
            let size = label.size()
            label.draw(at: NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
    }

    private func buttonTitle(_ action: HunkAction) -> NSAttributedString {
        var color: NSColor = !actionsEnabled ? .tertiaryLabelColor : action.tint
        // Same darkening as Color.readableTint in light mode.
        if actionsEnabled, effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua {
            color = color.blended(withFraction: 0.28, of: .black) ?? color
        }
        return NSAttributedString(string: action.title, attributes: [.font: DiffStyle.buttonFont, .foregroundColor: color])
    }

    /// Buttons of a hunk row, left to right, aligned to the right edge.
    private func buttonRects(in rect: NSRect) -> [(HunkAction, NSRect)] {
        var x = rect.maxX - DiffStyle.hunkInset
        var result: [(HunkAction, NSRect)] = []
        for action in actions.reversed() {
            let w = ceil(buttonTitle(action).size().width) + DiffStyle.buttonPadding * 2
            x -= w
            result.append((action, NSRect(x: x, y: rect.midY - DiffStyle.buttonHeight / 2,
                                          width: w, height: DiffStyle.buttonHeight)))
            x -= DiffStyle.buttonSpacing
        }
        return result.reversed()
    }

    private func buttonHit(at p: NSPoint) -> ButtonHit? {
        guard !actions.isEmpty, let r = row(atY: p.y, clamped: false), hunkIndex(row: r) != nil else { return nil }
        guard let (action, _) = buttonRects(in: rowRect(r)).first(where: { $0.1.contains(p) }) else { return nil }
        return ButtonHit(row: r, action: action)
    }

    // MARK: Text

    private var gutterAttributes: [NSAttributedString.Key: Any] {
        [.font: DiffStyle.gutterFont, .foregroundColor: DiffStyle.gutterText]
    }

    private func attributed(_ index: Int) -> NSAttributedString {
        if let cached = textCache[index] { return cached }
        let line = doc.lines[index]
        var text = line.text
        if text.utf16.count > DiffStyle.maxDrawnColumns {
            text = String(text.utf16.prefix(DiffStyle.maxDrawnColumns)) ?? String(text.prefix(DiffStyle.maxDrawnColumns))
            text += " …"
        }
        let attrs: [NSAttributedString.Key: Any] = line.kind == .meta
            ? [.font: DiffStyle.metaFont, .foregroundColor: DiffStyle.secondaryText]
            : [.font: DiffStyle.font, .foregroundColor: DiffStyle.text]
        let s = NSAttributedString(string: text, attributes: attrs)
        if textCache.count > 5_000 { textCache.removeAll(); changeCache.removeAll() }
        textCache[index] = s
        return s
    }

    /// X offsets of the changed span, measured so wide characters line up.
    private func changeOffsets(_ index: Int) -> (CGFloat, CGFloat)? {
        if let cached = changeCache[index] { return cached }
        guard let change = doc.lines[index].change else { return nil }
        let s = attributed(index)
        let start = min(change.location, s.length)
        let end = min(change.location + change.length, s.length)
        let x0 = s.attributedSubstring(from: NSRange(location: 0, length: start)).size().width
        let x1 = s.attributedSubstring(from: NSRange(location: 0, length: end)).size().width
        changeCache[index] = (x0, x1)
        return (x0, x1)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        setHover(buttonHit(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHover(nil)
    }

    private func setHover(_ hit: ButtonHit?) {
        guard hit != hover else { return }
        for r in [hover?.row, hit?.row].compactMap({ $0 }) { setNeedsDisplay(rowRect(r)) }
        hover = hit
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let hit = buttonHit(at: p) {
            pressed = hit
            setNeedsDisplay(rowRect(hit.row))
            return
        }
        guard let r = row(atY: p.y, clamped: false) else {
            selection = nil
            needsDisplay = true
            return
        }
        if mode == .split { selectionSide = p.x < splitMid ? .left : .right }
        if event.modifierFlags.contains(.shift), let a = anchor {
            selection = min(a, r)...max(a, r)
        } else {
            anchor = r
            selection = r...r
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if pressed != nil {
            setHover(buttonHit(at: p))
            return
        }
        guard let a = anchor, let r = row(atY: p.y, clamped: true) else { return }
        autoscroll(with: event)
        selection = min(a, r)...max(a, r)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let hit = pressed else { return }
        pressed = nil
        setNeedsDisplay(rowRect(hit.row))
        let p = convert(event.locationInWindow, from: nil)
        guard actionsEnabled, buttonHit(at: p) == hit, let hunk = hunkIndex(row: hit.row) else { return }
        onHunkAction?(hit.action, hunk)
    }

    override func scrollWheel(with event: NSEvent) {
        let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * DiffStyle.lineHeight
        if dx != 0, maxHOffset > 0 {
            hOffset -= dx
            clampHOffset()
            needsDisplay = true
        }
        super.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let r = row(atY: p.y, clamped: false) else { return nil }
        if selection?.contains(r) != true {
            anchor = r
            selection = r...r
            if mode == .split { selectionSide = p.x < splitMid ? .left : .right }
            needsDisplay = true
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a")
        if let hunk = owningHunk(row: r), !actions.isEmpty {
            menu.addItem(.separator())
            for action in actions {
                let item = menu.addItem(withTitle: action.title + (action == .discard ? "…" : ""),
                                        action: #selector(menuHunkAction(_:)), keyEquivalent: "")
                item.representedObject = [action, hunk] as [Any]
                item.target = self
                item.isEnabled = actionsEnabled
            }
        }
        return menu
    }

    @objc private func menuHunkAction(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any], let action = pair.first as? HunkAction,
              let hunk = pair.last as? Int else { return }
        onHunkAction?(action, hunk)
    }

    // MARK: Keyboard and copy

    override func keyDown(with event: NSEvent) {
        guard let clip = enclosingScrollView?.contentView else { return super.keyDown(with: event) }
        let page = clip.bounds.height - DiffStyle.lineHeight * 2
        var y = clip.bounds.minY
        switch event.specialKey {
        case .upArrow: y -= DiffStyle.lineHeight * 3
        case .downArrow: y += DiffStyle.lineHeight * 3
        case .pageUp: y -= page
        case .pageDown: y += page
        case .home: y = 0
        case .end: y = bounds.height
        case .leftArrow, .rightArrow:
            hOffset += (event.specialKey == .leftArrow ? -1 : 1) * charWidth * 8
            clampHOffset()
            needsDisplay = true
            return
        default:
            if event.charactersIgnoringModifiers == " " {
                y += event.modifierFlags.contains(.shift) ? -page : page
            } else {
                return super.keyDown(with: event)
            }
        }
        y = min(max(0, y), max(0, bounds.height - clip.bounds.height))
        clip.scroll(to: NSPoint(x: 0, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    /// Copies the selected lines with their original content (tabs kept, no
    /// signs). Hunk headers and notes are left out unless nothing else is selected.
    @objc func copy(_ sender: Any?) {
        guard let selection else { return }
        var code: [String] = [], other: [String] = []
        for r in selection {
            switch mode {
            case .hunk:
                let line = doc.lines[r]
                if line.kind == .hunk || line.kind == .meta { other.append(line.text) }
                else { code.append(doc.sourceText(ofLine: r)) }
            case .split:
                let row = doc.splitRows[r]
                switch row.kind {
                case .code:
                    if let i = selectionSide == .left ? row.left : row.right { code.append(doc.sourceText(ofLine: i)) }
                case .hunk, .meta:
                    if let l = row.left { other.append(doc.lines[l].text) }
                case .note:
                    if let i = selectionSide == .left ? row.left : row.right { other.append(doc.lines[i].text) }
                }
            }
        }
        External.copy((code.isEmpty ? other : code).joined(separator: "\n"))
    }

    override func selectAll(_ sender: Any?) {
        guard rowCount > 0 else { return }
        anchor = 0
        selection = 0...(rowCount - 1)
        needsDisplay = true
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): selection != nil
        case #selector(selectAll(_:)): rowCount > 0
        case #selector(menuHunkAction(_:)): actionsEnabled
        default: true
        }
    }
}
