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

    // MARK: SSH keys

    /// POST /user/keys, on GitHub and GitLab alike. GitHub needs the
    /// `write:public_key` scope, GitLab `api`. GitLab keys are marked for
    /// sign-in only (`usage_type`), since the app doesn't sign commits with them.
    public static func addSSHKeyRequest(kind: HostKind, host: String, token: String, title: String, publicKey: String) -> URLRequest? {
        guard kind != .gitea, let url = URL(string: apiBase(kind: kind, host: host) + "/user/keys") else { return nil }
        var r = authorized(url, kind: kind, token: token)
        var body = ["title": title, "key": publicKey.trimmingCharacters(in: .whitespacesAndNewlines)]
        if kind == .gitlab { body["usage_type"] = "auth" }
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }

    public enum AddKeyResult: Equatable, Sendable {
        case added
        /// The token works but may not add keys: an older sign-in without
        /// `write:public_key` (GitHub) or `api` (GitLab).
        case missingScope
        /// The token is no longer valid.
        case signedOut
        case failed(String)
    }

    /// Reads the answer to `addSSHKeyRequest`. `grantedScopes` is GitHub's
    /// X-OAuth-Scopes header, when there is one.
    public static func parseAddSSHKey(status: Int, data: Data, kind: HostKind, grantedScopes: String? = nil) -> AddKeyResult {
        switch status {
        case 200..<300:
            return .added
        case 401:
            return .signedOut
        case 403, 404:
            // GitHub answers 404 when a scope is missing, and lists the token's
            // scopes in a header; fine-grained tokens have no such header.
            if kind == .github, let grantedScopes {
                let scopes = Set(grantedScopes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                if scopes.isDisjoint(with: ["write:public_key", "admin:public_key"]) { return .missingScope }
                return .failed(errorMessage(data) ?? "HTTP \(status)")
            }
            return .missingScope
        default:
            return .failed(errorMessage(data) ?? "HTTP \(status)")
        }
    }

    /// The human part of an API error: GitHub's `errors[].message` or
    /// `message`, GitLab's `message` (a string or `{field: [problems]}`).
    static func errorMessage(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let errors = obj["errors"] as? [[String: Any]] {
            let messages = errors.compactMap { $0["message"] as? String }
            if !messages.isEmpty { return messages.joined(separator: "; ") }
        }
        if let message = obj["message"] as? String { return message }
        if let fields = obj["message"] as? [String: Any] {
            return fields.keys.sorted().compactMap { key in
                (fields[key] as? [String]).map { "\(key) \($0.joined(separator: ", "))" }
            }.joined(separator: "; ")
        }
        return obj["error_description"] as? String ?? obj["error"] as? String
    }

    /// Where to create a personal access token with the scopes git-cowork needs.
    public static func newTokenPage(kind: HostKind, host: String) -> URL? {
        switch kind {
        case .github:
            URL(string: "https://\(host)/settings/tokens/new?scopes=repo,workflow,read:org,write:public_key&description=git-cowork")
        case .gitlab:
            URL(string: "https://\(host)/-/user_settings/personal_access_tokens?name=git-cowork&scopes=read_user,api,write_repository")
        case .gitea:
            URL(string: "https://\(host)/user/settings/applications")
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
