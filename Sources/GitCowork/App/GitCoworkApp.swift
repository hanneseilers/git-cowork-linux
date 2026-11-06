import AppKit
import SwiftUI

@main
struct GitCoworkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One window per worktree. Windows open as tabs of each other.
        WindowGroup("git-cowork", id: "repo", for: String.self) { $path in
            RepoWindow(path: $path)
        }
        // Folders from `open -a git-cowork <dir>`, the command line, or the Dock icon.
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1440, height: 880)
        .commands { AppCommands() }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run straight from `swift run` (no app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = true
        _ = GitRunner.shared   // start resolving the login shell PATH early
        #if DEBUG
        DebugSnapshot.scheduleIfRequested()
        CoworkSelfTest.runIfRequested()
        UndoSelfTest.runIfRequested()
        #endif
        LaunchFolders.openFromCommandLine()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Credentials.shared.stop()   // no token stays in memory after quitting
    }
}

/// Things the focused window can do; used by menu commands.
struct WindowActions {
    let open: (String) -> Void
    let showClone: () -> Void
}

extension FocusedValues {
    struct RepoModelKey: FocusedValueKey { typealias Value = RepoModel }
    struct WindowActionsKey: FocusedValueKey { typealias Value = WindowActions }

    var repoModel: RepoModel? {
        get { self[RepoModelKey.self] }
        set { self[RepoModelKey.self] = newValue }
    }

    var windowActions: WindowActions? {
        get { self[WindowActionsKey.self] }
        set { self[WindowActionsKey.self] = newValue }
    }
}

/// The same actions for views inside the window (toolbar repository menu).
private struct WindowActionsEnvironmentKey: EnvironmentKey {
    static let defaultValue: WindowActions? = nil
}

extension EnvironmentValues {
    var windowActions: WindowActions? {
        get { self[WindowActionsEnvironmentKey.self] }
        set { self[WindowActionsEnvironmentKey.self] = newValue }
    }
}

/// `GitCowork /path/to/repo` from a terminal. AppKit swallows folder
/// arguments and then SwiftUI opens no window, so open one ourselves.
@MainActor
enum LaunchFolders {
    static var pending: [String] = []
    /// Clone was chosen with no window open; the next empty window shows the clone sheet.
    static var pendingClone = false

    /// All folders from the command line. The first window to appear takes them
    /// all, so later ⌘T / New Window never pick up leftovers.
    static func takeAll() -> [String] {
        defer { pending = [] }
        return pending
    }

    static func openFromCommandLine() {
        pending = CommandLine.arguments.dropFirst().filter { arg in
            var isDir: ObjCBool = false
            return !arg.hasPrefix("-") && FileManager.default.fileExists(atPath: arg, isDirectory: &isDir) && isDir.boolValue
        }.map { realPath($0) }
        guard !pending.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { newWindow() }
        }
    }

    /// Same as File > New Window, which is how SwiftUI creates WindowGroup windows.
    static func newWindow() {
        for item in NSApp.mainMenu?.items ?? [] {
            guard let menu = item.submenu,
                  let i = menu.items.firstIndex(where: { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command }) else { continue }
            menu.performActionForItem(at: i)
            return
        }
    }
}
