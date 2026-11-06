import GitCoworkCore
import AppKit
import SwiftUI

/// Scrollable diff: unified ("Hunk") or side by side ("Split"), drawn by `DiffCanvas`.
/// `version` changes when the content changes; `documentID` when another file is shown
/// (only then the view scrolls back to the top, so live reloads keep the position).
struct DiffTextView: NSViewRepresentable {
    let document: DiffDocument
    let version: Int
    let documentID: String
    let mode: DiffMode
    var actions: [HunkAction] = []
    var actionsEnabled = true
    var onHunkAction: (HunkAction, Int) -> Void = { _, _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = DiffCanvas()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? DiffCanvas else { return }
        canvas.onHunkAction = onHunkAction
        canvas.update(document: document, version: version, documentID: documentID, mode: mode,
                      actions: actions, actionsEnabled: actionsEnabled)
    }
}
