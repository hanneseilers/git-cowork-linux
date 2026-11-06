import Foundation

enum DiffMode: String, CaseIterable {
    case hunk, split

    var title: String { self == .hunk ? L("Hunk") : L("Split") }
}
