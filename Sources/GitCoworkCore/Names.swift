import Foundation

/// Branch and tag names: git's rules (see `git help check-ref-format`) and
/// turning a task title into a branch name.
public enum RefName {
    /// Whether `name` is a valid branch or tag name.
    public static func isValid(_ name: String) -> Bool {
        let n = name
        guard !n.isEmpty, n != "@", !n.hasPrefix("-"), !n.hasPrefix("/"), !n.hasSuffix("/"),
              !n.hasSuffix(".") else { return false }
        for bad in ["..", "~", "^", ":", "?", "*", "[", "\\", " ", "@{", "//"] where n.contains(bad) { return false }
        if n.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return false }
        // Each "/"-separated part: not starting with "." and not ending in ".lock".
        for part in n.split(separator: "/") where part.hasPrefix(".") || part.hasSuffix(".lock") { return false }
        return true
    }

    /// "Cache user sessions!" -> "cache-user-sessions", at most `maxLength` characters.
    public static func slug(_ title: String, maxLength: Int = 40) -> String {
        var out = ""
        var dash = false
        for ch in title.lowercased().unicodeScalars {
            if ch.isASCII && CharacterSet.alphanumerics.contains(ch) {
                if dash && !out.isEmpty { out.append("-") }
                out.unicodeScalars.append(ch)
                dash = false
            } else {
                dash = true
            }
            if out.count >= maxLength { break }
        }
        return out
    }

    /// Branch for "Start Task": "CW-a3f9-cache-user-sessions".
    public static func branch(for task: CoworkTask) -> String {
        let s = slug(task.title)
        return s.isEmpty ? task.id : "\(task.id)-\(s)"
    }
}

extension String {
    /// "Anna Berg" -> "AB", "claude" -> "C", "" -> "?". Used for every avatar.
    public var initials: String {
        let parts = split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
        let letters = parts.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    /// Same value on every launch (Swift's hashValue is randomized). Used to
    /// give each person and label a stable color.
    public var stableHash: Int {
        var h: UInt32 = 2_166_136_261
        for b in utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return Int(h % 10_000)
    }
}

extension TeamMember {
    /// Name, or the email when no name is known.
    public var displayName: String { name.isEmpty ? email : name }
}

/// How many files were modified, added, deleted, renamed or conflicted.
public struct ChangeCounts: Hashable, Sendable {
    public var modified = 0
    public var added = 0
    public var deleted = 0
    public var renamed = 0
    public var conflicted = 0

    public init() {}

    /// Counts each path once. Working copy: untracked files count as added.
    public init(_ changes: [FileChange]) {
        var seen = Set<String>()
        for c in changes where seen.insert(c.path).inserted {
            switch c.status {
            case .added, .copied, .untracked: added += 1
            case .deleted: deleted += 1
            case .renamed: renamed += 1
            case .conflicted: conflicted += 1
            case .modified, .typeChanged, .unknown: modified += 1
            }
        }
    }

    public var total: Int { modified + added + deleted + renamed + conflicted }
}
