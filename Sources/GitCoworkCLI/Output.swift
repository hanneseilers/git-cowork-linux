import Foundation
import GitCoworkCore

/// Text and JSON output. JSON is for agents and scripts: stable keys,
/// ISO-8601 dates, one object or array per command.
enum Output {
    static func json(_ value: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    }

    static func date(_ d: Date) -> String { CoworkCodec.string(d) }

    static func task(_ t: CoworkTask, comments: [CoworkComment] = []) -> [String: Any] {
        var o: [String: Any] = [
            "id": t.id, "title": t.title, "status": t.status.rawValue, "labels": t.labels,
            "author": t.author, "created": date(t.created), "updated": date(t.updated), "body": t.body,
        ]
        o["assignee"] = t.assignee ?? NSNull()
        o["branch"] = t.branch ?? NSNull()
        if !comments.isEmpty { o["comments"] = comments.map(comment) }
        return o
    }

    static func review(_ r: ReviewRequest, comments: [CoworkComment] = []) -> [String: Any] {
        var o: [String: Any] = [
            "id": r.id, "title": r.title, "branch": r.branch, "base": r.base, "requester": r.requester,
            "state": r.status.rawValue, "overall": r.overall.rawValue,
            "reviewers": Dictionary(uniqueKeysWithValues: r.reviewers.map { ($0.key, $0.value.rawValue) }),
            "created": date(r.created), "updated": date(r.updated), "body": r.body,
        ]
        o["task"] = r.taskID ?? NSNull()
        if !comments.isEmpty { o["comments"] = comments.map(comment) }
        return o
    }

    static func comment(_ c: CoworkComment) -> [String: Any] {
        ["id": c.id, "author": c.author, "name": c.authorName, "created": date(c.created), "body": c.body]
    }

    static func inbox(_ i: InboxItem) -> [String: Any] {
        ["id": i.id, "kind": i.kind.rawValue, "actor": i.actor, "date": date(i.date),
         "title": i.title, "detail": i.detail, "target": i.target]
    }

    // MARK: Text

    static let statusWords: [TaskStatus: String] = [
        .backlog: "backlog", .todo: "todo", .doing: "doing", .review: "review", .done: "done",
    ]

    static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }

    static func taskLine(_ t: CoworkTask) -> String {
        var line = "\(pad(t.id, 8))  \(pad(statusWords[t.status] ?? "", 7))  \(pad(who(t.assignee), 14))  \(t.title)"
        if !t.labels.isEmpty { line += "  [" + t.labels.joined(separator: ", ") + "]" }
        if let b = t.branch { line += "  (\(b))" }
        return line
    }

    static func reviewLine(_ r: ReviewRequest) -> String {
        let done = r.reviewers.values.filter { $0 == .approved }.count
        return "\(pad(r.id, 7))  \(pad(r.status == .closed ? "closed" : r.overall.rawValue, 17))  \(r.branch) → \(r.base)  \(done)/\(r.reviewers.count)  \(r.title)"
    }

    /// "anna" for anna@x.com, "-" for nobody.
    static func who(_ email: String?) -> String {
        guard let email, !email.isEmpty else { return "-" }
        return String(email.split(separator: "@").first ?? Substring(email))
    }

    static func showTask(_ t: CoworkTask, comments: [CoworkComment]) {
        print("\(t.id)  \(t.title)")
        print("status:   \(statusWords[t.status] ?? "")")
        print("assignee: \(t.assignee ?? "-")")
        if !t.labels.isEmpty { print("labels:   \(t.labels.joined(separator: ", "))") }
        print("branch:   \(t.branch ?? "-")")
        print("created:  \(date(t.created)) by \(t.author)")
        if !t.body.isEmpty { print("\n\(t.body)") }
        showComments(comments)
    }

    static func showReview(_ r: ReviewRequest, comments: [CoworkComment]) {
        print("\(r.id)  \(r.title)")
        print("branch:   \(r.branch) → \(r.base)")
        print("state:    \(r.status.rawValue), \(r.overall.rawValue)")
        print("by:       \(r.requester)")
        for (who, v) in r.reviewers.sorted(by: { $0.key < $1.key }) { print("reviewer: \(who)  \(v.rawValue)") }
        if let t = r.taskID { print("task:     \(t)") }
        if !r.body.isEmpty { print("\n\(r.body)") }
        showComments(comments)
    }

    private static func showComments(_ comments: [CoworkComment]) {
        guard !comments.isEmpty else { return }
        print("\ncomments:")
        for c in comments {
            print("- \(c.authorName) (\(date(c.created))):")
            for line in c.body.split(separator: "\n", omittingEmptySubsequences: false) { print("  \(line)") }
        }
    }
}
