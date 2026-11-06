import Foundation
import GitCoworkCore

/// Reads diffs as raw bytes (GitRunner.executeData). Decoding to String would
/// turn Latin-1 and other non-UTF-8 bytes into U+FFFD, and a hunk patch built
/// from that would write the replacement bytes into the index or working copy.
enum DiffLoader {
    /// Flags for every diff the pane shows: no external diff tool, no colors,
    /// fixed prefixes whatever `diff.noprefix` / `diff.mnemonicPrefix` say.
    private static let baseFlags = ["--no-ext-diff", "--no-color", "--src-prefix=a/", "--dst-prefix=b/"]

    /// Config that would make `git diff` print something `git apply` can't take back
    /// (GitRunner already turns off quoted paths and colors).
    private static let config = ["-c", "diff.suppressBlankEmpty=false"]

    /// Diff of a working-copy file. Staged and unstaged diffs are what hunk
    /// actions turn into patches, so they skip textconv (the patch must hold
    /// the real file bytes, not converted text).
    static func working(_ change: FileChange, root: URL) async -> Data {
        let flags = baseFlags + ["--no-textconv"]
        switch change.area {
        case .staged:
            var paths = [change.path]
            if let old = change.oldPath { paths.insert(old, at: 0) }
            return await read(["diff", "--cached", "-M"] + flags + ["--"] + paths, in: root)
        case .unstaged:
            return await read(["diff", "--no-renames"] + flags + ["--", change.path], in: root)
        case .conflicted:
            return await read(["diff"] + flags + ["--", change.path], in: root)
        case .untracked:
            if change.path.hasSuffix("/") { return Data() }   // untracked folder
            // --no-index exits 1 when the files differ.
            return await read(["diff", "--no-index"] + flags + ["--", "/dev/null", change.path], in: root, okCodes: [0, 1])
        }
    }

    /// Diff of one file in a commit against its first parent. Read-only, so
    /// textconv drivers (plist, docx, git-crypt) still apply.
    static func commit(_ detail: CommitDetail, file: FileChange, root: URL) async -> Data {
        var paths = [file.path]
        if let old = file.oldPath { paths.insert(old, at: 0) }
        if let p = detail.parents.first {
            return await read(["diff", "-M"] + baseFlags + [p, detail.id, "--"] + paths, in: root)
        }
        return await read(["show", "--format="] + baseFlags + [detail.id, "--"] + paths, in: root)
    }

    /// Runs git and returns stdout untouched; empty on failure.
    static func read(_ args: [String], in dir: URL, okCodes: Set<Int32> = [0]) async -> Data {
        let r = await GitRunner.shared.executeData(config + args, in: dir)
        return okCodes.contains(r.exitCode) ? r.stdout : Data()
    }
}
