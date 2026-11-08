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
    }

    @Test func onlyAnswersForAppKeys() {
        #expect(Askpass.isAppKey("/home/a/.ssh/git-cowork_github.com", sshDir: "/home/a/.ssh"))
        #expect(!Askpass.isAppKey("/home/a/.ssh/id_ed25519", sshDir: "/home/a/.ssh"))
        #expect(!Askpass.isAppKey("/tmp/git-cowork_x", sshDir: "/home/a/.ssh"))
        #expect(!Askpass.isAppKey("/home/a/.ssh/../x/git-cowork_x", sshDir: "/home/a/.ssh"))
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
