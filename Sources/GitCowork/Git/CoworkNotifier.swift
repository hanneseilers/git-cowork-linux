import AppKit
import Foundation
import GitCoworkCore
import UserNotifications

/// Shows a macOS notification for new inbox items (assigned to me, review
/// requests, @mentions, verdicts, comments on my things). Remembers what was
/// already shown per repository, so each item notifies once.
@MainActor
final class CoworkNotifier {
    static let shared = CoworkNotifier()

    private var authorized = false
    private var asked = false
    /// Notifications need an app bundle; `swift run` builds have none.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

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
        // Oldest first, so trimming drops the oldest IDs.
        UserDefaults.standard.set(Array((stored + fresh.map(\.id)).suffix(2000)), forKey: key)
        guard available else { return }

        Task {
            guard await requestAuthorization() else { return }
            for item in fresh.prefix(5) {
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.subtitle = repoName
                content.body = item.detail
                content.threadIdentifier = item.target
                let request = UNNotificationRequest(identifier: item.id, content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(request)
            }
        }
    }

    private func requestAuthorization() async -> Bool {
        if asked { return authorized }
        asked = true
        authorized = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        return authorized
    }
}
