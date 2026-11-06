import Foundation

public struct DiffLine: Hashable, Sendable {
    public enum Kind: UInt8, Sendable { case context, added, removed, hunk, meta }
    public let kind: Kind
    public let oldNumber: Int?
    public let newNumber: Int?
    public let text: String   // without the leading +/-/space
}

/// Turns unified diff text into display lines with line numbers.
/// File headers (`diff --git`, `index`, `---`, `+++`) are dropped; other
/// header lines like "new file mode" or "Binary files differ" are kept as meta.
public enum DiffParser {
    public static func parse(_ text: String, maxLines: Int = 20_000) -> (lines: [DiffLine], truncated: Bool) {
        var result: [DiffLine] = []
        var oldNo = 0, newNo = 0
        var inHunk = false

        // isNewline also matches "\r\n", which is a single Character in Swift.
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if result.count >= maxLines { return (result, true) }
            let line = Substring(raw)

            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                inHunk = false
                continue
            }
            if line.hasPrefix("@@") {
                inHunk = true
                (oldNo, newNo) = parseHunkHeader(line)
                result.append(DiffLine(kind: .hunk, oldNumber: nil, newNumber: nil, text: String(line)))
                continue
            }
            if !inHunk {
                if line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ") || line.isEmpty {
                    continue
                }
                result.append(DiffLine(kind: .meta, oldNumber: nil, newNumber: nil, text: String(line)))
                continue
            }

            guard let first = line.first else {
                // An empty line inside a hunk is only possible at the very end.
                continue
            }
            let rest = String(line.dropFirst())
            switch first {
            case "+":
                result.append(DiffLine(kind: .added, oldNumber: nil, newNumber: newNo, text: rest))
                newNo += 1
            case "-":
                result.append(DiffLine(kind: .removed, oldNumber: oldNo, newNumber: nil, text: rest))
                oldNo += 1
            case " ":
                result.append(DiffLine(kind: .context, oldNumber: oldNo, newNumber: newNo, text: rest))
                oldNo += 1; newNo += 1
            case "\\":
                result.append(DiffLine(kind: .meta, oldNumber: nil, newNumber: nil, text: String(line)))
            default:
                inHunk = false
                result.append(DiffLine(kind: .meta, oldNumber: nil, newNumber: nil, text: String(line)))
            }
        }
        return (result, false)
    }

    /// "@@ -12,5 +12,7 @@ ..." -> (12, 12)
    static func parseHunkHeader(_ line: Substring) -> (Int, Int) {
        var old = 0, new = 0
        for part in line.split(separator: " ") {
            if part.hasPrefix("-"), let n = Int(part.dropFirst().split(separator: ",").first ?? "") { old = n }
            else if part.hasPrefix("+"), let n = Int(part.dropFirst().split(separator: ",").first ?? "") { new = n; break }
        }
        return (old, new)
    }
}
