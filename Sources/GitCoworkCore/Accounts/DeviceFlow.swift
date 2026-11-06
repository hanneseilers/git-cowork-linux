import Foundation

/// OAuth device flow (RFC 8628), the sign-in GitHub and GitLab offer for apps
/// that can't keep a secret: the app shows a short code, the user approves it
/// in the browser, and the app polls until a token arrives.
public enum DeviceFlow {
    /// What the user types (or confirms) in the browser.
    public struct Code: Hashable, Sendable {
        public let deviceCode: String
        public let userCode: String
        public let verificationURL: URL
        /// Same page with the code already filled in, when the host offers one.
        public let verificationURLComplete: URL?
        public let expiresIn: TimeInterval
        public let interval: TimeInterval
    }

    public enum Poll: Equatable, Sendable {
        case token(TokenSet)
        case pending        // not approved yet, ask again after `interval`
        case slowDown       // asked too often, add 5 s to the interval
        case denied
        case expired
        case failed(String)
    }

    /// Scopes asked for at sign-in. GitHub needs `workflow` to push changes to
    /// .github/workflows; `read:org` lists org repos later; `write:public_key`
    /// adds an SSH key. GitLab has no scope narrower than `api` that can add
    /// an SSH key (and creating merge requests needs it too).
    public static func scopes(_ kind: HostKind) -> String {
        switch kind {
        case .github: "repo workflow read:org write:public_key"
        case .gitlab: "read_user api write_repository"
        case .gitea: ""
        }
    }

    /// Device flow is built in on GitHub, and on GitLab since 17.3 (on by
    /// default; flag removed in 17.9). Older GitLab servers, Gitea and Forgejo
    /// use a pasted token.
    public static func isSupported(_ kind: HostKind) -> Bool { kind != .gitea }

    private static func endpoints(_ kind: HostKind, host: String) -> (code: String, token: String) {
        switch kind {
        case .github: ("https://\(host)/login/device/code", "https://\(host)/login/oauth/access_token")
        case .gitlab, .gitea: ("https://\(host)/oauth/authorize_device", "https://\(host)/oauth/token")
        }
    }

    public static func codeRequest(kind: HostKind, host: String, clientID: String) -> URLRequest? {
        form(endpoints(kind, host: host).code, ["client_id": clientID, "scope": scopes(kind)])
    }

    public static func tokenRequest(kind: HostKind, host: String, clientID: String, deviceCode: String) -> URLRequest? {
        form(endpoints(kind, host: host).token, [
            "client_id": clientID,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
    }

    /// Renews an expiring token (GitLab tokens last two hours).
    public static func refreshRequest(kind: HostKind, host: String, clientID: String, refreshToken: String) -> URLRequest? {
        form(endpoints(kind, host: host).token, [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
    }

    public static func parseCode(_ data: Data) -> Code? {
        guard let obj = json(data),
              let device = obj["device_code"] as? String, !device.isEmpty,
              let user = obj["user_code"] as? String, !user.isEmpty,
              let uri = (obj["verification_uri"] as? String).flatMap(URL.init(string:)),
              uri.scheme == "https"
        else { return nil }
        let complete = (obj["verification_uri_complete"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return Code(deviceCode: device, userCode: user, verificationURL: uri, verificationURLComplete: complete,
                    expiresIn: number(obj["expires_in"]) ?? 900, interval: max(number(obj["interval"]) ?? 5, 1))
    }

    /// Reads a token poll answer. GitHub replies 200 with an `error` field,
    /// GitLab replies 400; both are read from the body.
    public static func parsePoll(_ data: Data, now: Date = .now) -> Poll {
        guard let obj = json(data) else { return .failed("The server sent an answer git-cowork can't read.") }
        if let access = obj["access_token"] as? String, !access.isEmpty {
            let expires = number(obj["expires_in"]).map { now.addingTimeInterval($0) }
            let refresh = (obj["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .token(TokenSet(access: access, refresh: refresh, expiresAt: expires))
        }
        switch obj["error"] as? String {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": return .denied
        case "expired_token": return .expired
        case let error?:
            let detail = obj["error_description"] as? String
            return .failed(detail.map { "\($0) (\(error))" } ?? error)
        case nil:
            return .failed("The server sent no token.")
        }
    }

    // MARK: Helpers

    static func form(_ urlString: String, _ fields: [String: String]) -> URLRequest? {
        guard let url = URL(string: urlString) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")   // GitHub answers form-encoded otherwise
        r.httpBody = Data(formEncode(fields).utf8)
        r.timeoutInterval = 20
        return r
    }

    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }.map { key, value in
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(v)"
        }.joined(separator: "&")
    }

    private static func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func number(_ value: Any?) -> TimeInterval? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return TimeInterval(s) }
        return nil
    }
}
