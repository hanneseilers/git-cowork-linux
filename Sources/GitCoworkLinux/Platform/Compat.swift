// Declarations the shared model files expect from the macOS app's view
// layer, which isn't compiled on Linux. Kept to the same names and meaning.
@_exported import FoundationNetworking
import Foundation
import GitCoworkCore

extension TeamMember {
    /// What to type after "@": the team handle, or the part of the email before "@".
    var mentionHandle: String {
        handle.isEmpty ? String(email.split(separator: "@").first ?? "") : handle
    }
}

/// A button on a hunk bar.
enum HunkAction: Hashable {
    case stage, unstage, discard

    var title: String {
        switch self {
        case .stage: L("Stage Hunk")
        case .unstage: L("Unstage Hunk")
        case .discard: L("Discard Hunk")
        }
    }
}
