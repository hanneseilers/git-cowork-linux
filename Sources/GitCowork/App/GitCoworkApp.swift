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
        DebugSnapshot.scheduleIfRequested()
        CoworkSelfTest.runIfRequested()
        LaunchFolders.openFromCommandLine()
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

/// For checking the UI without screen-recording permission:
/// GITCOWORK_SNAPSHOT=/tmp/shot.png renders the front window to a PNG after a few seconds.
enum DebugSnapshot {
    /// GITCOWORK_DEBUG_SELECT = "commit:<n>" (nth commit) | "diff" (first changed file) | "commitdiff:<n>"
    /// GITCOWORK_DEBUG_MODE = "board" | "reviews", optionally ":<n>" to select the nth task / review.
    @MainActor
    static func applySelection(_ model: RepoModel) async {
        applyMode(model)
        guard let sel = ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_SELECT"] else { return }
        let parts = sel.split(separator: ":")
        let n = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        switch parts.first {
        case "commit":
            if n < model.commits.count { model.reveal(model.commits[n].id) }
        case "diff":
            if let f = (model.status.unstaged + model.status.staged).first { model.openDiff = .working(f) }
        case "commitdiff":
            guard n < model.commits.count, let d = await model.commitDetail(model.commits[n].id) else { return }
            model.reveal(d.id)
            if let f = await model.changedFiles(d).first { model.openDiff = .commit(d, f) }
        default: break
        }
    }

    @MainActor
    private static func applyMode(_ model: RepoModel) {
        guard let value = ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_MODE"] else { return }
        let parts = value.split(separator: ":")
        guard let mode = parts.first.flatMap({ CenterMode(rawValue: String($0)) }) else { return }
        model.centerMode = mode
        guard parts.count > 1, let n = Int(parts[1]) else { return }
        switch mode {
        case .board:
            if n < model.cowork.tasks.count { model.coworkSelection = .task(model.cowork.tasks[n].id) }
        case .reviews:
            if n < model.cowork.reviews.count { model.coworkSelection = .review(model.cowork.reviews[n].id) }
        case .history: break
        }
    }

    static func scheduleIfRequested() {
        // GITCOWORK_DEBUG_APPEARANCE = "light" | "dark": render in that appearance.
        switch ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        guard let path = ProcessInfo.processInfo.environment["GITCOWORK_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["GITCOWORK_SNAPSHOT_DELAY"] ?? "") ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // The app usually isn't active when run from a terminal, so there's no key
            // window; take the selected tab of the frontmost window group.
            let candidate = NSApp.keyWindow ?? NSApp.mainWindow
                ?? NSApp.orderedWindows.first(where: { $0.isVisible && $0.contentView != nil })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
            guard let window = candidate?.tabGroup?.selectedWindow ?? candidate,
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                debugLog("snapshot: no visible window (\(NSApp.windows.count) windows)")
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            if ProcessInfo.processInfo.environment["GITCOWORK_SNAPSHOT_QUIT"] != nil { NSApp.terminate(nil) }
        }
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

func debugLog(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}
