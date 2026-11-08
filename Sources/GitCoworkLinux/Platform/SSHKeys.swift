import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GitCoworkCore

struct SSHKeyError: LocalizedError {
    let message: String
    /// The token can't add keys; signing in again (or a new token) fixes it.
    var needsSignIn = false
    var errorDescription: String? { message }
}

/// "Create SSH Key…" on Linux: makes the key, keeps its random passphrase in
/// the Secret Service, and adds the public key to the account on the host.
/// The app's git commands get the passphrase through its askpass helper
/// (see Askpass). If anything fails, what this run made is removed again.
enum SSHKeys {
    static var sshDir: String { NSHomeDirectory() + "/.ssh" }

    static func plannedPath(for account: HostAccount) -> String? {
        SSHKey.newKeyPath(sshDir: sshDir, host: account.host, exists: FileManager.default.fileExists(atPath:))
    }

    static func create(for account: HostAccount) async throws -> String {
        guard let token = await Credentials.shared.accessToken(for: account) else {
            throw SSHKeyError(message: String(localized: "No token for \(account.host) in the Keychain. Sign in again."), needsSignIn: true)
        }
        guard let keygen = Subprocess.which("ssh-keygen", path: "/usr/bin:/bin:/usr/local/bin") else {
            throw SSHKeyError(message: L("ssh-keygen isn't installed. Install the openssh-client package."))
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: sshDir) {
            try? fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard let path = plannedPath(for: account) else {
            throw SSHKeyError(message: L("Couldn't find a free file name for the key in ~/.ssh."))
        }

        // 1. Make the key. ssh-keygen won't replace a file that appeared meanwhile.
        let passphrase = SSHKey.newPassphrase()
        let comment = "\(account.username)@\(SSHKey.sshHost(account.host)) git-cowork"
        let made = await run(keygen, SSHKey.keygenArgs(path: path, comment: comment),
                             input: SSHKey.passphraseInput(passphrase, times: 2))
        guard made.status == 0, let publicKey = try? String(contentsOfFile: path + ".pub", encoding: .utf8) else {
            if made.status == 0 { removeFiles(path) }
            throw SSHKeyError(message: String(localized: "ssh-keygen failed: \(made.stderr.isEmpty ? "exit \(made.status)" : made.stderr)"))
        }

        do {
            // 2. Passphrase into the Secret Service, where the askpass helper finds it.
            guard Keychain.store(passphrase, service: Keychain.sshService, account: path,
                                 label: "git-cowork SSH key: \((path as NSString).lastPathComponent)") else {
                throw SSHKeyError(message: String(localized: "Couldn't put the key's passphrase in the Keychain: \(Keychain.lastError ?? L("no Secret Service (GNOME Keyring or KWallet) is running"))"))
            }
            // 3. Add the public key to the account.
            try await upload(publicKey, for: account, token: token)
            return path
        } catch {
            Keychain.clear(service: Keychain.sshService, account: path)
            removeFiles(path)
            throw error
        }
    }

    private static func upload(_ publicKey: String, for account: HostAccount, token: String) async throws {
        guard let request = HostAPI.addSSHKeyRequest(kind: account.kind, host: account.host, token: token,
                                                     title: SSHKey.title(machine: machineName), publicKey: publicKey)
        else { throw SSHKeyError(message: String(localized: "\(account.kind.title) servers can't take an SSH key from git-cowork.")) }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SSHKeyError(message: String(localized: "Couldn't reach \(account.host): \(error.localizedDescription)"))
        }
        let http = response as? HTTPURLResponse
        let result = HostAPI.parseAddSSHKey(status: http?.statusCode ?? 0, data: data, kind: account.kind,
                                            grantedScopes: http?.value(forHTTPHeaderField: "X-OAuth-Scopes"))
        switch result {
        case .added:
            return
        case .missingScope:
            let scope = account.kind == .github ? "write:public_key" : "api"
            let fix = account.method == .oauth
                ? L("Sign in again to allow it.")
                : String(localized: "Make a new token with the scopes \(account.kind.scopesHint) and add it with Add Token.")
            throw SSHKeyError(message: String(localized: "Your sign-in on \(account.host) isn't allowed to add SSH keys (needs the \(scope) scope).") + " " + fix,
                              needsSignIn: true)
        case .signedOut:
            throw SSHKeyError(message: String(localized: "\(account.host) no longer accepts your sign-in. Sign in again."), needsSignIn: true)
        case .failed(let reason):
            throw SSHKeyError(message: String(localized: "\(account.host) didn't add the key: \(reason)"))
        }
    }

    static var machineName: String {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return "Linux" }
        let name = String(cString: buf)
        return name.isEmpty ? "Linux" : name
    }

    private static func removeFiles(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + ".pub")
    }

    private static func run(_ tool: String, _ args: [String], input: Data) async -> (status: Int32, stderr: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let r = try? Subprocess.run(tool, args, input: input, timeout: 60) else {
                    cont.resume(returning: (-1, "\(tool) couldn't start"))
                    return
                }
                let stderr = String(decoding: r.stderr, as: UTF8.self)
                    .replacingOccurrences(of: #"Enter (same )?passphrase[^:]*: "#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: (r.status, stderr))
            }
        }
    }
}

/// The app is its own SSH_ASKPASS: ssh runs it with the prompt as the only
/// argument, and it answers with the stored passphrase of a key made under
/// Settings › Accounts. Any other prompt (other keys, host key questions,
/// passwords) gets no answer, exactly as without a terminal.
enum Askpass {
    static let environmentFlag = "GIT_COWORK_ASKPASS"

    /// Handles an askpass call and exits; returns if this isn't one.
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env[environmentFlag] == "1" else { return }
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
        guard let path = keyPath(in: prompt), isAppKey(path),
              let passphrase = Keychain.lookup(service: Keychain.sshService, account: path) else {
            exit(1)
        }
        FileHandle.standardOutput.write(Data((passphrase + "\n").utf8))
        exit(0)
    }

    /// The key file named in ssh's own prompt, exactly "Enter passphrase for key '<path>': ".
    /// ssh cuts paths at 100 characters (%.100s), so a 100-character path may be
    /// cut short and is refused.
    static func keyPath(in prompt: String) -> String? {
        let prefix = "Enter passphrase for key '", suffix = "': "
        guard prompt.hasPrefix(prefix), prompt.hasSuffix(suffix), prompt.count > prefix.count + suffix.count else { return nil }
        let path = String(prompt.dropFirst(prefix.count).dropLast(suffix.count))
        guard path.hasPrefix("/"), path.count < 100, !path.contains("'"), !path.contains("\n") else { return nil }
        return path
    }

    /// Only keys git-cowork made (in ~/.ssh, named git-cowork_<host>).
    static func isAppKey(_ path: String, sshDir: String = SSHKeys.sshDir) -> Bool {
        let resolved = (path as NSString).standardizingPath
        return (resolved as NSString).deletingLastPathComponent == (sshDir as NSString).standardizingPath
            && (resolved as NSString).lastPathComponent.hasPrefix("git-cowork_")
    }
}

extension Credentials {
    /// Environment that lets ssh ask the app for its keys' passphrases.
    var sshAskpassEnvironment: [String: String] {
        ["SSH_ASKPASS": AppResources.executablePath,
         "SSH_ASKPASS_REQUIRE": "force",
         Askpass.environmentFlag: "1"]
    }
}
