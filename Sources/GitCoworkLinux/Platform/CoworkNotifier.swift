import Foundation
import GitCoworkCore

/// Shows a desktop notification for new inbox items (assigned to me, review
/// requests, @mentions, verdicts, comments on my things). Remembers what was
/// already shown per repository, so each item notifies once. Same behaviour
/// and storage keys as the macOS notifier; delivery goes through
/// GNotification (set up by the GTK app in `send`).
@MainActor
final class CoworkNotifier {
    static let shared = CoworkNotifier()

    /// (id, title, body, target repo path). Set by the app; nil in tests.
    var send: ((String, String, String, String) -> Void)?

    private func seenKey(_ repo: String) -> String { "cowork.seen." + repo }

    func seen(repo: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: seenKey(repo)) ?? [])
    }

    /// Remembers `ids` as seen. Stored oldest first, so trimming drops the oldest.
    func markSeen(_ ids: [String], repo: String) {
        var list = UserDefaults.standard.stringArray(forKey: seenKey(repo)) ?? []
        let known = Set(list)
        let new = ids.filter { !known.contains($0) }
        guard !new.isEmpty else { return }
        list += new
        UserDefaults.standard.set(Array(list.suffix(2000)), forKey: seenKey(repo))
    }

    /// Unseen items, for badges in the UI.
    func unseen(_ items: [InboxItem], repo: String) -> [InboxItem] {
        let s = seen(repo: repo)
        return items.filter { !s.contains($0.id) }
    }

    func deliver(_ items: [InboxItem], repo: String, repoName: String) {
        let key = "cowork.notified." + repo
        let stored = UserDefaults.standard.stringArray(forKey: key)
        // First time we see a repo: remember everything (even nothing), don't flood.
        guard let stored else {
            UserDefaults.standard.set(items.map(\.id), forKey: key)
            return
        }
        let notified = Set(stored)
        let fresh = items.filter { !notified.contains($0.id) }
        guard !fresh.isEmpty else { return }
        UserDefaults.standard.set(Array((stored + fresh.map(\.id)).suffix(2000)), forKey: key)
        guard let send else { return }
        for item in fresh.prefix(5) {
            send(item.id, item.title, repoName + "\n" + item.detail, repo)
        }
    }
}
