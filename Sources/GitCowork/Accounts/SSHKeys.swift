import Foundation
import GitCoworkCore
import SystemConfiguration

struct SSHKeyError: LocalizedError {
    let message: String
    /// The token can't add keys; signing in again (or a new token) fixes it.
    var needsSignIn = false
    var errorDescription: String? { message }
}

/// "Create SSH Key…": makes the key, keeps its passphrase in the Keychain,
/// and adds the public key to the account on the host. If anything fails,
/// what this run made is removed again, so a half-made key is never used.
enum SSHKeys {
    static var sshDir: String { NSHomeDirectory() + "/.ssh" }

    /// Where the next key for this account will go.
    static func plannedPath(for account: HostAccount) -> String? {
        SSHKey.newKeyPath(sshDir: sshDir, host: account.host, exists: FileManager.default.fileExists(atPath:))
    }

    /// Returns the private key's path once the host has the public key.
    static func create(for account: HostAccount) async throws -> String {
        guard let token = await Credentials.shared.accessToken(for: account) else {
            throw SSHKeyError(message: String(localized: "No token for \(account.host) in the Keychain. Sign in again."), needsSignIn: true)
        }
        guard ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] != nil else {
            throw SSHKeyError(message: L("macOS's ssh-agent isn't available, so the key's passphrase can't be put in the Keychain."))
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
        let keygen = await run("/usr/bin/ssh-keygen", SSHKey.keygenArgs(path: path, comment: comment),
                               input: SSHKey.passphraseInput(passphrase, times: 2))
        guard keygen.status == 0, let publicKey = try? String(contentsOfFile: path + ".pub", encoding: .utf8) else {
            if keygen.status == 0 { removeFiles(path) }   // never delete a file ssh-keygen refused to replace
            throw SSHKeyError(message: String(localized: "ssh-keygen failed: \(keygen.stderr.isEmpty ? "exit \(keygen.status)" : keygen.stderr)"))
        }

        do {
            // 2. Passphrase into the Keychain, where ssh's UseKeychain finds it.
            //    ssh-add also loads the key into the agent; take it out again so
            //    ssh in the terminal doesn't start offering it to every server.
            let add = await run("/usr/bin/ssh-add", ["--apple-use-keychain", path],
                                input: SSHKey.passphraseInput(passphrase, times: 1))
            guard add.status == 0 else {
                throw SSHKeyError(message: String(localized: "Couldn't put the key's passphrase in the Keychain: \(add.stderr)"))
            }
            _ = await run("/usr/bin/ssh-add", ["-d", path], input: Data())

            // 3. Add the public key to the account.
            try await upload(publicKey, for: account, token: token)
            return path
        } catch {
            _ = await run("/usr/bin/ssh-add", ["--apple-use-keychain", "-d", path], input: Data())
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
                : String(localized: "Make a new token with the scopes \(HostAPI.tokenScopesHint(kind: account.kind)) and add it with Add Token.")
            throw SSHKeyError(message: String(localized: "Your sign-in on \(account.host) isn't allowed to add SSH keys (needs the \(scope) scope).") + " " + fix,
                              needsSignIn: true)
        case .signedOut:
            throw SSHKeyError(message: String(localized: "\(account.host) no longer accepts your sign-in. Sign in again."), needsSignIn: true)
        case .failed(let reason):
            throw SSHKeyError(message: String(localized: "\(account.host) didn't add the key: \(reason)"))
        }
    }

    private static var machineName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    private static func removeFiles(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + ".pub")
    }

    private static func run(_ tool: String, _ args: [String], input: Data) async -> (status: Int32, stderr: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: tool)
                p.arguments = args
                let inPipe = Pipe(), err = Pipe()
                p.standardInput = inPipe
                p.standardOutput = FileHandle.nullDevice
                p.standardError = err
                do { try p.run() } catch {
                    cont.resume(returning: (-1, error.localizedDescription))
                    return
                }
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                // Drop the passphrase prompts; they share a line with the real message.
                let stderr = String(decoding: errData, as: UTF8.self)
                    .replacingOccurrences(of: #"Enter (same )?passphrase[^:]*: "#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: (p.terminationStatus, stderr))
            }
        }
    }
}
