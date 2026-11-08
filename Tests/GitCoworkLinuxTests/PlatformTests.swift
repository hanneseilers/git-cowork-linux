import Foundation
import Testing
@testable import GitCoworkLinux
import GitCoworkCore

@Suite struct LocalizationTests {
    @Test func parsesStringsFiles() {
        let text = #"""
        /* comment */
        "Commit" = "Committen";
        // line comment
        "%@ into %@" = "%1$@ in %2$@";
        "Quote \"x\"\n" = "Zitat \"x\"\n";
        "Arrow" = "\U2192";
        """#
        let t = StringsFile.parse(text)
        #expect(t["Commit"] == "Committen")
        #expect(t["%@ into %@"] == "%1$@ in %2$@")
        #expect(t["Quote \"x\"\n"] == "Zitat \"x\"\n")
        #expect(t["Arrow"] == "→")
    }

    @Test func substitutesPlaceholders() {
        #expect(Localization.substitute("%@ failed", ["Push"]) == "Push failed")
        #expect(Localization.substitute("%2$@ before %1$@", ["a", "b"]) == "b before a")
        #expect(Localization.substitute("%lld ahead, %lld behind %@", ["3", "1", "main"]) == "3 ahead, 1 behind main")
        #expect(Localization.substitute("100%% done", []) == "100% done")
        #expect(Localization.substitute("%1$lld of %2$lld", ["1", "2"]) == "1 of 2")
    }

    @Test func picksLanguageFromEnvironment() {
        #expect(Localization.preferredLanguage(environment: ["LANG": "de_DE.UTF-8"]) == "de")
        #expect(Localization.preferredLanguage(environment: ["LANGUAGE": "fr:de", "LANG": "en_US.UTF-8"]) == "de")
        #expect(Localization.preferredLanguage(environment: ["LC_ALL": "C.UTF-8", "LANG": "de_DE.UTF-8"]) == "en")
        #expect(Localization.preferredLanguage(environment: ["GIT_COWORK_LANG": "en", "LANG": "de_DE.UTF-8"]) == "en")
        #expect(Localization.preferredLanguage(environment: [:]) == "en")
    }

    /// The shared German translations load and interpolated keys resolve.
    @Test func germanFromSharedResources() throws {
        let resources = try #require(AppResources.directory)
        let de = Localization(language: "de", resources: resources)
        #expect(de.translate("Commit") != "" )
        #expect(de.format("\("Push") failed") == "Push fehlgeschlagen")
        let en = Localization(language: "en", resources: resources)
        #expect(en.format("\("Push") failed") == "Push failed")
    }
}

@Suite struct ExternalTests {
    @Test func splitsCommands() {
        #expect(External.splitWords("code --new-window") == ["code", "--new-window"])
        #expect(External.splitWords(#"'/opt/My Editor/bin/ed' -w"#) == ["/opt/My Editor/bin/ed", "-w"])
        #expect(External.splitWords(#"a\ b "c d""#) == ["a b", "c d"])
        #expect(External.command(from: "Visual Studio Code") == ["code"])
        #expect(External.command(from: "Terminal") == nil)
        #expect(External.command(from: "  ") == nil)
    }
}

@Suite struct AskpassTests {
    @Test func readsKeyPathFromPrompt() {
        #expect(Askpass.keyPath(in: "Enter passphrase for key '/home/a/.ssh/git-cowork_github.com': ") == "/home/a/.ssh/git-cowork_github.com")
        #expect(Askpass.keyPath(in: "Are you sure you want to continue connecting (yes/no)?") == nil)
        #expect(Askpass.keyPath(in: "git@github.com's password: ") == nil)
        // Only ssh's exact format, not text that merely contains it (a server's prompt).
        #expect(Askpass.keyPath(in: "Server says: Enter passphrase for key '/home/a/.ssh/git-cowork_x': ") == nil)
        #expect(Askpass.keyPath(in: "Enter passphrase for key '/home/a/.ssh/git-cowork_x': extra") == nil)
        #expect(Askpass.keyPath(in: "Enter passphrase for key 'relative/git-cowork_x': ") == nil)
        #expect(Askpass.keyPath(in: "Enter passphrase for key '/" + String(repeating: "a", count: 99) + "': ") == nil)
    }

    @Test func onlyAnswersForAppKeys() {
        #expect(Askpass.isAppKey("/home/a/.ssh/git-cowork_github.com", sshDir: "/home/a/.ssh"))
        #expect(!Askpass.isAppKey("/home/a/.ssh/id_ed25519", sshDir: "/home/a/.ssh"))
        #expect(!Askpass.isAppKey("/tmp/git-cowork_x", sshDir: "/home/a/.ssh"))
        #expect(!Askpass.isAppKey("/home/a/.ssh/../x/git-cowork_x", sshDir: "/home/a/.ssh"))
    }
}

@Suite struct PrivateDirectoryTests {
    @Test func makesAPrivateFolderAndRefusesOthers() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gc-priv-\(UUID().uuidString.prefix(8))").path
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(atPath: base) }
        let dir = try #require(PrivateDirectory.app(environment: ["XDG_RUNTIME_DIR": base]))
        #expect(dir.path == base + "/git-cowork")
        let mode = try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)

        // Too open: tightened. A symlink in its place: refused.
        chmod(dir.path, 0o777)
        #expect(PrivateDirectory.ensurePrivate(dir.path))
        #expect((try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int) == 0o700)
        let link = base + "/link"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: dir.path)
        #expect(!PrivateDirectory.ensurePrivate(link))
    }

    @Test func sshConfigTurnsOffServerPrompts() {
        let config = SSHKey.appConfig(keys: [(host: "github.com", keyPath: "/home/a/.ssh/git-cowork_github.com")])
        let first = config.range(of: "KbdInteractiveAuthentication no")
        let include = config.range(of: "Include ~/.ssh/config")
        #expect(first != nil && include != nil && first!.lowerBound < include!.lowerBound)
        #expect(config.contains("PasswordAuthentication no"))
    }
}

@Suite struct FileWatcherTests {
    @Test func reportsChangesAndNewFolders() async throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gc-watch-\(UUID().uuidString.prefix(8))").path
        try fm.createDirectory(atPath: dir + "/a", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }

        let box = Collected()
        let watcher = FileWatcher(paths: [dir], latency: 0.05) { box.add($0) }
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try "x".write(toFile: dir + "/a/file.txt", atomically: false, encoding: .utf8)
        try await waitFor { box.paths.contains(dir + "/a/file.txt") }

        // A folder made after the watcher started is watched too.
        try fm.createDirectory(atPath: dir + "/b/c", withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(300))
        try "y".write(toFile: dir + "/b/c/deep.txt", atomically: false, encoding: .utf8)
        try await waitFor { box.paths.contains(dir + "/b/c/deep.txt") }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<50 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(condition())
    }
}

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths = Set<String>()
    var paths: Set<String> { lock.lock(); defer { lock.unlock() }; return _paths }
    func add(_ p: [String]) { lock.lock(); _paths.formUnion(p); lock.unlock() }
}

/// Needs a Secret Service (GNOME Keyring, KWallet). Skipped without one
/// (e.g. on CI without a D-Bus session); run Scripts/linux/e2e.sh for it.
@Suite struct KeychainTests {
    @Test func storesLooksUpAndClears() throws {
        let account = "test-\(UUID().uuidString.prefix(8))"
        guard Keychain.store("s3cret\nline", service: "git-cowork-test", account: account, label: "git-cowork test") else {
            print("No Secret Service available (\(Keychain.lastError ?? "?")); skipping")
            return
        }
        #expect(Keychain.lookup(service: "git-cowork-test", account: account) == "s3cret\nline")
        #expect(Keychain.lookup(service: "git-cowork-test", account: account + "x") == nil)
        Keychain.clear(service: "git-cowork-test", account: account)
        #expect(Keychain.lookup(service: "git-cowork-test", account: account) == nil)

        let tokens = Data(#"{"access":"tok"}"#.utf8)
        #expect(Keychain.save(tokens, host: "example.invalid"))
        #expect(Keychain.load(host: "example.invalid") == tokens)
        Keychain.delete(host: "example.invalid")
        #expect(Keychain.load(host: "example.invalid") == nil)
    }
}

/// The app as SSH_ASKPASS: given ssh's prompt for a key the app made, it
/// prints that key's passphrase from the Secret Service; for any other key
/// (even one with a stored passphrase) it answers nothing. Needs a Secret
/// Service; skipped without one. Scripts/linux/e2e.sh also logs in to a
/// local sshd this way.
@Suite struct AskpassEndToEndTests {
    @Test func answersOnlyForAppKeys() throws {
        let app = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("git-cowork-gtk").path
        guard FileManager.default.isExecutableFile(atPath: app) else { return }
        let id = UUID().uuidString.prefix(8)
        let key = SSHKeys.sshDir + "/git-cowork_askpass-test-\(id).invalid"
        let other = SSHKeys.sshDir + "/askpass-test-\(id)"
        let pass = SSHKey.newPassphrase()
        guard Keychain.store(pass, service: Keychain.sshService, account: key, label: "test key") else { return }
        defer { Keychain.clear(service: Keychain.sshService, account: key) }
        _ = Keychain.store(pass, service: Keychain.sshService, account: other, label: "test other")
        defer { Keychain.clear(service: Keychain.sshService, account: other) }

        var env = ProcessInfo.processInfo.environment
        env[Askpass.environmentFlag] = "1"
        let ok = try Subprocess.run(app, ["Enter passphrase for key '\(key)': "], environment: env, timeout: 30)
        #expect(ok.status == 0)
        #expect(String(decoding: ok.stdout, as: UTF8.self) == pass + "\n")
        let refused = try Subprocess.run(app, ["Enter passphrase for key '\(other)': "], environment: env, timeout: 30)
        #expect(refused.status != 0)
        #expect(refused.stdout.isEmpty)
        let hostKey = try Subprocess.run(app, ["Are you sure you want to continue connecting (yes/no/[fingerprint])?"], environment: env, timeout: 30)
        #expect(hostKey.status != 0)
    }
}

/// A pasted "URL" that looks like an option must not run anything.
@Suite struct CloneSafetyTests {
    @Test @MainActor func cloneDoesNotTakeOptionsFromTheURL() async throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gc-clone-\(UUID().uuidString.prefix(8))").path
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        let marker = dir + "/pwned"
        do {
            try await RepoModel.clone("--upload-pack=touch \(marker)", into: dir + "/dest")
        } catch {}
        #expect(!fm.fileExists(atPath: marker))
        #expect(CloneDialog.folderName(for: "--upload-pack=x") == "")
        #expect(CloneDialog.folderName(for: "https://example.com/org/repo.git/") == "repo")
        #expect(CloneDialog.folderName(for: "git@example.com:org/..") == "")
    }
}
