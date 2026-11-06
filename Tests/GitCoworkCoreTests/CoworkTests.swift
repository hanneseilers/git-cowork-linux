import Foundation
import Testing
@testable import GitCoworkCore

@Suite struct FrontMatterTests {
    @Test func roundTripTrickyValues() {
        var doc = FrontMatterDoc(body: "Line one\n\n---\nnot a header")
        doc["title"] = "Fix: login, \"quotes\" and [brackets]"
        doc["empty"] = ""
        doc["lead"] = "  spaced"
        doc.setList("labels", ["backend", "needs design", "a,b", "x]y", "\"q\""])
        let text = FrontMatter.serialize(doc)
        let back = FrontMatter.parse(text)
        #expect(back["title"] == doc["title"])
        #expect(back["empty"] == "")
        #expect(back["lead"] == "  spaced")
        #expect(back.list("labels") == doc.list("labels"))
        #expect(back.body == doc.body)
    }

    @Test func noHeaderIsAllBody() {
        let doc = FrontMatter.parse("just text")
        #expect(doc.fields.isEmpty && doc.body == "just text")
    }
}

@Suite struct CodecTests {
    let d1 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func taskRoundTrip() {
        let t = CoworkTask(id: "CW-ab12", title: "Cache sessions", status: .doing, assignee: "anna@x.com",
                           labels: ["backend"], branch: "feat/cache", author: "ben@x.com",
                           created: d1, updated: d1.addingTimeInterval(60), body: "Body @anna", rank: 2.5)
        let back = CoworkCodec.decodeTask(CoworkCodec.encode(t), id: "ignored")
        #expect(back == t)
    }

    @Test func reviewRoundTripAndOverall() {
        var r = ReviewRequest(id: "R-1", title: "Login cache", branch: "feat/x", base: "main", requester: "a@x",
                              reviewers: ["b@x": .requested, "c@x": .approved], created: d1, updated: d1)
        let back = CoworkCodec.decodeReview(CoworkCodec.encode(r), id: "R-1")
        #expect(back == r)
        #expect(r.overall == .requested)
        r.reviewers["b@x"] = .approved
        #expect(r.overall == .approved)
        r.reviewers["c@x"] = .changesRequested
        #expect(r.overall == .changesRequested)
    }

    @Test func decodeTree() {
        let c = CoworkComment(id: "2026-01-01T00-00-00Z-abcd", parent: "tasks/CW-1", author: "a@x", authorName: "Anna", created: d1, body: "hi")
        let files = [
            "tasks/CW-1.md": CoworkCodec.encode(CoworkTask(id: "CW-1", title: "T", author: "a@x", created: d1, updated: d1)),
            c.path: CoworkCodec.encode(c),
            "team.md": CoworkCodec.encodeTeam([TeamMember(handle: "anna", name: "Anna Berg", email: "anna@x.com")]),
            "README.md": "ignored",
        ]
        let snap = CoworkCodec.decode(files: files)
        #expect(snap.tasks.count == 1)
        #expect(snap.comments["tasks/CW-1"]?.first == c)
        #expect(snap.team == [TeamMember(handle: "anna", name: "Anna Berg", email: "anna@x.com")])
    }

    @Test func idsAreUnique() {
        var seen = Set<String>()
        for _ in 0..<200 { seen.insert(CoworkCodec.newID(prefix: "CW-", existing: seen)) }
        #expect(seen.count == 200)
    }
}

@Suite struct MergeTests {
    func task(_ edit: (inout CoworkTask) -> Void) -> String {
        var t = CoworkTask(id: "CW-1", title: "Base", status: .todo, author: "a@x",
                           created: Date(timeIntervalSince1970: 1_700_000_000),
                           updated: Date(timeIntervalSince1970: 1_700_000_000))
        edit(&t)
        return CoworkCodec.encode(t)
    }

    @Test func differentFieldsBothSurvive() {
        let base = task { _ in }
        let ours = task { $0.status = .doing; $0.updated = Date(timeIntervalSince1970: 1_700_000_100) }
        let theirs = task { $0.assignee = "b@x"; $0.updated = Date(timeIntervalSince1970: 1_700_000_050) }
        let merged = CoworkCodec.decodeTask(CoworkMerge.mergeFile(path: "tasks/CW-1.md", base: base, ours: ours, theirs: theirs)!, id: "CW-1")!
        #expect(merged.status == .doing)
        #expect(merged.assignee == "b@x")
        #expect(merged.updated == Date(timeIntervalSince1970: 1_700_000_100))
    }

    @Test func sameFieldNewerWins() {
        let base = task { _ in }
        let ours = task { $0.title = "Ours"; $0.updated = Date(timeIntervalSince1970: 1_700_000_010) }
        let theirs = task { $0.title = "Theirs"; $0.updated = Date(timeIntervalSince1970: 1_700_000_020) }
        let merged = CoworkCodec.decodeTask(CoworkMerge.mergeFile(path: "tasks/CW-1.md", base: base, ours: ours, theirs: theirs)!, id: "CW-1")!
        #expect(merged.title == "Theirs")
    }

    @Test func concurrentApprovalsBothCount() {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        func review(_ rv: [String: ReviewVerdict], _ t: TimeInterval) -> String {
            CoworkCodec.encode(ReviewRequest(id: "R-1", title: "x", branch: "b", base: "main", requester: "a@x",
                                             reviewers: rv, created: d, updated: d.addingTimeInterval(t)))
        }
        let base = review(["b@x": .requested, "c@x": .requested], 0)
        let ours = review(["b@x": .approved, "c@x": .requested], 10)
        let theirs = review(["b@x": .requested, "c@x": .approved], 20)
        let merged = CoworkCodec.decodeReview(CoworkMerge.mergeFile(path: "reviews/R-1.md", base: base, ours: ours, theirs: theirs)!, id: "R-1")!
        #expect(merged.reviewers == ["b@x": .approved, "c@x": .approved])
        #expect(merged.overall == .approved)
    }

    @Test func editBeatsDelete() {
        let base = task { _ in }
        let theirs = task { $0.title = "Edited" }
        #expect(CoworkMerge.mergeFile(path: "tasks/CW-1.md", base: base, ours: nil, theirs: theirs) == theirs)
        #expect(CoworkMerge.mergeFile(path: "tasks/CW-1.md", base: base, ours: base, theirs: nil) == nil)
    }

    @Test func bodyMergesLikeAField() {
        let base = task { _ in }
        let ours = task { $0.body = "new body" }
        let theirs = task { $0.status = .done }
        let merged = CoworkCodec.decodeTask(CoworkMerge.mergeFile(path: "tasks/CW-1.md", base: base, ours: ours, theirs: theirs)!, id: "CW-1")!
        #expect(merged.body == "new body" && merged.status == .done)
    }

    @Test func teamUnion() {
        let a = CoworkCodec.encodeTeam([TeamMember(handle: "anna", name: "Anna", email: "anna@x")])
        let b = CoworkCodec.encodeTeam([TeamMember(handle: "ben", name: "Ben", email: "ben@x")])
        let merged = CoworkCodec.decodeTeam(CoworkMerge.mergeFile(path: "team.md", base: nil, ours: a, theirs: b)!)
        #expect(Set(merged.map(\.handle)) == ["anna", "ben"])
    }

    @Test func teamRemovalSurvivesConcurrentAdd() {
        let x = TeamMember(handle: "x", name: "X", email: "x@x"), y = TeamMember(handle: "y", name: "Y", email: "y@x")
        let z = TeamMember(handle: "z", name: "Z", email: "z@x")
        let base = CoworkCodec.encodeTeam([x, y])
        let ours = CoworkCodec.encodeTeam([x])           // removed y
        let theirs = CoworkCodec.encodeTeam([x, y, z])   // added z
        let merged = CoworkCodec.decodeTeam(CoworkMerge.mergeFile(path: "team.md", base: base, ours: ours, theirs: theirs)!)
        #expect(Set(merged.map(\.handle)) == ["x", "z"])
    }

    @Test func reviewerKeysFoldCaseInsensitively() {
        let text = "---\nbranch: f\nreviewers: [Ben@X.com=requested, ben@x.com=approved]\n---\n"
        let r = CoworkCodec.decodeReview(text, id: "R-1")!
        #expect(r.reviewers.count == 1 && r.overall == .approved)
    }
}

@Suite struct MentionTests {
    @Test func findsHandlesNotEmails() {
        #expect(Mentions.handles(in: "@anna can you check? cc @ben.ortiz. mail me at x@y.com") == ["anna", "ben.ortiz"])
    }

    @Test func resolves() {
        let team = [TeamMember(handle: "anna", name: "Anna", email: "Anna@x.com")]
        let e = Mentions.emails(in: "@anna @claude @nobody", team: team, knownEmails: ["claude@agents.dev"])
        #expect(e == ["anna@x.com", "claude@agents.dev"])
    }
}
