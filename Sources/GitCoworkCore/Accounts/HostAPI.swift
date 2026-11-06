import Foundation

/// Host API calls for sign-in and the repo list (HostRepos.swift). Builds
/// requests and reads responses; the app does the actual networking.
public enum HostAPI {
    /// API base for a host: api.github.com for github.com, /api/v3 on GitHub
    /// Enterprise, /api/v4 on GitLab, /api/v1 on Gitea and Forgejo.
    public static func apiBase(kind: HostKind, host: String) -> String {
        switch kind {
        case .github: host == "github.com" ? "https://api.github.com" : "https://\(host)/api/v3"
        case .gitlab: "https://\(host)/api/v4"
        case .gitea: "https://\(host)/api/v1"
        }
    }

    /// GET the signed-in user, to check a token and learn the account name.
    public static func currentUserRequest(kind: HostKind, host: String, token: String) -> URLRequest? {
        guard let url = URL(string: apiBase(kind: kind, host: host) + "/user") else { return nil }
        return authorized(url, kind: kind, token: token)
    }

    /// Account name from a /user response: `login` on GitHub and Gitea, `username` on GitLab.
    public static func parseUsername(_ data: Data, kind: HostKind) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let name = obj[kind == .gitlab ? "username" : "login"] as? String
        return name?.isEmpty == false ? name : nil
    }

    /// Where to create a personal access token with the scopes git-cowork needs.
    public static func newTokenPage(kind: HostKind, host: String) -> URL? {
        switch kind {
        case .github:
            URL(string: "https://\(host)/settings/tokens/new?scopes=repo,workflow,read:org&description=git-cowork")
        case .gitlab:
            URL(string: "https://\(host)/-/user_settings/personal_access_tokens?name=git-cowork&scopes=read_user,read_api,write_repository")
        case .gitea:
            URL(string: "https://\(host)/user/settings/applications")
        }
    }

    /// Scopes to tick when making a token by hand.
    public static func tokenScopesHint(kind: HostKind) -> String {
        switch kind {
        case .github: "repo, workflow and read:org"
        case .gitlab: "read_user, read_api and write_repository"
        case .gitea: "read:user and write:repository"
        }
    }

    /// Adds the token and Accept header each host wants.
    static func authorized(_ url: URL, kind: HostKind, token: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(kind == .gitea ? "token \(token)" : "Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(kind == .github ? "application/vnd.github+json" : "application/json", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 20
        return r
    }
}
