import Foundation
import GitCoworkCore

/// One commit's worth of changes to the cowork ref. `build` gets the stored
/// content of `paths` at the tip it's written on and returns the changes
/// (path -> new content; nil removes). See `CoworkRepo.commit`.
public struct CoworkWrite {
    public let paths: [String]
    public let message: String
    public let build: ([String: String]) -> [String: String?]

    public init(paths: [String], message: String, build: @escaping ([String: String]) -> [String: String?]) {
        self.paths = paths
        self.message = message
        self.build = build
    }
}

/// The edits the app and the `git-cowork` tool make, in one place, so both
/// write task, review and comment files exactly the same way.
public enum CoworkEdit {
    /// A new task at the top of its column.
    public static func newTask(title: String, status: TaskStatus = .backlog, assignee: String? = nil,
                               labels: [String] = [], body: String = "", author: String,
                               in snapshot: CoworkSnapshot, now: Date = Date()) -> (CoworkTask, CoworkWrite) {
        let id = CoworkCodec.newID(prefix: "CW-", existing: Set(snapshot.tasks.map(\.id)))
        let rank = (snapshot.tasks.filter { $0.status == status }.compactMap(\.rank).min() ?? 0) - 1
        let t = CoworkTask(id: id, title: title, status: status, assignee: assignee, labels: labels,
                           author: author, created: now, updated: now, body: body, rank: rank)
        let text = CoworkCodec.encode(t)
        return (t, CoworkWrite(paths: [], message: "Create \(id): \(title)") { _ in [t.path: text] })
    }

    /// Changes tasks as stored at the tip, so fields changed meanwhile by
    /// someone else are kept. Deleted tasks stay deleted; unchanged ones aren't written.
    public static func updateTasks(_ edits: [String: (inout CoworkTask) -> Void], message: String,
                                   now: Date = Date()) -> CoworkWrite {
        CoworkWrite(paths: edits.keys.map(CoworkPaths.task), message: message) { current in
            var changes: [String: String?] = [:]
            for (id, change) in edits {
                let path = CoworkPaths.task(id)
                guard let text = current[path], var t = CoworkCodec.decodeTask(text, id: id) else { continue }
                let before = t
                change(&t)
                guard t != before else { continue }
                t.updated = now
                changes[path] = CoworkCodec.encode(t)
            }
            return changes
        }
    }

    public static func deleteTask(_ t: CoworkTask, comments: [CoworkComment]) -> CoworkWrite {
        var changes: [String: String?] = [t.path: nil]
        for c in comments { changes[c.path] = .some(nil) }
        return CoworkWrite(paths: [], message: "Delete \(t.id)") { _ in changes }
    }

    /// `parent` is "tasks/CW-a3f9" or "reviews/R-7k2p".
    public static func comment(on parent: String, body: String, by me: TeamMember,
                               now: Date = Date()) -> (CoworkComment, CoworkWrite) {
        let c = CoworkComment(id: CoworkCodec.newCommentID(date: now), parent: parent, author: me.email,
                              authorName: me.name, created: now, body: body)
        let text = CoworkCodec.encode(c)
        return (c, CoworkWrite(paths: [], message: "Comment on \(parent)") { _ in [c.path: text] })
    }

    /// A review request; a linked task moves to In Review.
    public static func requestReview(branch: String, base: String, title: String, reviewers: [String],
                                     body: String, taskID: String?, requester: String,
                                     in snapshot: CoworkSnapshot, now: Date = Date()) -> (ReviewRequest, CoworkWrite) {
        let id = CoworkCodec.newID(prefix: "R-", existing: Set(snapshot.reviews.map(\.id)))
        var rv: [String: ReviewVerdict] = [:]
        for r in reviewers { rv[r.lowercased()] = .requested }
        let r = ReviewRequest(id: id, title: title, branch: branch, base: base, requester: requester,
                              reviewers: rv, taskID: taskID, created: now, updated: now, body: body)
        let text = CoworkCodec.encode(r)
        let paths = taskID.map { [CoworkPaths.task($0)] } ?? []
        return (r, CoworkWrite(paths: paths, message: "Request review of \(branch)") { current in
            var changes: [String: String?] = [r.path: text]
            if let taskID, let stored = current[CoworkPaths.task(taskID)],
               var t = CoworkCodec.decodeTask(stored, id: taskID), t.status != .review, t.status != .done {
                t.status = .review
                t.updated = now
                changes[t.path] = CoworkCodec.encode(t)
            }
            return changes
        })
    }

    /// Changes one review as stored at the tip. `extra` is written alongside (e.g. a comment).
    public static func updateReview(_ id: String, extra: [String: String?] = [:], message: String? = nil,
                                    now: Date = Date(), _ change: @escaping (inout ReviewRequest) -> Void) -> CoworkWrite {
        let path = CoworkPaths.review(id)
        return CoworkWrite(paths: [path], message: message ?? "Update review \(id)") { current in
            guard let text = current[path], var r = CoworkCodec.decodeReview(text, id: id) else { return [:] }
            let before = r
            change(&r)
            var changes = extra
            if r != before {
                r.updated = now
                changes[path] = CoworkCodec.encode(r)
            }
            return changes
        }
    }

    /// My verdict on a review, with an optional comment.
    public static func verdict(_ verdict: ReviewVerdict, on review: ReviewRequest, comment: String,
                               by me: TeamMember, now: Date = Date()) -> CoworkWrite {
        var extra: [String: String?] = [:]
        if !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            extra = Self.comment(on: review.commentParent, body: comment, by: me, now: now).1.build([:])
        }
        let myID = me.id, myEmail = me.email
        return updateReview(review.id, extra: extra, message: "\(verdict.rawValue) \(review.branch)", now: now) { r in
            // Reuse the key the requester wrote, whatever its case.
            let key = r.reviewers.keys.first { $0.lowercased() == myID } ?? myEmail.lowercased()
            r.reviewers[key] = verdict
        }
    }

    /// The team list, merged with whatever is stored at the tip, so members
    /// someone else added or removed meanwhile stay that way.
    public static func saveTeam(_ members: [TeamMember], previous: [TeamMember]) -> CoworkWrite {
        let base = CoworkCodec.encodeTeam(previous)
        let ours = CoworkCodec.encodeTeam(members)
        return CoworkWrite(paths: [CoworkPaths.team], message: "Update team") { current in
            let merged = CoworkMerge.mergeFile(path: CoworkPaths.team, base: base, ours: ours,
                                               theirs: current[CoworkPaths.team] ?? base)
            return [CoworkPaths.team: merged ?? ours]
        }
    }
}

extension CoworkRepo {
    /// Writes one edit as a commit on the local ref. Returns false if nothing changed.
    @discardableResult
    public func apply(_ w: CoworkWrite) async throws -> Bool {
        try await commit(reading: w.paths, message: w.message, w.build)
    }
}
