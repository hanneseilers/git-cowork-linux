import AppKit
import GitCoworkCore

// Mouse, keyboard and copy for DiffCanvas.
extension DiffCanvas {
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

    func setHover(_ hit: ButtonHit?) {
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
        menu.addItem(withTitle: L("Select All"), action: #selector(selectAll(_:)), keyEquivalent: "a")
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
