import Foundation

/// The optional SSH key per signed-in account: where it lives, how
/// `ssh-keygen` makes it, and how the app's git commands (and only those)
/// use it.
///
/// The key is ed25519 with a random passphrase that `ssh-add
/// --apple-use-keychain` keeps in the login Keychain. Git runs
/// `/usr/bin/ssh -F <app config>`, where the app config gives each signed-in
/// host its key with `IdentitiesOnly yes` and then includes the person's own
/// `~/.ssh/config`, so every other host resolves exactly as in the terminal.
public enum SSHKey {
    /// Apple's ssh: it knows `UseKeychain`, which reads the passphrase.
    public static let sshPath = "/usr/bin/ssh"

    /// Host name SSH remotes use: an account's host without its HTTPS port.
    public static func sshHost(_ host: String) -> String {
        String(host.split(separator: ":", maxSplits: 1).first ?? Substring(host))
    }

    /// `<sshDir>/git-cowork_<host>`, or `…_2`, `…_3` when taken. Nil when a
    /// host name could escape the folder (normalized hosts never do).
    public static func newKeyPath(sshDir: String, host: String, exists: (String) -> Bool) -> String? {
        let name = sshHost(host)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
              !name.hasPrefix(".")
        else { return nil }
        let base = (sshDir as NSString).appendingPathComponent("git-cowork_\(name)")
        for n in 1...99 {
            let path = n == 1 ? base : "\(base)_\(n)"
            if !exists(path), !exists(path + ".pub") { return path }
        }
        return nil
    }

    /// Arguments for `ssh-keygen`. The passphrase comes on stdin (see
    /// `passphraseInput`), never on the command line where `ps` shows it.
    /// ssh-keygen asks before overwriting a file and reads the answer from
    /// stdin too, so an existing file is never replaced.
    public static func keygenArgs(path: String, comment: String) -> [String] {
        ["-q", "-t", "ed25519", "-C", comment, "-f", path]
    }

    /// stdin for ssh-keygen (asks twice) or ssh-add (asks once).
    public static func passphraseInput(_ passphrase: String, times: Int) -> Data {
        Data(String(repeating: passphrase + "\n", count: times).utf8)
    }

    /// 32 random bytes, base64. Nobody types it; it only keeps the key file
    /// encrypted on disk and in backups.
    public static func newPassphrase() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return Data(bytes).base64EncodedString()
    }

    /// Name shown in the host's list of SSH keys.
    public static func title(machine: String) -> String {
        "git-cowork on \(machine)"
    }

    /// The app's ssh config. First match wins in ssh, so these blocks come
    /// before the person's own config, which is included for everything else.
    public static func appConfig(keys: [(host: String, keyPath: String)],
                                 includes: [String] = ["~/.ssh/config", "/etc/ssh/ssh_config"]) -> String {
        var lines = ["# Written by git-cowork for its own git commands. Changes are overwritten.", ""]
        for key in keys {
            guard let block = hostBlock(host: key.host, identityFile: key.keyPath) else { continue }
            lines += block + [""]
        }
        #if os(Linux)
        // The app answers ssh's passphrase prompts itself (SSH_ASKPASS). A
        // server can send its own prompt text through keyboard-interactive
        // auth, so the app's ssh never offers it (or passwords): without a
        // terminal nobody could answer them anyway. First value wins in ssh,
        // so this comes before the person's own config.
        lines += ["Host *", "  KbdInteractiveAuthentication no", "  PasswordAuthentication no", ""]
        #endif
        lines.append("Host *")
        lines += includes.map { "  Include \($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `Host` entry for people who want ssh in the terminal to use the key
    /// too. Paths under the home folder are written with `~`.
    public static func hostEntry(host: String, keyPath: String, home: String) -> String? {
        var shown = keyPath
        if !home.isEmpty, keyPath.hasPrefix(home + "/") { shown = "~" + keyPath.dropFirst(home.count) }
        guard var block = hostBlock(host: host, identityFile: shown) else { return nil }
        #if os(macOS)
        // Other ssh builds (Homebrew) don't know UseKeychain and would refuse the file.
        block.insert("  IgnoreUnknown UseKeychain", at: block.count - 1)
        #endif
        return block.joined(separator: "\n") + "\n"
    }

    /// `GIT_SSH_COMMAND` value; git runs it through the shell.
    public static func sshCommand(configPath: String) -> String {
        sshPath + " -F " + CredentialConfig.shellQuote(configPath)
    }

    private static func hostBlock(host: String, identityFile: String) -> [String]? {
        let name = sshHost(host)
        guard HostAccount.normalizeHost(name) == name, !name.contains(":"),
              !identityFile.contains(where: { $0 == "\"" || $0 == "\n" || $0 == "\r" })
        else { return nil }
        // ssh expands %-tokens in IdentityFile.
        let file = identityFile.replacingOccurrences(of: "%", with: "%%")
        #if os(macOS)
        return ["Host \(name)",
                "  IdentityFile \"\(file)\"",
                "  IdentitiesOnly yes",
                "  UseKeychain yes"]
        #else
        // OpenSSH on Linux has no UseKeychain (and refuses unknown options);
        // the passphrase comes from the Secret Service through SSH_ASKPASS.
        return ["Host \(name)",
                "  IdentityFile \"\(file)\"",
                "  IdentitiesOnly yes"]
        #endif
    }
}
