import GitCoworkCore
import SwiftUI

/// A "Co-authored-by: Name <email>" trailer.
struct CoAuthor: Hashable {
    let name: String
    let email: String
}

enum CommitText {
    /// Splits the body into the text to show and its Co-authored-by trailers.
    static func split(body: String) -> (text: String, coAuthors: [CoAuthor]) {
        var lines: [Substring] = []
        var authors: [CoAuthor] = []
        let prefix = "co-authored-by:"
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix(prefix) {
                let value = t.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                if let lt = value.firstIndex(of: "<"), let gt = value.lastIndex(of: ">"), lt < gt {
                    let name = value[..<lt].trimmingCharacters(in: .whitespaces)
                    let email = String(value[value.index(after: lt)..<gt])
                    authors.append(CoAuthor(name: name.isEmpty ? email : name, email: email))
                } else if !value.isEmpty {
                    authors.append(CoAuthor(name: value, email: value))
                }
                continue
            }
            lines.append(line)
        }
        let text = reflow(lines).trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        return (text, authors.filter { seen.insert($0.email.lowercased()).inserted })
    }

    /// Joins lines that were hard-wrapped at ~72 columns so the text can wrap
    /// to the panel width. Blank lines, list items, indented lines, trailers
    /// ("Signed-off-by: …"), tables, headings, quotes and fenced code stay as they are.
    static func reflow(_ lines: [Substring]) -> String {
        // A final paragraph made only of trailers is kept verbatim.
        var trailerStart = lines.count
        var i = lines.count - 1
        while i >= 0, lines[i].allSatisfy(\.isWhitespace) { i -= 1 }
        var j = i
        while j >= 0, !lines[j].allSatisfy(\.isWhitespace) { j -= 1 }
        if i >= 0, (j + 1...i).allSatisfy({ isTrailer(lines[$0]) }) { trailerStart = j + 1 }

        var out = ""
        var previousJoinable = false
        var inFence = false
        for (n, line) in lines.enumerated() {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            let isBlank = line.allSatisfy(\.isWhitespace)
            let first = line.first
            let isIndented = first == " " || first == "\t"
            let isListItem = line.range(of: #"^\s*([-*•+]|\d+[.)])\s"#, options: .regularExpression) != nil
            let hard = isFence || inFence || n >= trailerStart || hardBreak(line)
            if previousJoinable && !isBlank && !isIndented && !isListItem && !hard {
                out += " " + line
            } else {
                if n > 0 { out += "\n" }
                out += line
            }
            if isFence { inFence.toggle() }
            previousJoinable = !isBlank && !isIndented && !line.hasSuffix(":") && !hard && !inFence
        }
        return out
    }

    /// "Signed-off-by: Alice <a@x>", "Fixes: #12".
    static func isTrailer(_ line: Substring) -> Bool {
        line.range(of: #"^[A-Za-z][A-Za-z0-9-]*: \S"#, options: .regularExpression) != nil
    }

    /// Lines that are structure, not prose: never joined with a neighbour.
    private static func hardBreak(_ line: Substring) -> Bool {
        let t = line.drop { $0 == " " || $0 == "\t" }
        if t.hasPrefix("|") || t.hasPrefix("#") || t.hasPrefix(">") { return true }
        return isTrailer(line)
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("ddMMyyyy")
        return f
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jjmm")
        return f
    }()

    /// "06.11.2026 @ 14:01" (order and separators follow the user's locale).
    static func stamp(_ date: Date) -> String {
        "\(day.string(from: date)) @ \(time.string(from: date))"
    }
}

/// Rounded card holding the subject in large type and the body below it.
/// As tall as its content, scrolling when the message is very long.
struct MessageCard: View {
    let subject: String
    let text: String
    @State private var height: CGFloat = 40

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(subject)
                    .font(InspectorStyle.subjectFont)
                    .fixedSize(horizontal: false, vertical: true)
                if !text.isEmpty {
                    Text(text)
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Metrics.cardPadding)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { height = g.size.height }
                    .onChange(of: g.size.height) { _, h in height = h }
            })
        }
        .scrollIndicators(.automatic)
        .frame(height: min(height, InspectorStyle.messageMaxHeight))
        .background(InspectorStyle.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(InspectorStyle.cardBorder))
    }
}

/// Big avatar, name, "authored 06.11.2026 @ 14:01", committer if different,
/// and parent links on the right.
struct AuthorBlock: View {
    let detail: CommitDetail
    let reveal: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Avatar(name: detail.authorName, email: detail.authorEmail, size: InspectorStyle.avatarSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(detail.authorName)
                    .font(Theme.Font.body.weight(.semibold))
                    .lineLimit(1)
                Text("authored \(CommitText.stamp(detail.authorDate))")
                    .font(Theme.Font.small)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if committerDiffers {
                    Text("committed by \(detail.committerName), \(CommitText.stamp(detail.committerDate))")
                        .font(Theme.Font.small)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            .help(detail.authorEmail)
            Spacer(minLength: Theme.Space.s)
            if !detail.parents.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(detail.parents.count > 1 ? "parents:" : "parent:").foregroundStyle(.secondary)
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(detail.parents, id: \.self) { p in
                            Button(String(p.prefix(7))) { reveal(p) }
                                .buttonStyle(.link)
                                .font(Theme.Font.monoSmall)
                                .help("Show parent \(p)")
                        }
                    }
                }
                .font(Theme.Font.small)
            }
        }
    }

    private var committerDiffers: Bool {
        detail.committerEmail != detail.authorEmail || detail.committerName != detail.authorName
    }
}

/// Row of small avatars with names for Co-authored-by trailers.
struct CoAuthorList: View {
    let authors: [CoAuthor]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("CO-AUTHORS")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
            FlowRow(spacing: Theme.Space.m) {
                ForEach(authors, id: \.self) { a in
                    HStack(spacing: Theme.Space.s) {
                        Avatar(name: a.name, email: a.email, size: InspectorStyle.coAuthorAvatarSize)
                        Text(a.name)
                            .font(Theme.Font.small)
                            .lineLimit(1)
                    }
                    .help(a.email)
                }
            }
        }
    }
}
