import Foundation

public struct Commit: Identifiable, Hashable, Sendable {
    public let id: String          // full sha
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    public let date: Date
    public let subject: String
    public let bodyPreview: String  // first line of the body, may be empty

    public init(id: String, parents: [String], authorName: String, authorEmail: String, date: Date, subject: String, bodyPreview: String = "") {
        self.bodyPreview = bodyPreview
        self.id = id
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.date = date
        self.subject = subject
    }

    public var shortID: String { String(id.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }
}

public struct CommitDetail: Hashable, Sendable {
    public let id: String
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    public let authorDate: Date
    public let committerName: String
    public let committerEmail: String
    public let committerDate: Date
    public let message: String

    public init(id: String, parents: [String], authorName: String, authorEmail: String, authorDate: Date,
                committerName: String, committerEmail: String, committerDate: Date, message: String) {
        self.id = id; self.parents = parents
        self.authorName = authorName; self.authorEmail = authorEmail; self.authorDate = authorDate
        self.committerName = committerName; self.committerEmail = committerEmail; self.committerDate = committerDate
        self.message = message
    }

    public var subject: String { message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "" }
    public var body: String {
        guard let r = message.range(of: "\n") else { return "" }
        return message[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum RefKind: Int, Hashable, Sendable {
    case localBranch, remoteBranch, tag
}

public struct Ref: Identifiable, Hashable, Sendable {
    public var id: String { fullName }
    public let fullName: String     // refs/heads/main
    public let name: String         // main, origin/main, v1.0
    public let kind: RefKind
    public let target: String       // commit sha (peeled for annotated tags)
    public let upstream: String?    // origin/main
    public let ahead: Int
    public let behind: Int
    public let upstreamGone: Bool
    public let isHead: Bool

    public init(fullName: String, name: String, kind: RefKind, target: String,
                upstream: String? = nil, ahead: Int = 0, behind: Int = 0,
                upstreamGone: Bool = false, isHead: Bool = false) {
        self.fullName = fullName
        self.name = name
        self.kind = kind
        self.target = target
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.upstreamGone = upstreamGone
        self.isHead = isHead
    }

    /// "origin" for "origin/feature/x". Nil for non-remote refs.
    public var remoteName: String? {
        guard kind == .remoteBranch else { return nil }
        return name.split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    /// "feature/x" for "origin/feature/x".
    public var branchNameWithoutRemote: String {
        guard kind == .remoteBranch, let i = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: i)...])
    }
}

public struct Worktree: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let head: String?
    public let branch: String?      // short name, nil when detached
    public let isBare: Bool
    public let isLocked: Bool
    public let isPrunable: Bool
    public let isMain: Bool

    public var displayName: String { (path as NSString).lastPathComponent }
}

public enum FileStatus: Character, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typeChanged = "T"
    case untracked = "?"
    case conflicted = "U"
    case unknown = "X"

    public init(code: Character) {
        self = FileStatus(rawValue: code) ?? .unknown
    }
}

public enum ChangeArea: String, Hashable, Sendable {
    case staged, unstaged, untracked, conflicted
}

public struct FileChange: Identifiable, Hashable, Sendable {
    public var id: String { area.rawValue + ":" + path }
    public let path: String
    public let oldPath: String?
    public let status: FileStatus
    public let area: ChangeArea

    public init(path: String, oldPath: String? = nil, status: FileStatus, area: ChangeArea) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.area = area
    }

    public var fileName: String { (path as NSString).lastPathComponent }
    public var directory: String {
        let d = (path as NSString).deletingLastPathComponent
        return d
    }
}

public struct WorkingStatus: Hashable, Sendable {
    public var headOID: String?     // nil before the first commit
    public var branch: String?      // nil when detached
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var staged: [FileChange] = []
    public var unstaged: [FileChange] = []
    public var untracked: [FileChange] = []
    public var conflicted: [FileChange] = []

    public init() {}

    public var changeCount: Int {
        // A file can be both staged and unstaged; count unique paths.
        var paths = Set<String>()
        for c in staged { paths.insert(c.path) }
        for c in unstaged { paths.insert(c.path) }
        for c in untracked { paths.insert(c.path) }
        for c in conflicted { paths.insert(c.path) }
        return paths.count
    }

    public var isClean: Bool { changeCount == 0 }
}

public struct Stash: Identifiable, Hashable, Sendable {
    public var id: String { selector }
    public let sha: String
    public let selector: String     // stash@{0}
    public let message: String
}

public struct Remote: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let url: String
}

public enum RepoOperation: String, Sendable {
    case merge = "Merge"
    case rebase = "Rebase"
    case cherryPick = "Cherry-pick"
    case revert = "Revert"
}
