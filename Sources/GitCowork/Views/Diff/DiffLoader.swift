import Foundation
import GitCoworkCore

/// Reads diffs as raw bytes. `GitRunner` decodes stdout as UTF-8, which turns
/// Latin-1 and other non-UTF-8 bytes into U+FFFD; a hunk patch built from that
/// would write the replacement bytes into the index or working copy. So diffs
/// are read here as `Data` and only decoded line by line for display.
enum DiffLoader {
    /// Flags for every diff the pane shows: no external diff tool, no colors,
    /// fixed prefixes whatever `diff.noprefix` / `diff.mnemonicPrefix` say.
    private static let baseFlags = ["--no-ext-diff", "--no-color", "--src-prefix=a/", "--dst-prefix=b/"]

    /// Config that would make `git diff` print something `git apply` can't take back.
    private static let config = [
        "-c", "core.quotepath=false",
        "-c", "color.ui=false",
        "-c", "diff.suppressBlankEmpty=false",
    ]

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
        let gitPath = GitRunner.shared.gitPath
        let env = environment
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: gitPath)
                p.arguments = config + args
                p.currentDirectoryURL = dir
                p.environment = env
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: Data()); return }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: okCodes.contains(p.terminationStatus) ? data : Data())
            }
        }
    }

    /// Same settings as `GitRunner` for read-only commands (no hooks run, so
    /// the login-shell PATH isn't needed).
    private static let environment: [String: String] = {
        var e = ProcessInfo.processInfo.environment
        let base = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        e["PATH"] = [e["PATH"], base].compactMap { $0 }.joined(separator: ":")
        e["GIT_TERMINAL_PROMPT"] = "0"
        e["GIT_OPTIONAL_LOCKS"] = "0"     // a diff must not refresh the index (would retrigger file watching)
        e["LC_ALL"] = "en_US.UTF-8"
        return e
    }()
}
