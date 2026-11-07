import Foundation
import Testing
@testable import GitCoworkCore

@Suite struct AccountsTests {
    // MARK: Hosts and accounts

    @Test func normalizesHosts() {
        #expect(HostAccount.normalizeHost("github.com") == "github.com")
        #expect(HostAccount.normalizeHost(" https://GitLab.Example.com/ ") == "gitlab.example.com")
        #expect(HostAccount.normalizeHost("git.example.com:8443") == "git.example.com:8443")
        #expect(HostAccount.normalizeHost("") == nil)
        #expect(HostAccount.normalizeHost("evil.com/path") == nil)
        #expect(HostAccount.normalizeHost("a.com\n[core]") == nil)
        #expect(HostAccount.normalizeHost("a b.com") == nil)
    }

    @Test func gitUsername() {
        #expect(HostAccount(host: "gitlab.com", kind: .gitlab, username: "anna", method: .oauth).gitUsername == "oauth2")
        #expect(HostAccount(host: "gitlab.com", kind: .gitlab, username: "anna", method: .token).gitUsername == "anna")
        #expect(HostAccount(host: "github.com", kind: .github, username: "octo", method: .oauth).gitUsername == "octo")
    }

    @Test func tokenExpiry() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(!TokenSet(access: "a").expiresSoon(now: now))
        #expect(TokenSet(access: "a", expiresAt: now.addingTimeInterval(60)).expiresSoon(now: now))
        #expect(!TokenSet(access: "a", expiresAt: now.addingTimeInterval(3600)).expiresSoon(now: now))
    }

    // MARK: Host API

    @Test func apiBases() {
        #expect(HostAPI.apiBase(kind: .github, host: "github.com") == "https://api.github.com")
        #expect(HostAPI.apiBase(kind: .github, host: "ghe.corp.com") == "https://ghe.corp.com/api/v3")
        #expect(HostAPI.apiBase(kind: .gitlab, host: "gitlab.com") == "https://gitlab.com/api/v4")
        #expect(HostAPI.apiBase(kind: .gitea, host: "codeberg.org") == "https://codeberg.org/api/v1")
    }

    @Test func currentUserRequest() throws {
        let gh = try #require(HostAPI.currentUserRequest(kind: .github, host: "github.com", token: "t1"))
        #expect(gh.url?.absoluteString == "https://api.github.com/user")
        #expect(gh.value(forHTTPHeaderField: "Authorization") == "Bearer t1")
        let gitea = try #require(HostAPI.currentUserRequest(kind: .gitea, host: "codeberg.org", token: "t2"))
        #expect(gitea.value(forHTTPHeaderField: "Authorization") == "token t2")
    }

    @Test func parsesUsernames() {
        #expect(HostAPI.parseUsername(Data(#"{"login":"octo","id":1}"#.utf8), kind: .github) == "octo")
        #expect(HostAPI.parseUsername(Data(#"{"username":"anna","name":"Anna"}"#.utf8), kind: .gitlab) == "anna")
        #expect(HostAPI.parseUsername(Data(#"{"message":"Bad credentials"}"#.utf8), kind: .github) == nil)
        #expect(HostAPI.parseUsername(Data("not json".utf8), kind: .gitea) == nil)
    }

    // MARK: Device flow

    @Test func codeRequestIsForm() throws {
        let r = try #require(DeviceFlow.codeRequest(kind: .github, host: "github.com", clientID: "abc"))
        #expect(r.url?.absoluteString == "https://github.com/login/device/code")
        #expect(r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "Accept") == "application/json")
        let body = String(decoding: r.httpBody ?? Data(), as: UTF8.self)
        #expect(body == "client_id=abc&scope=repo%20workflow%20read%3Aorg%20write%3Apublic_key")

        let gl = try #require(DeviceFlow.tokenRequest(kind: .gitlab, host: "gitlab.com", clientID: "c", deviceCode: "d"))
        #expect(gl.url?.absoluteString == "https://gitlab.com/oauth/token")
        #expect(String(decoding: gl.httpBody ?? Data(), as: UTF8.self)
                == "client_id=c&device_code=d&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code")
    }

    @Test func parsesDeviceCode() throws {
        let json = #"""
        {"device_code":"dev","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device",
         "expires_in":899,"interval":5}
        """#
        let code = try #require(DeviceFlow.parseCode(Data(json.utf8)))
        #expect(code.userCode == "WDJB-MJHT")
        #expect(code.verificationURL.absoluteString == "https://github.com/login/device")
        #expect(code.verificationURLComplete == nil)
        #expect(code.interval == 5)
        #expect(code.expiresIn == 899)
    }

    @Test func rejectsNonHTTPSVerificationPage() {
        let json = #"{"device_code":"d","user_code":"u","verification_uri":"javascript:alert(1)"}"#
        #expect(DeviceFlow.parseCode(Data(json.utf8)) == nil)
        #expect(DeviceFlow.parseCode(Data(#"{"error":"invalid_client"}"#.utf8)) == nil)
    }

    @Test func parsesPollAnswers() {
        let now = Date(timeIntervalSince1970: 0)
        func poll(_ s: String) -> DeviceFlow.Poll { DeviceFlow.parsePoll(Data(s.utf8), now: now) }

        #expect(poll(#"{"access_token":"gho_x","token_type":"bearer","scope":"repo"}"#) == .token(TokenSet(access: "gho_x")))
        #expect(poll(#"{"access_token":"a","refresh_token":"r","expires_in":7200}"#)
                == .token(TokenSet(access: "a", refresh: "r", expiresAt: Date(timeIntervalSince1970: 7200))))
        #expect(poll(#"{"error":"authorization_pending"}"#) == .pending)
        #expect(poll(#"{"error":"slow_down","interval":10}"#) == .slowDown)
        #expect(poll(#"{"error":"access_denied"}"#) == .denied)
        #expect(poll(#"{"error":"expired_token"}"#) == .expired)
        #expect(poll(#"{"error":"invalid_client","error_description":"Unknown client"}"#) == .failed("Unknown client (invalid_client)"))
        if case .failed = poll("<html>") {} else { Issue.record("HTML should fail") }
    }

    // MARK: Credential config

    @Test func configArgsResetThenCache() {
        let args = CredentialConfig.configArgs(hosts: ["github.com", "bad host"], socketPath: "/tmp/it's/sock")
        #expect(args == [
            "-c", "credential.https://github.com.helper=",
            "-c", "credential.https://github.com.helper=cache --socket '/tmp/it'\\''s/sock'",
        ])
    }

    @Test func storeInputRejectsInjectedLines() throws {
        let ok = try #require(CredentialConfig.storeInput(host: "github.com", username: "octo", password: "t"))
        #expect(String(decoding: ok, as: UTF8.self) == "protocol=https\nhost=github.com\nusername=octo\npassword=t\n\n")
        #expect(CredentialConfig.storeInput(host: "github.com", username: "octo", password: "t\nhost=evil.com") == nil)
        #expect(CredentialConfig.storeInput(host: "github.com", username: "", password: "t") == nil)
        #expect(CredentialConfig.storeInput(host: "GitHub.com", username: "o", password: "t") == nil)
    }

    @Test func detectsNetworkCommands() {
        #expect(CredentialConfig.needsCredentials(["fetch", "--all", "--prune"]))
        #expect(CredentialConfig.needsCredentials(["push", "-u", "origin", "main"]))
        #expect(!CredentialConfig.needsCredentials(["status", "--porcelain=v2"]))
        #expect(!CredentialConfig.needsCredentials(["config", "--get", "remote.origin.push"]))
    }

    @Test func detectsAuthFailures() {
        #expect(CredentialConfig.isAuthFailure("fatal: could not read Username for 'https://github.com': terminal prompts disabled"))
        #expect(CredentialConfig.isAuthFailure("remote: HTTP Basic: Access denied\nfatal: Authentication failed for 'https://gitlab.com/a/b.git/'"))
        #expect(CredentialConfig.isAuthFailure("git@github.com: Permission denied (publickey)."))
        #expect(!CredentialConfig.isAuthFailure("error: failed to push some refs to 'origin'\nhint: Updates were rejected"))
    }

    /// The real thing: with the app's -c options, git takes the token from the
    /// cache for that host only, and never asks the system helper for it.
    @Test func gitUsesCacheForSignedInHostOnly() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("gc-cred-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let socket = dir.appendingPathComponent("sock").path

        func git(_ args: [String], input: Data) throws -> String {
            #if os(Linux)
            // Foundation's Process leaks a descriptor into the cache daemon; see Subprocess.
            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            let r = try Subprocess.run("/usr/bin/git", args, currentDirectory: dir.path, environment: env, input: input)
            return String(decoding: r.stdout, as: UTF8.self)
            #else
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = dir
            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            p.environment = env
            let inPipe = Pipe(), out = Pipe()
            p.standardInput = inPipe
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            inPipe.fileHandleForWriting.write(input)
            try inPipe.fileHandleForWriting.close()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
            #endif
        }

        let store = try #require(CredentialConfig.storeInput(host: "github.com", username: "octo", password: "tok-123"))
        _ = try git(["credential-cache", "--socket", socket, "--timeout", "60", "store"], input: store)
        defer { _ = try? git(["credential-cache", "--socket", socket, "exit"], input: Data()) }

        // A system helper that would leak if git asked it; it must never run.
        let leak = dir.appendingPathComponent("asked")
        let base = ["-c", "credential.helper=!touch '\(leak.path)'; true"]
        let args = base + CredentialConfig.configArgs(hosts: ["github.com"], socketPath: socket)

        let filled = try git(args + ["credential", "fill"], input: Data("protocol=https\nhost=github.com\n\n".utf8))
        #expect(filled.contains("username=octo"))
        #expect(filled.contains("password=tok-123"))
        #expect(!fm.fileExists(atPath: leak.path))

        // Another host still goes to the user's own helper.
        _ = try git(args + ["credential", "fill"], input: Data("protocol=https\nhost=example.invalid\n\n".utf8))
        #expect(fm.fileExists(atPath: leak.path))
    }

    // MARK: SSH key

    @Test func oldAccountsDecodeWithoutKey() throws {
        let json = #"{"host":"github.com","kind":"github","username":"octo","method":"oauth"}"#
        let account = try JSONDecoder().decode(HostAccount.self, from: Data(json.utf8))
        #expect(account.sshKey == nil)
        #expect(account.canAddSSHKey)
        #expect(!HostAccount(host: "codeberg.org", kind: .gitea, username: "a", method: .token).canAddSSHKey)
    }

    @Test func addSSHKeyRequests() throws {
        let gh = try #require(HostAPI.addSSHKeyRequest(kind: .github, host: "github.com", token: "t1",
                                                      title: "git-cowork on Mac", publicKey: "ssh-ed25519 AAAA c\n"))
        #expect(gh.url?.absoluteString == "https://api.github.com/user/keys")
        #expect(gh.httpMethod == "POST")
        #expect(gh.value(forHTTPHeaderField: "Authorization") == "Bearer t1")
        #expect(gh.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(String(decoding: gh.httpBody ?? Data(), as: UTF8.self)
                == #"{"key":"ssh-ed25519 AAAA c","title":"git-cowork on Mac"}"#)

        let gl = try #require(HostAPI.addSSHKeyRequest(kind: .gitlab, host: "gitlab.example.com", token: "t2",
                                                      title: "k", publicKey: "ssh-ed25519 BBBB"))
        #expect(gl.url?.absoluteString == "https://gitlab.example.com/api/v4/user/keys")
        #expect(String(decoding: gl.httpBody ?? Data(), as: UTF8.self)
                == #"{"key":"ssh-ed25519 BBBB","title":"k","usage_type":"auth"}"#)

        #expect(HostAPI.addSSHKeyRequest(kind: .gitea, host: "codeberg.org", token: "t", title: "k", publicKey: "k") == nil)
    }

    @Test func parsesAddSSHKeyAnswers() {
        func parse(_ status: Int, _ body: String, _ kind: HostKind = .github, scopes: String? = nil) -> HostAPI.AddKeyResult {
            HostAPI.parseAddSSHKey(status: status, data: Data(body.utf8), kind: kind, grantedScopes: scopes)
        }
        #expect(parse(201, #"{"id":1,"key":"ssh-ed25519 AAAA","title":"t"}"#) == .added)
        #expect(parse(401, #"{"message":"Bad credentials"}"#) == .signedOut)
        // GitHub: token from before write:public_key was asked for.
        #expect(parse(404, #"{"message":"Not Found"}"#, scopes: "read:org, repo, workflow") == .missingScope)
        #expect(parse(404, #"{"message":"Not Found"}"#, scopes: "repo, write:public_key") == .failed("Not Found"))
        #expect(parse(403, #"{"message":"Resource not accessible by personal access token"}"#) == .missingScope)
        #expect(parse(422, #"{"message":"Validation Failed","errors":[{"resource":"PublicKey","code":"custom","field":"key","message":"key is already in use"}]}"#)
                == .failed("key is already in use"))
        // GitLab
        #expect(parse(403, #"{"error":"insufficient_scope"}"#, .gitlab) == .missingScope)
        #expect(parse(400, #"{"message":{"fingerprint":["has already been taken"],"key":["has already been taken"]}}"#, .gitlab)
                == .failed("fingerprint has already been taken; key has already been taken"))
        #expect(parse(500, "oops", .gitlab) == .failed("HTTP 500"))
    }

    @Test func keyPaths() {
        #expect(SSHKey.sshHost("git.example.com:8443") == "git.example.com")
        let taken: Set<String> = ["/h/.ssh/git-cowork_github.com", "/h/.ssh/git-cowork_github.com_2.pub"]
        #expect(SSHKey.newKeyPath(sshDir: "/h/.ssh", host: "gitlab.com", exists: taken.contains) == "/h/.ssh/git-cowork_gitlab.com")
        #expect(SSHKey.newKeyPath(sshDir: "/h/.ssh", host: "github.com", exists: taken.contains) == "/h/.ssh/git-cowork_github.com_3")
        #expect(SSHKey.newKeyPath(sshDir: "/h/.ssh", host: "../x", exists: { _ in false }) == nil)
        #expect(SSHKey.newKeyPath(sshDir: "/h/.ssh", host: "a/b", exists: { _ in false }) == nil)
    }

    @Test func passphrases() {
        let a = SSHKey.newPassphrase(), b = SSHKey.newPassphrase()
        #expect(a != b)
        #expect(Data(base64Encoded: a)?.count == 32)
        #expect(SSHKey.passphraseInput("p", times: 2) == Data("p\np\n".utf8))
    }

    @Test func appConfigAndHostEntry() {
        let config = SSHKey.appConfig(keys: [(host: "gitlab.example.com:8443", keyPath: "/Users/a/.ssh/git-cowork_gitlab.example.com"),
                                             (host: "bad\nhost", keyPath: "/x")])
        #if os(macOS)
        #expect(config.contains("Host gitlab.example.com\n  IdentityFile \"/Users/a/.ssh/git-cowork_gitlab.example.com\"\n  IdentitiesOnly yes\n  UseKeychain yes\n"))
        #else
        #expect(config.contains("Host gitlab.example.com\n  IdentityFile \"/Users/a/.ssh/git-cowork_gitlab.example.com\"\n  IdentitiesOnly yes\n"))
        #expect(!config.contains("UseKeychain"))
        #endif
        #expect(!config.contains("bad"))
        #expect(config.hasSuffix("Host *\n  Include ~/.ssh/config\n  Include /etc/ssh/ssh_config\n"))

        let entry = SSHKey.hostEntry(host: "github.com", keyPath: "/Users/a/.ssh/git-cowork_github.com", home: "/Users/a")
        #if os(macOS)
        #expect(entry == """
            Host github.com
              IdentityFile "~/.ssh/git-cowork_github.com"
              IdentitiesOnly yes
              IgnoreUnknown UseKeychain
              UseKeychain yes

            """)
        #else
        #expect(entry == """
            Host github.com
              IdentityFile "~/.ssh/git-cowork_github.com"
              IdentitiesOnly yes

            """)
        #endif
        #expect(SSHKey.sshCommand(configPath: "/tmp/a b/ssh_config") == "/usr/bin/ssh -F '/tmp/a b/ssh_config'")
    }

    /// The real thing: ssh resolves the app config to our key for the signed-in
    /// host only, and the person's own config still applies to every host.
    @Test func sshUsesKeyForSignedInHostOnly() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("gc-ssh-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let key = dir.appendingPathComponent("git-cowork_github.com").path
        let user = dir.appendingPathComponent("user_config")
        try "Host github.com\n  HostName ssh.github.com\n  Port 443\nHost example.com\n  User bob\n".write(to: user, atomically: true, encoding: .utf8)
        let config = dir.appendingPathComponent("ssh_config")
        try SSHKey.appConfig(keys: [(host: "github.com", keyPath: key)], includes: [user.path]).write(to: config, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)

        func resolve(_ host: String) throws -> [String] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: SSHKey.sshPath)
            p.arguments = ["-F", config.path, "-G", host]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }

        let gh = try resolve("github.com")
        #expect(gh.first { $0.hasPrefix("identityfile ") } == "identityfile \(key)")
        #expect(gh.contains("identitiesonly yes"))
        #expect(gh.contains("hostname ssh.github.com"))   // the person's own settings still apply
        #expect(gh.contains("port 443"))

        let other = try resolve("example.com")
        #expect(!other.contains("identityfile \(key)"))
        #expect(other.contains("identitiesonly no"))
        #expect(other.contains("user bob"))
    }

    /// ssh-keygen takes the passphrase on stdin and won't replace a file.
    @Test func keygenReadsPassphraseFromStdin() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("gc-keygen-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let path = dir.appendingPathComponent("k").path
        let pass = SSHKey.newPassphrase()

        func run(_ tool: String, _ args: [String], input: Data) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let inPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            inPipe.fileHandleForWriting.write(input)
            try inPipe.fileHandleForWriting.close()
            p.waitUntilExit()
            return p.terminationStatus
        }

        let args = SSHKey.keygenArgs(path: path, comment: "test")
        #expect(try run("/usr/bin/ssh-keygen", args, input: SSHKey.passphraseInput(pass, times: 2)) == 0)
        #expect(try run("/usr/bin/ssh-keygen", ["-y", "-P", pass, "-f", path], input: Data()) == 0)
        #expect(try run("/usr/bin/ssh-keygen", ["-y", "-P", "", "-f", path], input: Data()) != 0)

        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(try run("/usr/bin/ssh-keygen", args, input: SSHKey.passphraseInput("other", times: 2)) != 0)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
    }
}
