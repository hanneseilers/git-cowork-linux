import Foundation

/// How the app hands tokens to git without touching the user's git config.
///
/// Tokens are kept in git's own `credential-cache` daemon, listening on a
/// socket only this user can reach. For each signed-in host, the app adds two
/// `-c` options to its git commands: an empty helper (which clears the helper
/// list for that host, so osxkeychain and friends neither answer nor store a
/// copy of our token) and the cache helper. Other hosts and SSH remotes are
/// untouched, and so is git in the terminal.
public enum CredentialConfig {
    /// `-c` options for git, one pair per host.
    public static func configArgs(hosts: [String], socketPath: String) -> [String] {
        let helper = "cache --socket " + shellQuote(socketPath)
        return hosts.compactMap(HostAccount.normalizeHost).flatMap { host in
            ["-c", "credential.https://\(host).helper=",
             "-c", "credential.https://\(host).helper=\(helper)"]
        }
    }

    /// Input for `git credential-cache store`. Nil when a value could smuggle in
    /// an extra line (git's credential format is one `key=value` per line).
    public static func storeInput(host: String, username: String, password: String) -> Data? {
        let values = [host, username, password]
        guard values.allSatisfy({ !$0.isEmpty && !$0.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) }),
              HostAccount.normalizeHost(host) == host
        else { return nil }
        return Data("protocol=https\nhost=\(host)\nusername=\(username)\npassword=\(password)\n\n".utf8)
    }

    /// Commands that may talk to a server and so need credentials ready.
    public static func needsCredentials(_ args: [String]) -> Bool {
        let network: Set<String> = ["fetch", "pull", "push", "clone", "ls-remote", "submodule"]
        return args.contains(where: network.contains)
    }

    /// Whether git's error output means the server wanted credentials it didn't get.
    public static func isAuthFailure(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return [
            "authentication failed",
            "could not read username",
            "could not read password",
            "terminal prompts disabled",
            "invalid username or password",
            "permission denied (publickey",
            "http basic: access denied",
            "the requested url returned error: 401",
            "the requested url returned error: 403",
        ].contains(where: s.contains)
    }

    /// Single-quotes a string for /bin/sh, which is how git runs helpers.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
