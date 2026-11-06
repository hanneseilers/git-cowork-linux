import Foundation

public enum HostKind: String, CaseIterable, Sendable {
    case github, gitlab, gitea   // gitea also covers Forgejo / Codeberg
}

/// Turns a git remote URL into web links for GitHub, GitLab and Gitea/Forgejo.
public struct RemoteLinks: Hashable, Sendable {
    public let host: String
    public let path: String       // "org/repo" (GitLab may have subgroups: "group/sub/repo")
    public let kind: HostKind?

    public var webBase: String { "https://\(host)/\(path)" }

    /// Parses ssh (`git@host:org/repo.git`, `ssh://git@host:22/org/repo.git`)
    /// and http(s) remote URLs. `overrides` maps host name -> kind for
    /// self-hosted servers whose name doesn't give it away.
    public init?(remoteURL: String, overrides: [String: HostKind] = [:]) {
        var s = remoteURL.trimmingCharacters(in: .whitespaces)
        var host: String
        var path: String

        if let r = s.range(of: "://") {
            s = String(s[r.upperBound...])
            if let at = s.firstIndex(of: "@"), s[..<at].contains(where: { $0 != "/" }), !s[..<at].contains("/") {
                s = String(s[s.index(after: at)...])
            }
            guard let slash = s.firstIndex(of: "/") else { return nil }
            host = String(s[..<slash])
            path = String(s[s.index(after: slash)...])
            if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }  // drop port
        } else if let colon = s.firstIndex(of: ":"), !s.hasPrefix("/") {
            // scp-like: git@host:org/repo.git
            var hostPart = String(s[..<colon])
            if let at = hostPart.firstIndex(of: "@") { hostPart = String(hostPart[hostPart.index(after: at)...]) }
            host = hostPart
            path = String(s[s.index(after: colon)...])
        } else {
            return nil   // local path remote
        }

        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        while path.hasSuffix("/") { path.removeLast() }
        while path.hasPrefix("/") { path.removeFirst() }
        guard !host.isEmpty, !path.isEmpty else { return nil }

        self.host = host
        self.path = path
        self.kind = overrides[host.lowercased()] ?? RemoteLinks.guessKind(host: host)
    }

    static func guessKind(host: String) -> HostKind? {
        let h = host.lowercased()
        if h == "github.com" || h.contains("github") { return .github }
        if h.contains("gitlab") { return .gitlab }
        if h.contains("gitea") || h.contains("forgejo") || h.contains("codeberg") { return .gitea }
        return nil
    }

    public func commitURL(_ sha: String) -> URL? {
        switch kind {
        case .gitlab: return URL(string: "\(webBase)/-/commit/\(sha)")
        default: return URL(string: "\(webBase)/commit/\(sha)")
        }
    }

    public func branchURL(_ branch: String) -> URL? {
        let b = Self.escape(branch)
        switch kind {
        case .gitlab: return URL(string: "\(webBase)/-/tree/\(b)")
        case .gitea: return URL(string: "\(webBase)/src/branch/\(b)")
        default: return URL(string: "\(webBase)/tree/\(b)")
        }
    }

    /// Page for opening a pull/merge request from `branch` into `base`.
    public func newPullRequestURL(branch: String, base: String?) -> URL? {
        let b = Self.escape(branch)
        switch kind {
        case .gitlab:
            var s = "\(webBase)/-/merge_requests/new?merge_request%5Bsource_branch%5D=\(b)"
            if let base { s += "&merge_request%5Btarget_branch%5D=\(Self.escape(base))" }
            return URL(string: s)
        case .gitea:
            return URL(string: "\(webBase)/compare/\(Self.escape(base ?? "main"))...\(b)")
        case .github, .none:
            if let base { return URL(string: "\(webBase)/compare/\(Self.escape(base))...\(b)?expand=1") }
            return URL(string: "\(webBase)/compare/\(b)?expand=1")
        }
    }

    public var pullRequestTerm: String { kind == .gitlab ? "Merge Request" : "Pull Request" }

    static func escape(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#&=")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Parses "git.example.com = gitlab" lines from settings.
    public static func parseOverrides(_ text: String) -> [String: HostKind] {
        var result: [String: HostKind] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            let kind: HostKind? = switch parts[1] {
            case "github": .github
            case "gitlab": .gitlab
            case "gitea", "forgejo", "codeberg": .gitea
            default: nil
            }
            if let kind { result[parts[0]] = kind }
        }
        return result
    }
}
