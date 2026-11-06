import Foundation

/// When to run the background `git fetch --all --prune`, and how to read its
/// failures. Pure logic so it can be tested without a window or a network.
public enum AutoFetch {
    /// Time between fetches while the app is in front.
    public static let interval: TimeInterval = 5 * 60
    /// First fetch after a window opens.
    public static let firstDelay: TimeInterval = 10
    /// How often the timer wakes up to check. Same tick as the task sync.
    public static let tick: TimeInterval = 30

    /// Everything the decision depends on, read fresh on every tick.
    public struct Conditions: Equatable {
        /// Settings › Fetch automatically.
        public var enabled: Bool
        /// The app is in front. Nothing runs in the background.
        public var appActive: Bool
        public var hasRemotes: Bool
        /// A git action the user started (fetch, pull, push, …) is running.
        public var actionRunning: Bool
        /// The last automatic fetch failed to sign in. Retrying every few
        /// minutes with the same wrong credentials can lock the account on
        /// servers with lockout rules, so wait until a fetch, pull or push
        /// the user starts succeeds.
        public var pausedForSignIn: Bool
        /// When the window opened.
        public var openedAt: Date
        /// Last fetch of this repository, automatic or not. nil: none yet.
        public var lastFetch: Date?

        public init(enabled: Bool, appActive: Bool, hasRemotes: Bool, actionRunning: Bool,
                    pausedForSignIn: Bool, openedAt: Date, lastFetch: Date?) {
            self.enabled = enabled
            self.appActive = appActive
            self.hasRemotes = hasRemotes
            self.actionRunning = actionRunning
            self.pausedForSignIn = pausedForSignIn
            self.openedAt = openedAt
            self.lastFetch = lastFetch
        }
    }

    public static func isDue(_ c: Conditions, now: Date) -> Bool {
        guard c.enabled, c.appActive, c.hasRemotes, !c.actionRunning, !c.pausedForSignIn else { return false }
        // A recent fetch from anywhere (toolbar, another window, the terminal)
        // counts, even if it came before this window opened.
        if let last = c.lastFetch { return now.timeIntervalSince(last) >= interval }
        return now.timeIntervalSince(c.openedAt) >= firstDelay
    }

    public enum Failure: Equatable {
        /// Credentials missing or rejected. Needs the user.
        case signIn
        /// Offline, DNS, timeouts. Goes away by itself.
        case network
        case other
    }

    /// Classifies a failed fetch by git's stderr. Messages are matched in
    /// English (the app runs git with LC_ALL=en_US.UTF-8).
    public static func classify(_ stderr: String) -> Failure {
        let s = stderr.lowercased()
        // Same list as the sign-in hint on errors, plus cases that need the
        // user just as much (unknown SSH host key, other servers' wording).
        let alsoSignIn = [
            "host key verification failed",
            "permission denied, please try again",
            "access denied",
            "returned error: 401",
            "returned error: 403",
        ]
        if CredentialConfig.isAuthFailure(stderr) || alsoSignIn.contains(where: s.contains) { return .signIn }
        let network = [
            "could not resolve host",
            "could not resolve hostname",
            "connection timed out",
            "operation timed out",
            "network is unreachable",
            "connection refused",
            "no route to host",
            "failed to connect",
            "connection reset",
            "unable to access",                 // generic curl failure, after the cases above
        ]
        if network.contains(where: s.contains) { return .network }
        return .other
    }
}
