import Foundation
import Testing
@testable import GitCoworkCore

@Suite struct AutoFetchTests {
    private let opened = Date(timeIntervalSince1970: 1_000_000)

    private func conditions(_ change: (inout AutoFetch.Conditions) -> Void = { _ in }) -> AutoFetch.Conditions {
        var c = AutoFetch.Conditions(enabled: true, appActive: true, hasRemotes: true, actionRunning: false,
                                     pausedForSignIn: false, openedAt: opened, lastFetch: nil)
        change(&c)
        return c
    }

    @Test func firstFetchShortlyAfterOpening() {
        #expect(!AutoFetch.isDue(conditions(), now: opened))
        #expect(!AutoFetch.isDue(conditions(), now: opened + AutoFetch.firstDelay - 1))
        #expect(AutoFetch.isDue(conditions(), now: opened + AutoFetch.firstDelay))
    }

    @Test func thenEveryInterval() {
        let last = opened + 60
        let c = conditions { $0.lastFetch = last }
        #expect(!AutoFetch.isDue(c, now: last + AutoFetch.interval - 1))
        #expect(AutoFetch.isDue(c, now: last + AutoFetch.interval))
    }

    @Test func recentFetchBeforeOpeningCounts() {
        // Fetched in the terminal a minute before the window opened: no extra fetch.
        let c = conditions { $0.lastFetch = opened - 60 }
        #expect(!AutoFetch.isDue(c, now: opened + AutoFetch.firstDelay))
        #expect(AutoFetch.isDue(c, now: opened - 60 + AutoFetch.interval))
    }

    @Test func blockers() {
        let later = opened + AutoFetch.interval * 10
        #expect(!AutoFetch.isDue(conditions { $0.enabled = false }, now: later))
        #expect(!AutoFetch.isDue(conditions { $0.appActive = false }, now: later))
        #expect(!AutoFetch.isDue(conditions { $0.hasRemotes = false }, now: later))
        #expect(!AutoFetch.isDue(conditions { $0.actionRunning = true }, now: later))
        #expect(!AutoFetch.isDue(conditions { $0.pausedForSignIn = true }, now: later))
        #expect(AutoFetch.isDue(conditions(), now: later))
    }

    @Test func classifiesSignInFailures() {
        let cases = [
            "fatal: could not read Username for 'https://gitlab.example.de': terminal prompts disabled",
            "remote: HTTP Basic: Access denied\nfatal: Authentication failed for 'https://gitlab.example.de/team/app.git/'",
            "git@gitea.example.de: Permission denied (publickey).\nfatal: Could not read from remote repository.",
            "fatal: unable to access 'https://git.example.de/x.git/': The requested URL returned error: 403",
            "Host key verification failed.\nfatal: Could not read from remote repository.",
        ]
        for c in cases { #expect(AutoFetch.classify(c) == .signIn, "\(c)") }
    }

    @Test func classifiesNetworkFailures() {
        let cases = [
            "fatal: unable to access 'https://github.com/a/b.git/': Could not resolve host: github.com",
            "ssh: connect to host gitlab.example.de port 22: Operation timed out",
            "ssh: Could not resolve hostname gitea.local: nodename nor servname provided, or not known",
            "fatal: unable to access 'https://x/': Failed to connect to x port 443: Connection refused",
        ]
        for c in cases { #expect(AutoFetch.classify(c) == .network, "\(c)") }
    }

    @Test func otherFailures() {
        #expect(AutoFetch.classify("fatal: 'upstream' does not appear to be a git repository") == .other)
    }
}
