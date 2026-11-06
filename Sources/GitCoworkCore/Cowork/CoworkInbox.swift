import Foundation

/// Something a teammate did that concerns me.
public struct InboxItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case assigned            // a task was assigned to me
        case reviewRequested     // someone asked me to review
        case reviewVerdict       // a reviewer approved / asked for changes on my request
        case mention             // @me in a task or comment
        case comment             // a comment on my task or review
    }

    /// Stable key; also used to remember what was already seen.
    public let id: String
    public let kind: Kind
    public let actor: String          // email of who did it
    public let date: Date
    public let title: String          // "Anna assigned you CW-a3f9"
    public let detail: String         // task title / comment excerpt
    /// "tasks/CW-a3f9" or "reviews/R-7k2p"
    public let target: String
}

public enum CoworkInbox {
    /// Items for `me`, newest first. Things I did myself are never included.
    public static func items(for me: String, in snap: CoworkSnapshot, knownEmails: [String],
                             names: [String: String] = [:]) -> [InboxItem] {
        let me = me.lowercased()
        func name(_ email: String) -> String {
            names[email.lowercased()] ?? snap.team.first { $0.id == email.lowercased() }?.name
                ?? String(email.split(separator: "@").first ?? Substring(email))
        }
        func mentionsMe(_ text: String) -> Bool {
            Mentions.emails(in: text, team: snap.team, knownEmails: knownEmails + [me]).contains(me)
        }
        func excerpt(_ s: String) -> String {
            let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.count > 120 ? String(line.prefix(117)) + "…" : line
        }

        var out: [InboxItem] = []
        var tasksByParent: [String: CoworkTask] = [:]
        var reviewsByParent: [String: ReviewRequest] = [:]

        for t in snap.tasks {
            tasksByParent[t.commentParent] = t
            if t.assignee?.lowercased() == me, t.author.lowercased() != me {
                out.append(InboxItem(id: "assigned:\(t.id)", kind: .assigned, actor: t.author, date: t.created,
                                     title: "\(name(t.author)) assigned you \(t.id)", detail: t.title, target: t.commentParent))
            }
            if t.author.lowercased() != me, mentionsMe(t.body) {
                out.append(InboxItem(id: "mention:\(t.path)", kind: .mention, actor: t.author, date: t.created,
                                     title: "\(name(t.author)) mentioned you in \(t.id)", detail: t.title, target: t.commentParent))
            }
        }

        for r in snap.reviews {
            reviewsByParent[r.commentParent] = r
            if r.status == .open, r.reviewers.keys.contains(where: { $0.lowercased() == me }), r.requester.lowercased() != me {
                out.append(InboxItem(id: "review:\(r.id)", kind: .reviewRequested, actor: r.requester, date: r.created,
                                     title: "\(name(r.requester)) asked you to review \(r.branch)", detail: r.title, target: r.commentParent))
            }
            if r.requester.lowercased() == me {
                for (reviewer, verdict) in r.reviewers where reviewer.lowercased() != me && (verdict == .approved || verdict == .changesRequested) {
                    let what = verdict == .approved ? "approved" : "requested changes on"
                    out.append(InboxItem(id: "verdict:\(r.id):\(reviewer):\(verdict.rawValue)", kind: .reviewVerdict, actor: reviewer,
                                         date: r.updated, title: "\(name(reviewer)) \(what) \(r.branch)", detail: r.title, target: r.commentParent))
                }
            }
        }

        for (parent, comments) in snap.comments {
            let ownerTask = tasksByParent[parent]
            let ownerReview = reviewsByParent[parent]
            let owner = (ownerTask?.assignee ?? ownerTask?.author ?? ownerReview?.requester)?.lowercased()
            let label = ownerTask?.id ?? ownerReview?.branch ?? parent
            for c in comments where c.author.lowercased() != me {
                if mentionsMe(c.body) {
                    out.append(InboxItem(id: "mention:\(c.path)", kind: .mention, actor: c.author, date: c.created,
                                         title: "\(name(c.author)) mentioned you on \(label)", detail: excerpt(c.body), target: parent))
                } else if owner == me {
                    out.append(InboxItem(id: "comment:\(c.path)", kind: .comment, actor: c.author, date: c.created,
                                         title: "\(name(c.author)) commented on \(label)", detail: excerpt(c.body), target: parent))
                }
            }
        }

        return out.sorted { $0.date > $1.date }
    }
}
