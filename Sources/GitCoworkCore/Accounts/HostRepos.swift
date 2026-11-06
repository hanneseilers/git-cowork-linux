import Foundation

/// A repository the signed-in account can clone, from the host's API.
public struct HostRepo: Hashable, Sendable, Identifiable {
    public var name: String        // "repo"
    public var fullPath: String    // "org/repo", or "group/sub/repo" on GitLab
    public var cloneURL: String    // always https://
    public var isPrivate: Bool
    public var updatedAt: Date?

    public var id: String { fullPath }

    public init(name: String, fullPath: String, cloneURL: String, isPrivate: Bool, updatedAt: Date?) {
        self.name = name
        self.fullPath = fullPath
        self.cloneURL = cloneURL
        self.isPrivate = isPrivate
        self.updatedAt = updatedAt
    }

    /// Case-insensitive match on the full path ("org/repo"). Empty matches all.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || fullPath.localizedCaseInsensitiveContains(q)
    }
}

/// Listing the account's repos, newest activity first: the user's own, the
/// ones shared with them, and their orgs' or groups' repos.
extension HostAPI {
    /// Most pages `HostRepos` follows (GitHub/GitLab: 100 per page, Gitea: 50).
    public static let maxRepoPages = 10

    /// First page of the account's repos.
    public static func reposRequest(kind: HostKind, host: String, token: String) -> URLRequest? {
        let path = switch kind {
        case .github: "/user/repos?per_page=100&sort=pushed"
        case .gitlab: "/projects?membership=true&order_by=last_activity_at&per_page=100"
        case .gitea: "/user/repos?limit=50"
        }
        guard let url = URL(string: apiBase(kind: kind, host: host) + path) else { return nil }
        return authorized(url, kind: kind, token: token)
    }

    /// A later page, from the `next` link of the previous response. Nil when
    /// the link points anywhere but this host's API, so the token stays there.
    public static func nextReposRequest(linkHeader: String?, kind: HostKind, host: String, token: String) -> URLRequest? {
        guard let next = nextPageURL(linkHeader: linkHeader),
              let base = URL(string: apiBase(kind: kind, host: host)),
              next.scheme == "https", next.host?.lowercased() == base.host?.lowercased(), next.port == base.port,
              next.path.hasPrefix(base.path)
        else { return nil }
        return authorized(next, kind: kind, token: token)
    }

    /// The `rel="next"` URL of an RFC 8288 Link header, as GitHub, GitLab and Gitea send it:
    /// `<https://api.github.com/user/repos?page=2>; rel="next", <…>; rel="last"`.
    public static func nextPageURL(linkHeader: String?) -> URL? {
        guard let linkHeader else { return nil }
        for part in linkHeader.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let target = pieces.first, target.hasPrefix("<"), target.hasSuffix(">") else { continue }
            let isNext = pieces.dropFirst().contains { param in
                let p = param.replacingOccurrences(of: " ", with: "").lowercased()
                return p == "rel=\"next\"" || p == "rel=next"
            }
            if isNext { return URL(string: String(target.dropFirst().dropLast())) }
        }
        return nil
    }

    /// Repos in one page of a listing. Nil when the response isn't a list
    /// (an error object, say). Entries without a usable path are skipped.
    public static func parseRepos(_ data: Data, kind: HostKind, host: String) -> [HostRepo]? {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return items.compactMap { repo(from: $0, kind: kind, host: host) }
    }

    private static func repo(from obj: [String: Any], kind: HostKind, host: String) -> HostRepo? {
        let fullPath: String?, name: String?, cloneURL: String?, isPrivate: Bool, updated: String?
        switch kind {
        case .github, .gitea:
            fullPath = obj["full_name"] as? String
            name = obj["name"] as? String
            cloneURL = obj["clone_url"] as? String
            isPrivate = obj["private"] as? Bool ?? false
            updated = (obj["pushed_at"] as? String) ?? (obj["updated_at"] as? String)
        case .gitlab:
            fullPath = obj["path_with_namespace"] as? String
            name = obj["path"] as? String
            cloneURL = obj["http_url_to_repo"] as? String
            isPrivate = (obj["visibility"] as? String).map { $0 != "public" } ?? true
            updated = obj["last_activity_at"] as? String
        }
        guard let fullPath, !fullPath.isEmpty else { return nil }
        // Use the server's HTTPS URL; build one if it gave http:// or nothing,
        // so git finds the token stored for https://<host>.
        let url = cloneURL.flatMap { $0.lowercased().hasPrefix("https://") ? $0 : nil }
            ?? "https://\(host)/\(fullPath).git"
        let shortName = name.flatMap { $0.isEmpty ? nil : $0 }
            ?? fullPath.split(separator: "/").last.map(String.init) ?? fullPath
        return HostRepo(name: shortName, fullPath: fullPath, cloneURL: url,
                        isPrivate: isPrivate, updatedAt: updated.flatMap(parseDate))
    }

    /// ISO 8601 with or without fractional seconds ("2024-05-01T10:00:00Z",
    /// "2024-05-01T10:00:00.123+02:00").
    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
