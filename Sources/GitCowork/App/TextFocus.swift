import AppKit
import Observation

/// Whether the key window is editing text, so Edit > Undo can go to the text
/// (typing in the commit message) instead of the last git action.
@MainActor @Observable
final class TextFocus {
    static let shared = TextFocus()

    private(set) var isEditing = false
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        // First-responder changes have no notification of their own; checking
        // once per event loop pass is cheap.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let editing = TextFocus.editingTextView() != nil
                if editing != TextFocus.shared.isEditing { TextFocus.shared.isEditing = editing }
            }
        }
    }

    /// The editable text view (a text field's field editor or a text editor)
    /// that has keyboard focus, if any.
    static func editingTextView() -> NSTextView? {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable else { return nil }
        return tv
    }

    static func undoText() { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
    static func redoText() { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
}
