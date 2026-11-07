import CoworkKit
import Foundation
import GitCoworkCore

/// Creating and changing tasks, reviews, comments and the team. What each
/// edit writes is defined once in CoworkEdit (shared with the `git-cowork`
/// tool); here it's also shown on screen right away (`optimistic`).
extension CoworkStore {
    @discardableResult
    func createTask(title: String, status: TaskStatus = .backlog, assignee: String? = nil,
                    labels: [String] = [], body: String = "") async -> CoworkTask? {
        let (t, edit) = CoworkEdit.newTask(title: title, status: status, assignee: assignee, labels: labels,
                                           body: body, author: me.email, in: snapshot)
        return await write(edit) ? t : nil
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
        await write(CoworkEdit.updateTasks(edits, message: message)) { snap in
            for (id, change) in edits {
                if let i = snap.tasks.firstIndex(where: { $0.id == id }) { change(&snap.tasks[i]) }
            }
        }
    }

    func deleteTask(_ t: CoworkTask) async {
        await write(CoworkEdit.deleteTask(t, comments: comments(on: t.commentParent))) { snap in
            snap.tasks.removeAll { $0.id == t.id }
        }
    }

    /// Returns false when the comment couldn't be written.
    @discardableResult
    func addComment(on parent: String, body: String) async -> Bool {
        await write(CoworkEdit.comment(on: parent, body: body, by: me).1)
    }

    @discardableResult
    func requestReview(branch: String, base: String, title: String, reviewers: [String],
                       body: String, taskID: String?) async -> ReviewRequest? {
        let (r, edit) = CoworkEdit.requestReview(branch: branch, base: base, title: title, reviewers: reviewers,
                                                 body: body, taskID: taskID, requester: me.email, in: snapshot)
        return await write(edit) ? r : nil
    }

    /// Changes one review, applied to the stored copy at the tip (see updateTask).
    @discardableResult
    func updateReview(_ id: String, extra: [String: String?] = [:], message: String? = nil,
                      _ change: @escaping (inout ReviewRequest) -> Void) async -> Bool {
        await write(CoworkEdit.updateReview(id, extra: extra, message: message, change)) { snap in
            if let i = snap.reviews.firstIndex(where: { $0.id == id }) { change(&snap.reviews[i]) }
        }
    }

    @discardableResult
    func setVerdict(_ verdict: ReviewVerdict, on review: ReviewRequest, comment: String) async -> Bool {
        let myID = me.id, myEmail = me.email
        return await write(CoworkEdit.verdict(verdict, on: review, comment: comment, by: me)) { snap in
            guard let i = snap.reviews.firstIndex(where: { $0.id == review.id }) else { return }
            let key = snap.reviews[i].reviewers.keys.first { $0.lowercased() == myID } ?? myEmail.lowercased()
            snap.reviews[i].reviewers[key] = verdict
        }
    }

    /// Saves the team list, merged with whatever is stored at the tip now
    /// (so members another window or teammate added or removed meanwhile stay that way).
    func saveTeam(_ members: [TeamMember]) async {
        await write(CoworkEdit.saveTeam(members, previous: snapshot.team)) { $0.team = members }
    }
}
