import Foundation

/// One file's diff. Keeps git's output as raw bytes (single-hunk patches for
/// staging are cut from those, so non-UTF-8 content survives byte for byte)
/// next to decoded display lines for the unified and split views.
public struct DiffDocument: Sendable {
    public struct Hunk: Sendable {
        /// The "@@ … @@" line, decoded for display.
        public let header: String
        public let oldStart: Int
        public let newStart: Int
        /// Bytes of the file header this hunk belongs to ("diff --git" … "+++ b/x").
        public let fileHeader: Range<Int>
        /// Bytes from the "@@" line to the end of the hunk's last line.
        public var body: Range<Int>
        /// Has unchanged context lines (a zero-context hunk needs --unidiff-zero).
        public var hasContext = false
    }

    public enum Kind: UInt8, Sendable { case context, added, removed, hunk, meta }

    public struct Line: Sendable {
        public let kind: Kind
        public let old: Int?
        public let new: Int?
        /// Display text: no +/- sign, tabs expanded, no trailing CR.
        public let text: String
        /// Index into `hunks`, or -1 outside any hunk.
        public let hunk: Int
        /// Bytes of the original content in `raw` (no sign; tabs kept), for copying.
        /// Empty for hunk and meta rows.
        public var source: Range<Int> = 0..<0
        /// Changed span (UTF-16) for paired removed/added lines.
        public var change: NSRange?
    }

    /// One row of the side-by-side view. `left`/`right` index into `lines`.
    /// Hunk and file-level meta rows span both sides and use `left`; a note
    /// ("No newline at end of file") sits on the side(s) it belongs to.
    public struct SplitRow: Sendable {
        public enum Kind: UInt8, Sendable { case code, hunk, meta, note }
        public let kind: Kind
        public let left: Int?
        public let right: Int?
    }

    public init() {}

    /// git's output, untouched.
    public var raw = Data()
    public var hunks: [Hunk] = []
    public var lines: [Line] = []
    public var splitRows: [SplitRow] = []
    public var truncated = false
    public var added = 0
    public var removed = 0
    /// Number of "diff " sections. A type change (symlink ↔ file) prints a
    /// deletion and an addition; a single hunk of those can't be staged alone.
    public var sections = 0
    /// Longest display line in UTF-16 units, for horizontal scrolling.
    public var maxColumns = 0
    /// Highest line number, for the gutter width.
    public var maxLineNumber = 0

    /// No text changes (binary, empty, or mode-only diffs).
    public var isEmpty: Bool { hunks.isEmpty }

    /// Hunks can be staged, unstaged or discarded one by one.
    public var supportsHunkActions: Bool { sections <= 1 && !hunks.isEmpty }

    /// A patch with the file header and only hunk `index`, for `git apply`.
    /// Built from the raw bytes, never from decoded text.
    public func patch(forHunk index: Int) -> Data? {
        guard hunks.indices.contains(index) else { return nil }
        let h = hunks[index]
        guard !h.fileHeader.isEmpty, h.fileHeader.upperBound <= raw.count, h.body.upperBound <= raw.count else { return nil }
        var out = Data()
        out.reserveCapacity(h.fileHeader.count + h.body.count + 16)
        let base = raw.startIndex
        out.append(raw[(base + h.fileHeader.lowerBound)..<(base + h.fileHeader.upperBound)])
        if out.last != 0x0A { out.append(0x0A) }
        // Copy line by line: an empty line inside a hunk is a blank context
        // line printed by diff.suppressBlankEmpty and needs its space back.
        var start = base + h.body.lowerBound
        let end = base + h.body.upperBound
        while start < end {
            let nl = raw[start..<end].firstIndex(of: 0x0A) ?? end
            if nl == start {
                out.append(0x20)
            } else {
                out.append(raw[start..<nl])
            }
            out.append(0x0A)
            start = nl + 1
        }
        return out
    }

    /// The original bytes of a line (tabs and non-UTF-8 kept, trailing CR dropped), for copying.
    public func sourceText(ofLine index: Int) -> String {
        let line = lines[index]
        guard !line.source.isEmpty else { return line.text }
        var bytes = raw[(raw.startIndex + line.source.lowerBound)..<(raw.startIndex + line.source.upperBound)]
        if bytes.last == 0x0D { bytes = bytes.dropLast() }
        return Self.decode(bytes)
    }

    /// First and last line number of a hunk on the new side, for messages.
    public func newRange(ofHunk index: Int) -> ClosedRange<Int>? {
        let numbers = lines.lazy.filter { $0.hunk == index }.compactMap { $0.new ?? $0.old }
        guard let lo = numbers.min(), let hi = numbers.max() else { return nil }
        return lo...hi
    }
}

// MARK: Parsing

extension DiffDocument {
    /// Header lines that the view's own header already covers.
    private static let hiddenHeaderPrefixes = [
        "diff --git ", "diff --cc ", "diff --combined ", "index ", "--- ", "+++ ",
        "similarity index ", "dissimilarity index ", "rename from ", "rename to ",
        "copy from ", "copy to ", "new file mode ", "deleted file mode ",
    ]

    private static let plus = UInt8(ascii: "+"), minus = UInt8(ascii: "-"), space = UInt8(ascii: " ")
    private static let backslash = UInt8(ascii: "\\"), at = UInt8(ascii: "@")

    /// Text for display: UTF-8 when valid, otherwise Latin-1 (every byte maps
    /// to a character, so nothing is shown as U+FFFD and nothing is lost).
    public static func decode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        let s = String(decoding: bytes, as: UTF8.self)
        if s.utf8.count == bytes.count, s.utf8.elementsEqual(bytes) { return s }
        return String(bytes: Array(bytes), encoding: .isoLatin1) ?? s
    }

    public static func parse(_ text: String, maxLines: Int = 20_000) -> DiffDocument {
        parse(Data(text.utf8), maxLines: maxLines)
    }

    public static func parse(_ data: Data, maxLines: Int = 20_000) -> DiffDocument {
        var doc = DiffDocument()
        doc.raw = data
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            parse(buf.bindMemory(to: UInt8.self), into: &doc, maxLines: maxLines)
        }
        if doc.truncated {
            doc.lines.append(Line(kind: .meta, old: nil, new: nil,
                                  text: "Diff too long, showing the first \(maxLines) lines.", hunk: -1))
        }
        doc.pairLines()
        return doc
    }

    private static func parse(_ bytes: UnsafeBufferPointer<UInt8>, into doc: inout DiffDocument, maxLines: Int) {
        var oldNo = 0, newNo = 0
        var oldLeft = 0, newLeft = 0   // lines still expected in a unified hunk
        var signColumns = 1            // 2+ for combined diffs (conflicts)
        var inHunk = false
        var sectionStart = 0           // byte offset of the current "diff " line
        var headerRange = 0..<0        // file header of the current section

        func show(_ line: Line) {
            if doc.lines.count >= maxLines { doc.truncated = true; return }
            doc.lines.append(line)
        }

        let count = bytes.count
        var start = 0
        while start < count {
            var end = start
            while end < count, bytes[end] != 0x0A { end += 1 }
            let next = min(end + 1, count)
            defer { start = next }
            let line = UnsafeBufferPointer(rebasing: bytes[start..<end])
            let first = line.first

            // Hunk header: "@@ -a,b +c,d @@" (or "@@@ … @@@" for combined diffs).
            if first == at, line.count > 1, line[1] == at {
                if !inHunk { headerRange = sectionStart..<start }
                inHunk = true
                let ats = line.prefix { $0 == at }.count
                signColumns = max(1, ats - 1)
                let header = decode(line)
                let ranges = parseHunkRanges(Substring(header))
                (oldNo, newNo) = (ranges.oldStart, ranges.newStart)
                (oldLeft, newLeft) = (ranges.oldCount, ranges.newCount)
                doc.hunks.append(Hunk(header: header, oldStart: oldNo, newStart: newNo,
                                      fileHeader: headerRange, body: start..<next))
                show(Line(kind: .hunk, old: nil, new: nil, text: header, hunk: doc.hunks.count - 1))
                continue
            }

            if inHunk {
                let h = doc.hunks.count - 1
                // Unified hunks end when the counts from the header are used up;
                // combined diffs go by the sign columns.
                let isContent: Bool
                if first == backslash {
                    isContent = true
                } else if signColumns == 1 {
                    isContent = (oldLeft > 0 || newLeft > 0) && (first == nil || first == plus || first == minus || first == space)
                } else {
                    isContent = first == nil || first == plus || first == minus || first == space
                }
                if isContent {
                    doc.hunks[h].body = doc.hunks[h].body.lowerBound..<next
                    if first == backslash {
                        show(Line(kind: .meta, old: nil, new: nil, text: decode(line.dropFirst(min(2, line.count))), hunk: h))
                        continue
                    }
                    if first == nil && signColumns > 1 { continue }
                    let n = min(signColumns, line.count)
                    let signs = line.prefix(n)
                    let bodyBytes = UnsafeBufferPointer(rebasing: line[n...])
                    let body = displayText(Substring(decode(bodyBytes)))
                    let source = (start + n)..<end
                    doc.maxColumns = max(doc.maxColumns, body.utf16.count)
                    if signs.contains(plus) {
                        doc.added += 1
                        show(Line(kind: .added, old: nil, new: newNo, text: body, hunk: h, source: source))
                        newNo += 1; newLeft -= 1
                    } else if signs.contains(minus) {
                        doc.removed += 1
                        show(Line(kind: .removed, old: signColumns == 1 ? oldNo : nil, new: nil, text: body, hunk: h, source: source))
                        oldNo += 1; oldLeft -= 1
                    } else {
                        // A bare empty line is a blank context line (diff.suppressBlankEmpty).
                        doc.hunks[h].hasContext = true
                        show(Line(kind: .context, old: signColumns == 1 ? oldNo : nil, new: newNo, text: body, hunk: h, source: source))
                        oldNo += 1; newNo += 1; oldLeft -= 1; newLeft -= 1
                    }
                    continue
                }
                inHunk = false
            }

            // Outside a hunk: file header lines.
            let s = decode(line)
            if s.hasPrefix("diff ") {
                doc.sections += 1
                sectionStart = start
            }
            if s.isEmpty || hiddenHeaderPrefixes.contains(where: { s.hasPrefix($0) }) { continue }
            show(Line(kind: .meta, old: nil, new: nil, text: s, hunk: -1))
        }
        doc.maxLineNumber = max(oldNo, newNo)
    }

    /// "@@ -12,5 +12,7 @@ ..." -> (12, 12). Combined diffs have several "-" ranges; the first wins.
    public static func parseHunkHeader(_ line: Substring) -> (Int, Int) {
        let r = parseHunkRanges(line)
        return (r.oldStart, r.newStart)
    }

    /// Starts and line counts of a hunk header; a missing count means 1.
    public static func parseHunkRanges(_ line: Substring) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
        func range(_ part: Substring) -> (Int, Int)? {
            let nums = part.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let a = nums.first.flatMap({ Int($0) }) else { return nil }
            let b = nums.count > 1 ? Int(nums[1]) ?? 1 : 1
            return (a, b)
        }
        var old: (Int, Int)?, new = (0, 0)
        for part in line.split(separator: " ").dropFirst() {
            if part.hasPrefix("-"), old == nil, let r = range(part) { old = r }
            else if part.hasPrefix("+"), let r = range(part) { new = r; break }
        }
        return (old?.0 ?? 0, old?.1 ?? 0, new.0, new.1)
    }

    /// Drops a trailing CR and expands tabs to 4-column stops.
    public static func displayText(_ s: Substring) -> String {
        var s = s
        if s.utf8.last == 0x0D { s = Substring(s.utf8.dropLast()) }
        guard s.utf8.contains(0x09) else { return String(s) }
        var out = ""
        out.reserveCapacity(s.utf8.count + 8)
        var column = 0
        for ch in s {
            if ch == "\t" {
                let n = 4 - column % 4
                out.append(String(repeating: " ", count: n))
                column += n
            } else {
                out.append(ch)
                column += 1
            }
        }
        return out
    }

    /// Builds split rows and pairs each run of removed lines with the added
    /// lines that follow it, marking the changed span of each pair.
    private mutating func pairLines() {
        var removedRun: [Int] = [], addedRun: [Int] = []
        var leftNote: Int?, rightNote: Int?
        var lastKind = Kind.context
        var rows: [SplitRow] = []
        rows.reserveCapacity(lines.count)

        func flush() {
            let n = max(removedRun.count, addedRun.count)
            for k in 0..<n {
                let l = k < removedRun.count ? removedRun[k] : nil
                let r = k < addedRun.count ? addedRun[k] : nil
                if let l, let r, let (a, b) = Self.changedRanges(lines[l].text, lines[r].text) {
                    lines[l].change = a
                    lines[r].change = b
                }
                rows.append(SplitRow(kind: .code, left: l, right: r))
            }
            if leftNote != nil || rightNote != nil {
                rows.append(SplitRow(kind: .note, left: leftNote, right: rightNote))
            }
            removedRun.removeAll(keepingCapacity: true)
            addedRun.removeAll(keepingCapacity: true)
            leftNote = nil
            rightNote = nil
        }

        for (i, line) in lines.enumerated() {
            switch line.kind {
            case .removed:
                if !addedRun.isEmpty || rightNote != nil { flush() }
                removedRun.append(i)
            case .added:
                addedRun.append(i)
            case .meta where line.hunk >= 0:
                // "No newline at end of file" belongs to the side of the line above it
                // and shouldn't break a run.
                switch lastKind {
                case .removed: leftNote = i
                case .added: rightNote = i
                default: leftNote = i; rightNote = i
                }
            case .context:
                flush()
                rows.append(SplitRow(kind: .code, left: i, right: i))
            case .hunk:
                flush()
                rows.append(SplitRow(kind: .hunk, left: i, right: nil))
            case .meta:
                flush()
                rows.append(SplitRow(kind: .meta, left: i, right: nil))
            }
            if line.kind != .meta { lastKind = line.kind }
        }
        flush()
        splitRows = rows
    }

    /// Changed span of two similar lines: everything between the common prefix
    /// and the common suffix, widened to whole characters (emoji, combining
    /// marks). Nil when the lines share nothing but whitespace.
    public static func changedRanges(_ a: String, _ b: String) -> (NSRange, NSRange)? {
        let x = Array(a.utf16), y = Array(b.utf16)
        var p = 0
        while p < x.count, p < y.count, x[p] == y[p] { p += 1 }
        var s = 0
        while s < x.count - p, s < y.count - p, x[x.count - 1 - s] == y[y.count - 1 - s] { s += 1 }

        // Snap to composed character boundaries so a highlight never splits a
        // surrogate pair or separates a letter from its accent.
        let na = a as NSString, nb = b as NSString
        func snapStart(_ str: NSString, _ i: Int) -> Int {
            i > 0 && i < str.length ? str.rangeOfComposedCharacterSequence(at: i).location : i
        }
        func snapEnd(_ str: NSString, _ e: Int) -> Int {
            guard e > 0, e < str.length else { return e }
            let r = str.rangeOfComposedCharacterSequence(at: e)
            return r.location == e ? e : NSMaxRange(r)
        }
        for _ in 0..<4 {
            let p2 = min(snapStart(na, p), snapStart(nb, p))
            let ea = snapEnd(na, max(p2, x.count - s)), eb = snapEnd(nb, max(p2, y.count - s))
            let s2 = min(x.count - ea, y.count - eb)
            if p2 == p && s2 == s { break }
            p = p2; s = s2
        }

        let common = x[0..<p] + x[(x.count - s)...]
        guard common.contains(where: { $0 != 0x20 && $0 != 0x09 }) else { return nil }
        let ra = NSRange(location: p, length: x.count - p - s)
        let rb = NSRange(location: p, length: y.count - p - s)
        if ra.length == 0 && rb.length == 0 { return nil }
        return (ra, rb)
    }
}
