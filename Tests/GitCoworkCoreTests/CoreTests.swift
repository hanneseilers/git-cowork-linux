import Foundation
import Testing
@testable import GitCoworkCore

private func c(_ id: String, _ parents: String...) -> Commit {
    Commit(id: id, parents: parents, authorName: "a", authorEmail: "a@x", date: .init(), subject: id)
}

@Suite struct GraphLayoutTests {
    @Test func linearHistoryStaysInOneLane() {
        let rows = GraphLayout.layout([c("c", "b"), c("b", "a"), c("a")])
        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(rows.allSatisfy { $0.laneCount == 1 })
        // Tip has no incoming line; root has no outgoing line.
        #expect(!rows[0].lines.contains { $0.from == .top })
        #expect(!rows[2].lines.contains { $0.to == .bottom })
    }

    @Test func branchAndMerge() {
        // m merges f into b; both come from a.
        //  m
        //  |\
        //  b f
        //  |/
        //  a
        let rows = GraphLayout.layout([c("m", "b", "f"), c("f", "a"), c("b", "a"), c("a")])
        #expect(rows[0].lane == 0)
        #expect(rows[0].lines.contains(GraphLine(fromLane: 0, from: .middle, toLane: 1, to: .bottom, color: rows[0].lines.last!.color)))
        #expect(rows[1].lane == 1)       // f in the second lane
        #expect(rows[2].lane == 0)       // b back in the first lane
        #expect(rows[3].lane == 0)       // a: both lanes join here
        let incoming = rows[3].lines.filter { $0.to == .middle }
        #expect(Set(incoming.map(\.fromLane)) == [0, 1])
    }

    @Test func twoTipsGetTwoLanesAndFreedLaneIsReused() {
        let rows = GraphLayout.layout([c("x", "a"), c("y", "a"), c("a"), c("z")])
        #expect(rows[0].lane == 0)
        #expect(rows[1].lane == 1)
        #expect(rows[2].lane == 0)
        #expect(rows[3].lane == 0)       // unrelated root reuses the freed lane
        #expect(rows[3].laneCount == 1)
    }

    @Test func missingParentKeepsLaneOpen() {
        let rows = GraphLayout.layout([c("b", "a")])   // a not loaded
        #expect(rows[0].lines.contains { $0.to == .bottom })
    }
}

@Suite struct ParserTests {
    @Test func log() {
        let out = "aaa\u{1f}bbb ccc\u{1f}Anna\u{1f}anna@x\u{1f}1700000000\u{1f}Merge: things\u{1e}\nbbb\u{1f}\u{1f}Ben\u{1f}ben@x\u{1f}1700000000\u{1f}root\u{1e}\n"
        let commits = Parsers.parseLog(out)
        #expect(commits.count == 2)
        #expect(commits[0].parents == ["bbb", "ccc"])
        #expect(commits[0].subject == "Merge: things")
        #expect(commits[1].parents.isEmpty)
    }

    @Test func refs() {
        let s = "\u{1f}"
        let out = [
            ["refs/heads/main", "111", "", "origin/main", "ahead 2, behind 1", "*", ""],
            ["refs/heads/old", "222", "", "origin/old", "gone", " ", ""],
            ["refs/remotes/origin/HEAD", "111", "", "", "", " ", "refs/remotes/origin/main"],
            ["refs/remotes/origin/feature/x", "333", "", "", "", " ", ""],
            ["refs/tags/v1", "444", "555", "", "", " ", ""],
        ].map { $0.joined(separator: s) }.joined(separator: "\n")
        let list = Parsers.parseRefs(out)
        #expect(list.refs.count == 4)
        #expect(list.refs[0].isHead && list.refs[0].ahead == 2 && list.refs[0].behind == 1)
        #expect(list.refs[1].upstreamGone)
        #expect(list.refs[2].remoteName == "origin" && list.refs[2].branchNameWithoutRemote == "feature/x")
        #expect(list.refs[3].target == "555")   // annotated tag peeled
        #expect(list.remoteDefaults["origin"] == "main")
    }

    @Test func status() {
        let out = [
            "# branch.oid abc",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +1 -3",
            "1 M. N... 100644 100644 100644 h1 h2 src/a file.swift",
            "1 .M N... 100644 100644 100644 h1 h2 b.swift",
            "2 R. N... 100644 100644 100644 h1 h2 R100 new.swift",
            "old.swift",
            "u UU N... 100644 100644 100644 100644 h1 h2 h3 conflict.txt",
            "? new dir/",
            "",
        ].joined(separator: "\0")
        let st = Parsers.parseStatus(out)
        #expect(st.branch == "main" && st.ahead == 1 && st.behind == 3)
        #expect(st.staged.map(\.path) == ["src/a file.swift", "new.swift"])
        #expect(st.staged[1].oldPath == "old.swift")
        #expect(st.unstaged.map(\.path) == ["b.swift"])
        #expect(st.conflicted.map(\.path) == ["conflict.txt"])
        #expect(st.untracked.map(\.path) == ["new dir/"])
        #expect(st.changeCount == 5)
    }

    @Test func worktrees() {
        let out = """
        worktree /repo
        HEAD 111
        branch refs/heads/main

        worktree /repo-wt
        HEAD 222
        detached
        locked

        """
        let wts = Parsers.parseWorktrees(out)
        #expect(wts.count == 2)
        #expect(wts[0].isMain && wts[0].branch == "main")
        #expect(!wts[1].isMain && wts[1].branch == nil && wts[1].isLocked)
    }

    @Test func nameStatus() {
        let out = "M\0a.txt\0R087\0old.txt\0new.txt\0D\0gone.txt\0"
        let files = Parsers.parseNameStatus(out)
        #expect(files.map(\.path) == ["a.txt", "new.txt", "gone.txt"])
        #expect(files[1].status == .renamed && files[1].oldPath == "old.txt")
    }
}

@Suite struct DiffTests {
    @Test func lineNumbers() {
        let diff = """
        diff --git a/f b/f
        index 1..2 100644
        --- a/f
        +++ b/f
        @@ -10,3 +10,4 @@ func x()
         same
        -old
        +new
        +added
         end
        """
        let (lines, truncated) = DiffParser.parse(diff)
        #expect(!truncated)
        #expect(lines.map(\.kind) == [.hunk, .context, .removed, .added, .added, .context])
        #expect(lines[1].oldNumber == 10 && lines[1].newNumber == 10)
        #expect(lines[2].oldNumber == 11)
        #expect(lines[4].newNumber == 12)
        #expect(lines[5].oldNumber == 12 && lines[5].newNumber == 13)
    }
}

@Suite struct RemoteLinkTests {
    @Test func formats() {
        let a = RemoteLinks(remoteURL: "git@github.com:org/repo.git")!
        #expect(a.host == "github.com" && a.path == "org/repo" && a.kind == .github)

        let b = RemoteLinks(remoteURL: "ssh://git@gitlab.example.com:2222/group/sub/repo.git")!
        #expect(b.host == "gitlab.example.com" && b.path == "group/sub/repo" && b.kind == .gitlab)
        #expect(b.newPullRequestURL(branch: "feat/x", base: "main")!.absoluteString
                == "https://gitlab.example.com/group/sub/repo/-/merge_requests/new?merge_request%5Bsource_branch%5D=feat/x&merge_request%5Btarget_branch%5D=main")

        let c = RemoteLinks(remoteURL: "https://user@git.company.io/team/app", overrides: ["git.company.io": .gitea])!
        #expect(c.host == "git.company.io" && c.kind == .gitea)
        #expect(c.branchURL("dev")!.absoluteString == "https://git.company.io/team/app/src/branch/dev")

        #expect(RemoteLinks(remoteURL: "/local/path/repo.git") == nil)
    }

    @Test func overrides() {
        let o = RemoteLinks.parseOverrides("git.a.com = gitlab\n bad line\nforge.b = forgejo")
        #expect(o == ["git.a.com": .gitlab, "forge.b": .gitea])
    }
}
