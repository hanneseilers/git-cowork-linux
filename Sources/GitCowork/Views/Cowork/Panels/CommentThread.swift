import GitCoworkCore
import SwiftUI

// Comment threads on tasks and reviews, plus @mention highlighting and completion.

/// Completion of the "@par" being typed at the end of a text.
enum MentionCompletion {
    /// The handle prefix after a trailing "@" (may be empty), or nil when the
    /// text doesn't end in a mention being typed.
    static func pendingQuery(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex {
            let before = text[text.index(before: at)]
            guard before.isWhitespace || before == "(" else { return nil }
        }
        let query = text[text.index(after: at)...]
        guard query.count <= 32, query.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        return String(query)
    }

    /// People whose handle, email or name starts with the query.
    static func candidates(_ query: String, people: [TeamMember], limit: Int = 5) -> [TeamMember] {
        let q = query.lowercased()
        let matches = people.filter { p in
            q.isEmpty
                || p.mentionHandle.lowercased().hasPrefix(q)
                || p.email.lowercased().hasPrefix(q)
                || p.name.lowercased().split(separator: " ").contains { $0.hasPrefix(q) }
        }
        // An exact, complete handle needs no suggestion.
        if matches.count == 1, matches[0].mentionHandle.lowercased() == q { return [] }
        return Array(matches.prefix(limit))
    }

    /// Replaces the trailing "@par" with "@handle ".
    static func complete(_ text: String, with person: TeamMember) -> String {
        guard let at = text.lastIndex(of: "@") else { return text }
        return String(text[..<at]) + "@" + person.mentionHandle + " "
    }
}

/// Body text with @mentions of known people drawn in the accent color.
struct MentionText: View {
    let text: String
    let handles: Set<String>   // lowercased

    var body: some View {
        Text(attributed)
            .font(Theme.Font.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        let chars = Array(text)
        var i = 0
        var plain = ""
        func flush() {
            if !plain.isEmpty { out += AttributedString(plain); plain = "" }
        }
        while i < chars.count {
            let startsMention = chars[i] == "@" && (i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "." || chars[i - 1] == "_"))
            if startsMention {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "." || chars[j] == "_" || chars[j] == "-" { j += 1 }
                var end = j
                while end > i + 1, chars[end - 1] == "." || chars[end - 1] == "-" { end -= 1 }
                let handle = String(chars[(i + 1)..<end])
                if !handle.isEmpty, handles.contains(handle.lowercased()) {
                    flush()
                    var m = AttributedString("@" + handle)
                    m.foregroundColor = .accentColor
                    m.font = Theme.Font.body.weight(.semibold)
                    out += m
                    plain = String(chars[end..<j])
                    i = j
                    continue
                }
            }
            plain.append(chars[i])
            i += 1
        }
        flush()
        return out
    }
}

extension CoworkStore {
    /// Lowercased handles that resolve to a person, for highlighting.
    var mentionHandles: Set<String> {
        Set(people.map { $0.mentionHandle.lowercased() })
    }
}

/// Small list of people to complete an @mention with.
struct MentionSuggestions: View {
    let people: [TeamMember]
    let pick: (TeamMember) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(people) { p in
                Button { pick(p) } label: {
                    HStack(spacing: Theme.Space.m) {
                        PersonAvatar(person: p, size: 16)
                        Text(p.displayName).lineLimit(1)
                        Text("@" + p.mentionHandle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(Theme.Font.small)
                    .padding(.horizontal, Theme.Space.m)
                    .frame(height: Theme.Metrics.buttonHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverRowStyle())
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// Plain button with a light highlight while hovered or pressed.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(pressed: configuration.isPressed) { configuration.label }
    }

    private struct HoverRow<Label: View>: View {
        let pressed: Bool
        @ViewBuilder var label: Label
        @State private var hovering = false

        var body: some View {
            label
                .background(Color.primary.opacity(pressed ? 0.10 : hovering ? 0.05 : 0))
                .onHover { hovering = $0 }
        }
    }
}

/// Comments on a task or review, oldest first.
struct CommentList: View {
    let model: RepoModel
    let parent: String

    var body: some View {
        let comments = model.cowork.comments(on: parent)
        let handles = model.cowork.mentionHandles
        VStack(alignment: .leading, spacing: Theme.Metrics.panelPadding) {
            CoworkSectionTitle("Comments", count: comments.count)
            if comments.isEmpty {
                Text("No comments yet.")
                    .font(Theme.Font.small)
                    .foregroundStyle(.secondary)
            }
            ForEach(comments) { c in
                CommentRow(comment: c, person: model.cowork.person(c.author), handles: handles)
            }
        }
    }
}

private struct CommentRow: View {
    let comment: CoworkComment
    let person: TeamMember?
    let handles: Set<String>

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            PersonAvatar(person: person, size: 22)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(person?.displayName ?? comment.authorName)
                        .font(Theme.Font.body.weight(.semibold))
                        .lineLimit(1)
                    Text(Formatters.relative(comment.created))
                        .font(Theme.Font.small)
                        .foregroundStyle(.secondary)
                        .help(Formatters.full(comment.created))
                    Spacer(minLength: 0)
                }
                MentionText(text: comment.body, handles: handles)
            }
        }
    }
}

/// Text box at the bottom of a panel for adding a comment. ⌘↩ sends.
struct CommentComposer: View {
    let model: RepoModel
    let parent: String
    var placeholder = "Write a comment… Use @ to mention someone."

    @State private var sending = false
    @FocusState private var focused: Bool

    /// Kept in the store per parent, so switching to another task and back
    /// doesn't lose an unsent comment.
    private var draft: String {
        get { model.cowork.drafts["comment:" + parent] ?? "" }
        nonmutating set { model.cowork.drafts["comment:" + parent] = newValue.isEmpty ? nil : newValue }
    }
    private var draftBinding: Binding<String> { Binding(get: { draft }, set: { draft = $0 }) }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let q = MentionCompletion.pendingQuery(in: draft) {
                let people = MentionCompletion.candidates(q, people: model.cowork.people)
                if !people.isEmpty {
                    MentionSuggestions(people: people) { draft = MentionCompletion.complete(draft, with: $0) }
                }
            }
            PlaceholderEditor(text: draftBinding, placeholder: placeholder, minHeight: 56, maxHeight: 56, focused: focused)
                .focused($focused)
            HStack(spacing: Theme.Space.m) {
                Text("⌘↩ to send")
                    .font(Theme.Font.small)
                    .foregroundStyle(.tertiary)
                Spacer()
                if sending { ProgressView().controlSize(.small) }
                Button("Comment") { send() }
                    .buttonStyle(ActionButtonStyle.primary())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(trimmed.isEmpty || sending)
            }
        }
        .padding(Theme.Metrics.panelPadding)
    }

    private func send() {
        let body = trimmed
        guard !body.isEmpty, !sending else { return }
        sending = true
        let saved = draft
        let parent = parent
        draft = ""
        Task {
            // Failed to write: put the text back so nothing is lost.
            if await model.cowork.addComment(on: parent, body: body) == false,
               (model.cowork.drafts["comment:" + parent] ?? "").isEmpty {
                model.cowork.drafts["comment:" + parent] = saved
            }
            sending = false
        }
    }
}
