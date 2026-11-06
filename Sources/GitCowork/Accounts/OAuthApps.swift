import Foundation

/// Client IDs of the OAuth apps git-cowork signs in with. They are public by
/// design: the device flow needs no client secret.
///
/// To fill these in, register an OAuth app on github.com (Settings > Developer
/// settings > OAuth Apps, tick "Enable Device Flow") and on gitlab.com (User
/// settings > Applications, untick "Confidential", allow the device code
/// grant, scopes read_user, read_api, write_repository). Until then, sign-in
/// asks for a client ID or a token.
enum OAuthApps {
    static let builtIn: [String: String] = [
        "github.com": "",
        "gitlab.com": "",
    ]

    private static func key(_ host: String) -> String { "oauth.clientID.\(host)" }

    /// Client ID for a host: one the user entered (self-hosted servers), else the built-in one.
    static func clientID(for host: String) -> String? {
        let saved = UserDefaults.standard.string(forKey: key(host)) ?? ""
        if !saved.isEmpty { return saved }
        let builtIn = builtIn[host] ?? ""
        return builtIn.isEmpty ? nil : builtIn
    }

    static func hasBuiltIn(_ host: String) -> Bool { !(builtIn[host] ?? "").isEmpty }

    /// Remembers a client ID the user entered, so token refresh works later.
    static func save(_ clientID: String, for host: String) {
        guard !hasBuiltIn(host) || builtIn[host] != clientID else { return }
        UserDefaults.standard.set(clientID, forKey: key(host))
    }
}
