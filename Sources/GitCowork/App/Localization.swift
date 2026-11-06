import GitCoworkCore
import SwiftUI

// UI text is written in English and looked up in Localizable.strings
// (Resources/<lang>.lproj). SwiftUI does that by itself for literals like
// Text("Commit"); these helpers cover labels that travel as a String first.

extension Text {
    /// A UI label held in a String, e.g. a component's `title`. Not for user
    /// data such as branch names or commit messages. Looked up as is, with no
    /// format processing, so a `%` in git's error output shows unchanged.
    init(ui key: String) {
        self.init(verbatim: L(key))
    }
}

/// Translated String, for AppKit, alerts and computed labels.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

extension TaskStatus {
    /// Translated column name for the screen. `title` stays English: it's
    /// also used in the task sync's commit messages.
    var label: String { L(title) }
}
