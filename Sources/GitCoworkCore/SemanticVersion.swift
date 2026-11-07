import Foundation

/// "1.2.3" (optionally "v1.2.3" or "1.2.3-beta.1"), compared the semver way:
/// numbers numerically, and a pre-release sorts before its release.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// "beta.1" in "1.2.3-beta.1"; empty for a release.
    public let prerelease: String

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let core = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let parts = core[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        major = parts[0]!
        minor = parts.count > 1 ? parts[1]! : 0
        patch = parts.count > 2 ? parts[2]! : 0
        prerelease = core.count > 1 ? core[1] : ""
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-\(prerelease)")
    }

    public static func < (a: Self, b: Self) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        // 1.2.3-beta < 1.2.3; between two pre-releases, compare identifiers.
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): return a.prerelease.compare(b.prerelease, options: .numeric) == .orderedAscending
        }
    }
}
