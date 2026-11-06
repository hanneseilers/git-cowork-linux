import Foundation

/// User settings, stored in UserDefaults. Views bind to the same keys with @AppStorage.
enum Prefs {
    enum Key {
        static let editorApp = "editorApp"
        static let terminalApp = "terminalApp"
        static let hostOverrides = "hostOverrides"
        static let recentRepos = "recentRepos"
        /// Remote that tasks and reviews (refs/cowork/main) sync with. Empty: the
        /// current branch's upstream remote, else origin.
        static let coworkRemote = "cowork.remote"
        /// Fetch/push refs/cowork/main about once a minute while the app is in front.
        static let coworkAutoSync = "cowork.autoSync"
    }

    static var editorApp: String { UserDefaults.standard.string(forKey: Key.editorApp) ?? "Visual Studio Code" }
    static var terminalApp: String { UserDefaults.standard.string(forKey: Key.terminalApp) ?? "Terminal" }
    static var hostOverrides: String { UserDefaults.standard.string(forKey: Key.hostOverrides) ?? "" }

    /// Remote name from Settings, or nil to use the default (upstream remote, else origin).
    static var coworkRemote: String? {
        let s = (UserDefaults.standard.string(forKey: Key.coworkRemote) ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    static var coworkAutoSync: Bool { UserDefaults.standard.object(forKey: Key.coworkAutoSync) as? Bool ?? true }

    static var recentRepos: [String] {
        get { UserDefaults.standard.stringArray(forKey: Key.recentRepos) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(20)), forKey: Key.recentRepos) }
    }

    /// Recent repositories worth showing: still on disk and not in a temporary
    /// folder (throwaway repos from scripts and test runs).
    static var visibleRecents: [String] {
        let temp = [NSTemporaryDirectory(), "/tmp/", "/private/tmp/", "/private/var/folders/", "/var/folders/"]
        return recentRepos.filter { path in
            FileManager.default.fileExists(atPath: path) && !temp.contains { path.hasPrefix($0) }
        }
    }

    static func addRecent(_ path: String) {
        var list = recentRepos.filter { $0 != path }
        list.insert(path, at: 0)
        recentRepos = list
    }
}
