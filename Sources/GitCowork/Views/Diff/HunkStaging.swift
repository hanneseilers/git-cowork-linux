import Foundation
import GitCoworkCore

/// Stages, unstages or discards one hunk by feeding a single-hunk patch,
/// cut from git's raw output, to `git apply` on stdin.
@MainActor
enum HunkStaging {
    /// Which hunk buttons a diff offers. Renames, type changes (symlink ↔ file),
    /// conflicts and untracked files only get file-level actions.
    static func actions(for target: DiffTarget, document: DiffDocument) -> [HunkAction] {
        guard case .working(let f) = target, f.oldPath == nil, f.status != .typeChanged,
              document.supportsHunkActions else { return [] }
        switch f.area {
        case .unstaged: return [.discard, .stage]
        case .staged: return [.unstage]
        case .untracked, .conflicted: return []
        }
    }

    static func confirmDiscard(hunk: Int, in doc: DiffDocument, file: FileChange, model: RepoModel) {
        let lines = doc.newRange(ofHunk: hunk).map { " (lines \($0.lowerBound)–\($0.upperBound))" } ?? ""
        model.confirmation = Confirmation(
            title: "Discard this hunk?",
            message: String(localized: "Removes the change in \(file.fileName)\(lines) from the working copy. This can't be undone."),
            confirmTitle: "Discard Hunk"
        ) {
            await run(.discard, hunk: hunk, in: doc, file: file, model: model)
        }
    }

    static func run(_ action: HunkAction, hunk: Int, in doc: DiffDocument, file: FileChange, model: RepoModel) async {
        guard let patch = doc.patch(forHunk: hunk) else { return }
        if await model.applyHunk(patch, action, zeroContext: !doc.hunks[hunk].hasContext) {
            follow(file, model: model)
        }
    }

    /// When the last hunk moved away, show the file's other side, or go back.
    private static func follow(_ file: FileChange, model: RepoModel) {
        let st = model.status
        let same = file.area == .staged ? st.staged : st.unstaged
        if same.contains(where: { $0.path == file.path }) { return }
        let other = file.area == .staged ? st.unstaged : st.staged
        if let next = other.first(where: { $0.path == file.path }) {
            model.openDiff = .working(next)
        } else {
            model.openDiff = nil
        }
    }
}
