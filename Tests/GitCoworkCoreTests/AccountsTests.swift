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
        #expect(body == "client_id=abc&scope=repo%20workflow%20read%3Aorg")

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
}
