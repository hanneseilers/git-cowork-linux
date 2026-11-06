import Foundation

/// Shared team data stored in the repo itself, on the ref `refs/cowork/main`:
///
///     team.md                                 members (optional)
///     tasks/CW-a3f9.md                        one file per task
///     tasks/CW-a3f9/comments/<stamp>-<rnd>.md one file per comment
///     reviews/R-7k2p.md                       one file per review request
///     reviews/R-7k2p/comments/<stamp>-<rnd>.md
///
/// One file per thing and random ids mean two people rarely touch the same
/// file; when they do, `CoworkMerge` merges field by field.
public enum CoworkPaths {
    public static let ref = "refs/cowork/main"
    public static func remoteRef(_ remote: String) -> String { "refs/cowork/remotes/\(remote)/main" }

    public static func task(_ id: String) -> String { "tasks/\(id).md" }
    public static func review(_ id: String) -> String { "reviews/\(id).md" }
    public static let team = "team.md"

    /// "tasks/CW-a3f9" or "reviews/R-7k2p": the thing a comment belongs to.
    public static func comment(on parent: String, id: String) -> String { "\(parent)/comments/\(id).md" }
}

public enum TaskStatus: String, CaseIterable, Sendable, Hashable {
    case backlog, todo, doing, review, done

    public var title: String {
        switch self {
        case .backlog: "Backlog"
        case .todo: "To Do"
        case .doing: "In Progress"
        case .review: "In Review"
        case .done: "Done"
        }
    }
}

public struct CoworkTask: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var status: TaskStatus
    public var assignee: String?        // email
    public var labels: [String]
    public var branch: String?
    public var author: String           // email of the creator
    public var created: Date
    public var updated: Date
    public var body: String
    /// Order inside a board column; lower first. Empty means "by update time".
    public var rank: Double?

    public init(id: String, title: String, status: TaskStatus = .backlog, assignee: String? = nil,
                labels: [String] = [], branch: String? = nil, author: String, created: Date,
                updated: Date, body: String = "", rank: Double? = nil) {
        self.id = id; self.title = title; self.status = status; self.assignee = assignee
        self.labels = labels; self.branch = branch; self.author = author
        self.created = created; self.updated = updated; self.body = body; self.rank = rank
    }

    public var path: String { CoworkPaths.task(id) }
    public var commentParent: String { "tasks/\(id)" }
}

public enum ReviewVerdict: String, CaseIterable, Sendable, Hashable {
    case requested
    case approved
    case changesRequested = "changes-requested"
    case commented
}

public enum ReviewStatus: String, Sendable, Hashable {
    case open, closed
}

public struct ReviewRequest: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var branch: String
    public var base: String
    public var requester: String        // email
    /// reviewer email -> verdict
    public var reviewers: [String: ReviewVerdict]
    public var status: ReviewStatus
    public var taskID: String?
    public var created: Date
    public var updated: Date
    public var body: String

    public init(id: String, title: String, branch: String, base: String, requester: String,
                reviewers: [String: ReviewVerdict], status: ReviewStatus = .open, taskID: String? = nil,
                created: Date, updated: Date, body: String = "") {
        self.id = id; self.title = title; self.branch = branch; self.base = base
        self.requester = requester; self.reviewers = reviewers; self.status = status
        self.taskID = taskID; self.created = created; self.updated = updated; self.body = body
    }

    public var path: String { CoworkPaths.review(id) }
    public var commentParent: String { "reviews/\(id)" }

    /// Approved by everyone asked / someone wants changes / still waiting.
    public var overall: ReviewVerdict {
        let v = Array(reviewers.values)
        if v.contains(.changesRequested) { return .changesRequested }
        if !v.isEmpty && v.allSatisfy({ $0 == .approved }) { return .approved }
        return .requested
    }
}

public struct CoworkComment: Identifiable, Hashable, Sendable {
    public var id: String               // file name without .md
    public var parent: String           // "tasks/CW-a3f9"
    public var author: String           // email
    public var authorName: String
    public var created: Date
    public var body: String

    public init(id: String, parent: String, author: String, authorName: String, created: Date, body: String) {
        self.id = id; self.parent = parent; self.author = author
        self.authorName = authorName; self.created = created; self.body = body
    }

    public var path: String { CoworkPaths.comment(on: parent, id: id) }
}

public struct TeamMember: Identifiable, Hashable, Sendable {
    public var id: String { email.lowercased() }
    public var handle: String
    public var name: String
    public var email: String

    public init(handle: String, name: String, email: String) {
        self.handle = handle; self.name = name; self.email = email
    }
}

/// Everything on the cowork ref, decoded.
public struct CoworkSnapshot: Sendable {
    public var tasks: [CoworkTask] = []
    public var reviews: [ReviewRequest] = []
    public var comments: [String: [CoworkComment]] = [:]   // parent -> comments, oldest first
    public var team: [TeamMember] = []

    public init() {}
}
