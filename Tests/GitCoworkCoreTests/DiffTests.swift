import Foundation
import Testing
@testable import GitCoworkCore

// Tests for the diff parser the app uses, and for single-hunk patches,
// which are checked against real `git apply` in a temporary repo.

/// Runs git in `dir`; returns stdout as bytes.
@discardableResult
private func git(_ args: [String], in dir: URL, input: Data? = nil) throws -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["git", "-c", "core.autocrlf=false", "-c", "user.name=T", "-c", "user.email=t@x"] + args
    p.currentDirectoryURL = dir
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    let inPipe = Pipe()
    p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
    try p.run()
    if let input {
        inPipe.fileHandleForWriting.write(input)
        try inPipe.fileHandleForWriting.close()
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus != 0 && args.first != "diff" {
        throw NSError(domain: "git", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: args.joined(separator: " ")])
    }
    return data
}

/// A fresh repo with `file` committed as `base` and then changed to `changed` (unstaged).
private func repo(file: String = "f.txt", base: Data, changed: Data) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gc-diff-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try git(["init", "-q"], in: dir)
    try base.write(to: dir.appendingPathComponent(file))
    try git(["add", "."], in: dir)
    try git(["commit", "-qm", "base"], in: dir)
    try changed.write(to: dir.appendingPathComponent(file))
    return dir
}

/// Same flags the app uses for working-copy diffs.
private func workingDiff(_ dir: URL, cached: Bool = false) throws -> Data {
    try git(["diff", "--no-color", "--no-ext-diff", "--no-textconv", "-U3"] + (cached ? ["--cached"] : []) + ["--", "f.txt"], in: dir)
}

private func lines(_ n: ClosedRange<Int>, change: Set<Int> = [], suffix: String = "") -> Data {
    Data(n.map { change.contains($0) ? "line \($0) changed\(suffix)\n" : "line \($0)\(suffix)\n" }.joined().utf8)
}

@Suite struct DiffDocumentTests {
    @Test func parsesLineNumbersAndCounts() {
        let text = """
        diff --git a/f b/f
        index 1..2 100644
        --- a/f
        +++ b/f
        @@ -10,3 +10,4 @@ func x()
         same
        -old
        +new
        +added
         end
        """
        let doc = DiffDocument.parse(text)
        #expect(doc.hunks.count == 1)
        #expect(doc.added == 2 && doc.removed == 1)
        let code = doc.lines.filter { $0.kind != .hunk && $0.kind != .meta }
        #expect(code.map(\.kind) == [.context, .removed, .added, .added, .context])
        #expect(code[0].old == 10 && code[0].new == 10)
        #expect(code[1].old == 11)
        #expect(code[3].new == 12)
        #expect(code[4].old == 12 && code[4].new == 13)
    }

    @Test func splitsCRLFLines() {
        let doc = DiffDocument.parse(Data("diff --git a/f b/f\r\n--- a/f\r\n+++ b/f\r\n@@ -1 +1 @@\r\n-a\r\n+b\r\n".utf8))
        #expect(doc.added == 1 && doc.removed == 1)
        #expect(doc.lines.contains { $0.kind == .added && $0.text == "b" })
    }

    @Test func emptyForBinary() {
        let doc = DiffDocument.parse("diff --git a/x.png b/x.png\nBinary files a/x.png and b/x.png differ\n")
        #expect(doc.isEmpty)
    }

    @Test func truncatesLongDiffs() {
        let body = (1...50).map { "+l\($0)" }.joined(separator: "\n")
        let doc = DiffDocument.parse("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -0,0 +1,50 @@\n" + body, maxLines: 10)
        #expect(doc.truncated)
    }

    @Test func intraLineChangeRange() throws {
        let r = try #require(DiffDocument.changedRanges("let value = 1", "let value = 2"))
        #expect(r.0.location == 12 && r.0.length == 1)
        #expect(r.1.location == 12 && r.1.length == 1)
    }
}

@Suite struct HunkPatchTests {
    /// Stages only the second of two hunks and checks the index got exactly that.
    @Test func stagesOneHunkOfTwo() throws {
        let dir = try repo(base: lines(1...30), changed: lines(1...30, change: [3, 25]))
        let doc = DiffDocument.parse(try workingDiff(dir))
        #expect(doc.hunks.count == 2)
        let patch = try #require(doc.patch(forHunk: 1))
        try git(["apply", "--cached", "-"], in: dir, input: patch)
        let staged = String(decoding: try workingDiff(dir, cached: true), as: UTF8.self)
        #expect(staged.contains("+line 25 changed"))
        #expect(!staged.contains("line 3 changed"))
    }

    /// Unstage = reverse-apply the staged hunk to the index.
    @Test func unstagesAHunk() throws {
        let dir = try repo(base: lines(1...30), changed: lines(1...30, change: [3, 25]))
        try git(["add", "f.txt"], in: dir)
        let doc = DiffDocument.parse(try workingDiff(dir, cached: true))
        let patch = try #require(doc.patch(forHunk: 0))
        try git(["apply", "--cached", "--reverse", "-"], in: dir, input: patch)
        let staged = String(decoding: try workingDiff(dir, cached: true), as: UTF8.self)
        #expect(!staged.contains("line 3 changed"))
        #expect(staged.contains("line 25 changed"))
    }

    /// Discard = reverse-apply to the working tree; the other hunk stays.
    @Test func discardsAHunk() throws {
        let dir = try repo(base: lines(1...30), changed: lines(1...30, change: [3, 25]))
        let doc = DiffDocument.parse(try workingDiff(dir))
        try git(["apply", "--reverse", "-"], in: dir, input: try #require(doc.patch(forHunk: 0)))
        let file = String(decoding: try Data(contentsOf: dir.appendingPathComponent("f.txt")), as: UTF8.self)
        #expect(!file.contains("line 3 changed"))
        #expect(file.contains("line 25 changed"))
    }

    /// Non-UTF-8 bytes must reach the index byte for byte.
    @Test func keepsLatin1Bytes() throws {
        var changed = lines(1...10)
        changed.append(contentsOf: [0x63, 0x61, 0x66, 0xE9, 0x0A])   // "café" in Latin-1
        let dir = try repo(base: lines(1...10), changed: changed)
        let doc = DiffDocument.parse(try workingDiff(dir))
        try git(["apply", "--cached", "-"], in: dir, input: try #require(doc.patch(forHunk: 0)))
        let indexed = try git(["show", ":f.txt"], in: dir)
        #expect(indexed == changed)
    }

    @Test func crlfAndMissingFinalNewline() throws {
        var changed = lines(1...6, change: [2], suffix: "\r")
        changed.append(contentsOf: Data("no newline at end".utf8))
        let dir = try repo(base: lines(1...6, suffix: "\r"), changed: changed)
        let doc = DiffDocument.parse(try workingDiff(dir))
        try git(["apply", "--cached", "-"], in: dir, input: try #require(doc.patch(forHunk: 0)))
        #expect(try git(["show", ":f.txt"], in: dir) == changed)
    }
}

@Suite struct NameTests {
    @Test func refNames() {
        for ok in ["main", "feature/login", "CW-a3f9-cache", "release-1.8.6"] { #expect(RefName.isValid(ok), "\(ok)") }
        for bad in ["", "@", "-x", "a..b", "a b", "x.lock", "a/.hidden", "a/b.lock/c", "a~1", "a^", "a:b", "x/", "a@{1}", "tab\tname"] {
            #expect(!RefName.isValid(bad), "\(bad)")
        }
    }

    @Test func slugsAndBranchNames() {
        #expect(RefName.slug("Cache user sessions!") == "cache-user-sessions")
        #expect(RefName.slug("  Ümlaut & émoji 🎉 ok ") == "mlaut-moji-ok")
        let t = CoworkTask(id: "CW-a3f9", title: "Fix: login (again)", author: "a@x", created: .now, updated: .now)
        #expect(RefName.branch(for: t) == "CW-a3f9-fix-login-again")
        #expect(RefName.isValid(RefName.branch(for: t)))
    }

    @Test func initialsAndHash() {
        #expect("Anna Berg".initials == "AB")
        #expect("claude".initials == "C")
        #expect("".initials == "?")
        #expect("anna@x.com".stableHash == "anna@x.com".stableHash)
    }

    @Test func changeCounts() {
        let c = ChangeCounts([
            FileChange(path: "a", status: .modified, area: .unstaged),
            FileChange(path: "a", status: .modified, area: .staged),   // same path counts once
            FileChange(path: "b", status: .untracked, area: .untracked),
            FileChange(path: "c", status: .deleted, area: .staged),
        ])
        #expect(c.modified == 1 && c.added == 1 && c.deleted == 1 && c.total == 3)
    }
}
