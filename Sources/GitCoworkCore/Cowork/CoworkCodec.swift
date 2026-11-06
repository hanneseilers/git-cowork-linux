import Foundation

/// Converts between cowork files (path -> text) and models.
public enum CoworkCodec {
    // MARK: Dates

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func date(_ s: String?) -> Date? { s.flatMap { iso.date(from: $0) } }
    public static func string(_ d: Date) -> String { iso.string(from: d) }

    // MARK: IDs

    static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")   // no look-alikes

    /// "CW-a3f9". Random, so offline teammates don't collide like counters would.
    public static func newID(prefix: String, existing: Set<String>, length: Int = 4) -> String {
        while true {
            let id = prefix + String((0..<length).map { _ in alphabet.randomElement()! })
            if !existing.contains(id) { return id }
        }
    }

    /// Comment file name: sortable timestamp plus a random suffix.
    public static func newCommentID(date: Date) -> String {
        let stamp = string(date).replacingOccurrences(of: ":", with: "-")
        return stamp + "-" + String((0..<4).map { _ in alphabet.randomElement()! })
    }

    // MARK: Decode

    public static func decode(files: [String: String]) -> CoworkSnapshot {
        var snap = CoworkSnapshot()
        for (path, text) in files {
            let parts = path.split(separator: "/").map(String.init)
            if parts.count == 2, parts[0] == "tasks", parts[1].hasSuffix(".md") {
                if let t = decodeTask(text, id: String(parts[1].dropLast(3))) { snap.tasks.append(t) }
            } else if parts.count == 2, parts[0] == "reviews", parts[1].hasSuffix(".md") {
                if let r = decodeReview(text, id: String(parts[1].dropLast(3))) { snap.reviews.append(r) }
            } else if parts.count == 4, parts[2] == "comments", parts[3].hasSuffix(".md") {
                let parent = parts[0] + "/" + parts[1]
                if let c = decodeComment(text, id: String(parts[3].dropLast(3)), parent: parent) {
                    snap.comments[parent, default: []].append(c)
                }
            } else if path == CoworkPaths.team {
                snap.team = decodeTeam(text)
            }
        }
        for key in snap.comments.keys {
            snap.comments[key]!.sort { ($0.created, $0.id) < ($1.created, $1.id) }
        }
        return snap
    }

    public static func decodeTask(_ text: String, id: String) -> CoworkTask? {
        let doc = FrontMatter.parse(text)
        guard let title = doc["title"] else { return nil }
        let created = date(doc["created"]) ?? .distantPast
        return CoworkTask(
            id: doc["id"] ?? id,
            title: title,
            status: TaskStatus(rawValue: doc["status"] ?? "") ?? .backlog,
            assignee: doc["assignee"].flatMap { $0.isEmpty ? nil : $0 },
            labels: doc.list("labels"),
            branch: doc["branch"].flatMap { $0.isEmpty ? nil : $0 },
            author: doc["author"] ?? "",
            created: created,
            updated: date(doc["updated"]) ?? created,
            body: doc.body,
            rank: doc["rank"].flatMap(Double.init))
    }

    public static func decodeReview(_ text: String, id: String) -> ReviewRequest? {
        let doc = FrontMatter.parse(text)
        guard let branch = doc["branch"] else { return nil }
        var reviewers: [String: ReviewVerdict] = [:]
        for item in doc.list("reviewers") {
            let kv = item.split(separator: "=", maxSplits: 1).map(String.init)
            let verdict = kv.count == 2 ? ReviewVerdict(rawValue: kv[1]) ?? .requested : .requested
            // The same person under two spellings ("Ben@x.com", "ben@x.com"):
            // keep one entry, preferring an actual verdict over "requested".
            if let existing = reviewers.keys.first(where: { $0.lowercased() == kv[0].lowercased() }) {
                if verdict != .requested {
                    reviewers[existing] = nil
                    reviewers[kv[0]] = verdict
                }
            } else {
                reviewers[kv[0]] = verdict
            }
        }
        let created = date(doc["created"]) ?? .distantPast
        return ReviewRequest(
            id: doc["id"] ?? id,
            title: doc["title"] ?? branch,
            branch: branch,
            base: doc["base"] ?? "main",
            requester: doc["requester"] ?? "",
            reviewers: reviewers,
            status: ReviewStatus(rawValue: doc["state"] ?? "") ?? .open,
            taskID: doc["task"].flatMap { $0.isEmpty ? nil : $0 },
            created: created,
            updated: date(doc["updated"]) ?? created,
            body: doc.body)
    }

    public static func decodeComment(_ text: String, id: String, parent: String) -> CoworkComment? {
        let doc = FrontMatter.parse(text)
        guard let author = doc["author"] else { return nil }
        return CoworkComment(id: id, parent: parent, author: author, authorName: doc["name"] ?? author,
                             created: date(doc["created"]) ?? .distantPast, body: doc.body)
    }

    /// team.md: header-less list, one member per line: "- handle: Name <email>"
    public static func decodeTeam(_ text: String) -> [TeamMember] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("- ") else { return nil }
            l.removeFirst(2)
            guard let colon = l.firstIndex(of: ":"), let lt = l.lastIndex(of: "<"), let gt = l.lastIndex(of: ">"), lt < gt else { return nil }
            let handle = l[..<colon].trimmingCharacters(in: .whitespaces)
            let name = l[l.index(after: colon)..<lt].trimmingCharacters(in: .whitespaces)
            let email = String(l[l.index(after: lt)..<gt])
            return TeamMember(handle: handle, name: name, email: email)
        }
    }

    // MARK: Encode

    public static func encode(_ t: CoworkTask) -> String {
        var doc = FrontMatterDoc(body: t.body)
        doc["id"] = t.id
        doc["title"] = t.title
        doc["status"] = t.status.rawValue
        doc["assignee"] = t.assignee ?? ""
        doc.setList("labels", t.labels)
        doc["branch"] = t.branch ?? ""
        doc["author"] = t.author
        doc["created"] = string(t.created)
        doc["updated"] = string(t.updated)
        if let rank = t.rank { doc["rank"] = String(rank) }
        return FrontMatter.serialize(doc)
    }

    public static func encode(_ r: ReviewRequest) -> String {
        var doc = FrontMatterDoc(body: r.body)
        doc["id"] = r.id
        doc["title"] = r.title
        doc["state"] = r.status.rawValue
        doc["branch"] = r.branch
        doc["base"] = r.base
        doc["requester"] = r.requester
        doc.setList("reviewers", r.reviewers.keys.sorted().map { "\($0)=\(r.reviewers[$0]!.rawValue)" })
        doc["task"] = r.taskID ?? ""
        doc["created"] = string(r.created)
        doc["updated"] = string(r.updated)
        return FrontMatter.serialize(doc)
    }

    public static func encode(_ c: CoworkComment) -> String {
        var doc = FrontMatterDoc(body: c.body)
        doc["author"] = c.author
        doc["name"] = c.authorName
        doc["created"] = string(c.created)
        return FrontMatter.serialize(doc)
    }

    public static func encodeTeam(_ members: [TeamMember]) -> String {
        "# Team\n\n" + members.sorted { $0.handle < $1.handle }
            .map { "- \($0.handle): \($0.name) <\($0.email)>" }
            .joined(separator: "\n") + "\n"
    }
}
