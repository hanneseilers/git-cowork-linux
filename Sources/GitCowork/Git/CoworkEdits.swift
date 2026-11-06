import Foundation
import GitCoworkCore

/// Creating and changing tasks, reviews, comments and the team. Each edit is
/// one commit on refs/cowork/main (see `write`).
extension CoworkStore {
    @discardableResult
    func createTask(title: String, status: TaskStatus = .backlog, assignee: String? = nil,
                    labels: [String] = [], body: String = "") async -> CoworkTask? {
        let now = Date()
        let id = CoworkCodec.newID(prefix: "CW-", existing: Set(snapshot.tasks.map(\.id)))
        let rank = (snapshot.tasks.filter { $0.status == status }.compactMap(\.rank).min() ?? 0) - 1
        let t = CoworkTask(id: id, title: title, status: status, assignee: assignee, labels: labels,
                           author: me.email, created: now, updated: now, body: body, rank: rank)
        let ok = await apply([t.path: CoworkCodec.encode(t)], message: "Create \(id): \(title)")
        return ok ? t : nil
    }

    /// Changes one task. `change` runs on the task as stored at the tip the
    /// commit is built on, so other fields changed meanwhile (here or in
    /// another window) are kept. No commit when nothing changed.
    @discardableResult
    func updateTask(_ id: String, _ change: @escaping (inout CoworkTask) -> Void) async -> Bool {
        await updateTasks([id: change], message: "Update \(id)")
    }

    /// Changes several tasks in one commit.
    @discardableResult
    func updateTasks(_ edits: [String: (inout CoworkTask) -> Void], message: String) async -> Bool {
        let now = Date()
        return await write(reading: edits.keys.map(CoworkPaths.task), message: message, optimistic: { snap in
            for (id, change) in edits {
                if let i = snap.tasks.firstIndex(where: { $0.id == id }) { change(&snap.tasks[i]) }
            }
        }) { current in
            var changes: [String: String?] = [:]
            for (id, change) in edits {
                let path = CoworkPaths.task(id)
                // Deleted meanwhile: don't bring it back.
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

    func deleteTask(_ t: CoworkTask) async {
        var changes: [String: String?] = [t.path: nil]
        for c in comments(on: t.commentParent) { changes[c.path] = .some(nil) }
        await write(reading: [], message: "Delete \(t.id)", optimistic: { snap in
            snap.tasks.removeAll { $0.id == t.id }
        }) { _ in changes }
    }

    /// Returns false when the comment couldn't be written.
    @discardableResult
    func addComment(on parent: String, body: String) async -> Bool {
        let now = Date()
        let c = CoworkComment(id: CoworkCodec.newCommentID(date: now), parent: parent, author: me.email,
                              authorName: me.name, created: now, body: body)
        return await apply([c.path: CoworkCodec.encode(c)], message: "Comment on \(parent)")
    }

    @discardableResult
    func requestReview(branch: String, base: String, title: String, reviewers: [String],
                       body: String, taskID: String?) async -> ReviewRequest? {
        let now = Date()
        let id = CoworkCodec.newID(prefix: "R-", existing: Set(snapshot.reviews.map(\.id)))
        var rv: [String: ReviewVerdict] = [:]
        for r in reviewers { rv[r.lowercased()] = .requested }
        let r = ReviewRequest(id: id, title: title, branch: branch, base: base, requester: me.email,
                              reviewers: rv, taskID: taskID, created: now, updated: now, body: body)
        let paths = taskID.map { [CoworkPaths.task($0)] } ?? []
        let ok = await write(reading: paths, message: "Request review of \(branch)") { current in
            var changes: [String: String?] = [r.path: CoworkCodec.encode(r)]
            // Move the linked task to "In Review".
            if let taskID, let text = current[CoworkPaths.task(taskID)],
               var t = CoworkCodec.decodeTask(text, id: taskID), t.status != .review, t.status != .done {
                t.status = .review
                t.updated = now
                changes[t.path] = CoworkCodec.encode(t)
            }
            return changes
        }
        return ok ? r : nil
    }

    /// Changes one review, applied to the stored copy at the tip (see updateTask).
    @discardableResult
    func updateReview(_ id: String, extra: [String: String?] = [:], message: String? = nil,
                      _ change: @escaping (inout ReviewRequest) -> Void) async -> Bool {
        let now = Date()
        let path = CoworkPaths.review(id)
        return await write(reading: [path], message: message ?? "Update review \(id)", optimistic: { snap in
            if let i = snap.reviews.firstIndex(where: { $0.id == id }) { change(&snap.reviews[i]) }
        }) { current in
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

    @discardableResult
    func setVerdict(_ verdict: ReviewVerdict, on review: ReviewRequest, comment: String) async -> Bool {
        let now = Date()
        var extra: [String: String?] = [:]
        if !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let c = CoworkComment(id: CoworkCodec.newCommentID(date: now), parent: review.commentParent, author: me.email,
                                  authorName: me.name, created: now, body: comment)
            extra[c.path] = CoworkCodec.encode(c)
        }
        let myID = me.id, myEmail = me.email
        return await updateReview(review.id, extra: extra, message: "\(verdict.rawValue) \(review.branch)") { r in
            // Reuse the key the requester wrote, whatever its case.
            let key = r.reviewers.keys.first { $0.lowercased() == myID } ?? myEmail.lowercased()
            r.reviewers[key] = verdict
        }
    }

    /// Saves the team list, merged with whatever is stored at the tip now
    /// (so members another window or teammate added or removed meanwhile stay that way).
    func saveTeam(_ members: [TeamMember]) async {
        let base = CoworkCodec.encodeTeam(snapshot.team)
        let ours = CoworkCodec.encodeTeam(members)
        await write(reading: [CoworkPaths.team], message: "Update team", optimistic: { $0.team = members }) { current in
            let merged = CoworkMerge.mergeFile(path: CoworkPaths.team, base: base, ours: ours,
                                               theirs: current[CoworkPaths.team] ?? base)
            return [CoworkPaths.team: merged ?? ours]
        }
    }
}
