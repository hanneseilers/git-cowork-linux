import AppKit
import SwiftUI

// Debug builds only: lets developers and agents check the UI from a terminal.
// Release builds (make app / make install) don't contain any of this.
#if DEBUG

/// For checking the UI without screen-recording permission:
/// GITCOWORK_SNAPSHOT=/tmp/shot.png renders the front window (or its open sheet) to a PNG after a few seconds.
enum DebugSnapshot {
    /// GITCOWORK_DEBUG_SELECT = "commit:<n>" (nth commit) | "diff" (first changed file) | "commitdiff:<n>"
    /// GITCOWORK_DEBUG_MODE = "board" | "reviews", optionally ":<n>" to select the nth task / review.
    /// GITCOWORK_DEBUG_LOG = "1" opens the command log.
    @MainActor
    static func applySelection(_ model: RepoModel) async {
        applyMode(model)
        // GITCOWORK_DEBUG_LOG = "1": open the command log.
        if ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_LOG"] != nil { model.showCommandLog = true }
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

    @MainActor
    static func scheduleIfRequested() {
        // GITCOWORK_DEBUG_APPEARANCE = "light" | "dark": render in that appearance.
        switch ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        // GITCOWORK_DEBUG_SETTINGS=1: open the Settings window (to snapshot it).
        if ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                // Same as choosing git-cowork > Settings… (⌘,).
                guard let menu = NSApp.mainMenu?.items.first?.submenu,
                      let i = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { return }
                menu.performActionForItem(at: i)
            }
        }
        // GITCOWORK_DEBUG_CLONE=1: open the Clone sheet in the first window (to snapshot it).
        if ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_CLONE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                // Same as choosing File > Clone Repository… (⇧⌘O).
                for item in NSApp.mainMenu?.items ?? [] {
                    guard let menu = item.submenu,
                          let i = menu.items.firstIndex(where: { $0.title == L("Clone Repository…") }) else { continue }
                    menu.performActionForItem(at: i)
                    return
                }
            }
        }
        guard let path = ProcessInfo.processInfo.environment["GITCOWORK_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["GITCOWORK_SNAPSHOT_DELAY"] ?? "") ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // The app usually isn't active when run from a terminal, so there's no key
            // window; take the selected tab of the frontmost window group.
            let settings = ProcessInfo.processInfo.environment["GITCOWORK_DEBUG_SETTINGS"] == nil ? nil
                : NSApp.windows.first { $0.isVisible && (($0.identifier?.rawValue ?? "") + $0.title).localizedCaseInsensitiveContains("settings") }
            let candidate = settings ?? NSApp.keyWindow ?? NSApp.mainWindow
                ?? NSApp.orderedWindows.first(where: { $0.isVisible && $0.contentView != nil })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
            let front = candidate?.tabGroup?.selectedWindow ?? candidate
            guard let window = front?.attachedSheet ?? front,
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

func debugLog(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

#endif
