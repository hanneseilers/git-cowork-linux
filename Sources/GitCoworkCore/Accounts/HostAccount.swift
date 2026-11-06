import Foundation

/// A signed-in account on one host. One account per host, so git knows which
/// token to use for `https://<host>`. The token itself lives in the Keychain.
public struct HostAccount: Codable, Hashable, Sendable, Identifiable {
    public enum Method: String, Codable, Sendable {
        case oauth   // browser sign-in
        case token   // pasted personal access token
    }

    public var host: String       // lowercased, may include a port: "git.example.com:8443"
    public var kind: HostKind
    public var username: String
    public var method: Method
    /// Private key made by "Create SSH Key…" and added to this account on the
    /// host. Nil when there is none (older saved accounts have no such field).
    public var sshKey: String?

    public var id: String { host }

    public init(host: String, kind: HostKind, username: String, method: Method, sshKey: String? = nil) {
        self.host = host.lowercased()
        self.kind = kind
        self.username = username
        self.method = method
        self.sshKey = sshKey
    }

    /// GitHub and GitLab can take an SSH key through their API.
    public var canAddSSHKey: Bool { kind != .gitea }

    /// Username git sends over HTTPS. GitLab wants "oauth2" with OAuth tokens;
    /// everywhere else the account name works with the token as password.
    public var gitUsername: String {
        kind == .gitlab && method == .oauth ? "oauth2" : username
    }

    /// Accepts "github.com", "https://gitlab.example.com/", "Git.Example.com:8443".
    /// Returns nil for anything that isn't a plain host name (with optional port).
    public static func normalizeHost(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        while s.hasSuffix("/") { s.removeLast() }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-:")
        guard !s.isEmpty, s.allSatisfy(allowed.contains), !s.hasPrefix("."), !s.hasPrefix("-"), !s.hasPrefix(":") else { return nil }
        return s
    }
}

/// An access token and, for hosts whose tokens expire (GitLab), how to renew it.
public struct TokenSet: Codable, Hashable, Sendable {
    public var access: String
    public var refresh: String?
    public var expiresAt: Date?

    public init(access: String, refresh: String? = nil, expiresAt: Date? = nil) {
        self.access = access
        self.refresh = refresh
        self.expiresAt = expiresAt
    }

    /// True when the token runs out within `margin` seconds.
    public func expiresSoon(now: Date = .now, margin: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < margin
    }
}
