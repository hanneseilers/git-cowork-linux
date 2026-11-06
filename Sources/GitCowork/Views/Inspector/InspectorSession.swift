import Foundation
import GitCoworkCore
import Observation

/// Inspector state that has to outlive the panels themselves. RepoView rebuilds
/// ChangesPanel / CommitPanel whenever the selection changes, so plain @State
/// would reset (amend checkbox, last shown commit, handled focus requests).
/// One session per RepoModel, held weakly so it goes away with the model.
@MainActor @Observable
final class InspectorSession {
    /// "Amend previous commit" is ticked.
    var amend = false
    /// The draft the user had before ticking amend, restored when unticking.
    @ObservationIgnored var preAmendDraft: (summary: String, details: String)?
    /// HEAD's message as loaded into the draft by ticking amend.
    @ObservationIgnored var loadedAmendMessage: (summary: String, details: String)?
    /// Last model.focusSummaryToken the composer acted on.
    @ObservationIgnored var focusHandled = 0
    /// Last commit shown in the commit panel, kept so a new selection can show
    /// the previous commit until its own data has loaded (no spinner flash).
    @ObservationIgnored var lastCommit: (detail: CommitDetail, files: [FileChange])?

    private static let table = NSMapTable<RepoModel, InspectorSession>.weakToStrongObjects()

    static func of(_ model: RepoModel) -> InspectorSession {
        if let s = table.object(forKey: model) { return s }
        let s = InspectorSession()
        table.setObject(s, forKey: model)
        return s
    }

    func resetAmend() {
        amend = false
        preAmendDraft = nil
        loadedAmendMessage = nil
    }
}
