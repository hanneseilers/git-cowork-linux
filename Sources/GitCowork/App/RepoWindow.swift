import AppKit
import SwiftUI

/// One window (tab). Shows the welcome screen until a repo is chosen.
struct RepoWindow: View {
    @Binding var path: String?
    @State private var showClone = false
    @State private var dropTargeted = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let path {
                RepoContainer(path: path, openHere: openHere, openInNewTab: openTab, close: { self.path = nil })
                    .id(path)
            } else {
                WelcomeView(open: { open($0) }, clone: { showClone = true })
            }
        }
        .environment(\.windowActions, actions)
        .frame(minWidth: 900, minHeight: 500)
        .background(WindowAccessor())
        // Only an empty (welcome) window takes `open -a git-cowork <dir>`;
        // windows showing a repo decline, so SwiftUI opens a new tab instead.
        .handlesExternalEvents(preferring: path == nil ? ["*"] : [], allowing: path == nil ? ["*"] : [])
        .onAppear {
            if path == nil { openLaunchFolders() }
            if LaunchFolders.pendingClone {
                LaunchFolders.pendingClone = false
                showClone = true
            }
        }
        .onOpenURL { url in
            if url.isFileURL { open(url.path) }
        }
        // Drop a folder anywhere: opens here when empty, else in a new tab.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.hasDirectoryPath) ?? urls.first else { return false }
            open(url.path)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(Theme.Space.s)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showClone) {
            CloneSheet { open($0) }
        }
        .focusedSceneValue(\.windowActions, actions)
    }

    private var actions: WindowActions {
        WindowActions(open: { open($0) }, showClone: { showClone = true })
    }

    /// Folders passed on the command line: the first opens here, the rest as tabs.
    private func openLaunchFolders() {
        let folders = LaunchFolders.takeAll()
        guard !folders.isEmpty else { return }
        Task {
            for folder in folders {
                guard let resolved = await RepoLocator.resolve(folder) else { continue }
                if path == nil { path = resolved } else { openTab(resolved) }
            }
        }
    }

    /// Opens a repo here if this window is empty, otherwise in a new tab.
    private func open(_ chosen: String) {
        Task {
            guard let resolved = await RepoLocator.resolve(chosen) else {
                let alert = NSAlert()
                alert.messageText = "Not a git repository"
                alert.informativeText = chosen
                alert.runModal()
                return
            }
            if path == nil { path = resolved } else { openTab(resolved) }
        }
    }

    /// Switches this window to another worktree, unless that worktree is
    /// already open in another tab: then that tab comes to the front.
    private func openHere(_ p: String) {
        if OpenRepos.isOpen(p) { openTab(p) } else { path = p }
    }

    /// New tab next to this window. SwiftUI brings an existing window to the
    /// front when one already shows `p`.
    private func openTab(_ p: String) {
        WindowAccessor.setPendingParent(NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.orderedWindows.first { $0.isVisible && $0.tabbingIdentifier == WindowChrome.tabbingIdentifier })
        openWindow(id: "repo", value: p)
    }
}

/// Worktree paths currently shown in a window, so switching to one that's
/// already open focuses its tab instead of opening it twice.
@MainActor
enum OpenRepos {
    private static var counts: [String: Int] = [:]

    static func isOpen(_ path: String) -> Bool { counts[realPath(path), default: 0] > 0 }
    static func add(_ path: String) { counts[realPath(path), default: 0] += 1 }
    static func remove(_ path: String) {
        let key = realPath(path)
        let n = counts[key, default: 0] - 1
        counts[key] = n > 0 ? n : nil
    }
}

/// Creates the model for a worktree and keeps it for the window's lifetime.
private struct RepoContainer: View {
    @State private var model: RepoModel
    let openHere: (String) -> Void
    let openInNewTab: (String) -> Void
    let close: () -> Void

    private let path: String

    init(path: String, openHere: @escaping (String) -> Void, openInNewTab: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.path = path
        _model = State(initialValue: RepoModel(root: URL(fileURLWithPath: path)))
        self.openHere = openHere
        self.openInNewTab = openInNewTab
        self.close = close
    }

    var body: some View {
        Group {
            if let error = model.loadError {
                VStack {
                    EmptyState(symbol: "exclamationmark.triangle", title: "Can't open this repository", message: error)
                    Button("Choose Another…", action: close).padding(.bottom, Theme.Space.xxl)
                }
            } else {
                RepoView(model: model, openHere: openHere, openInNewTab: openInNewTab)
            }
        }
        .task {
            await model.load()
            if model.loadError == nil { Prefs.addRecent(model.mainWorktreePath ?? model.root.path) }
            #if DEBUG
            await DebugSnapshot.applySelection(model)
            #endif
        }
        .onAppear { OpenRepos.add(path) }
        .onDisappear {
            OpenRepos.remove(path)
            model.stopWatching()
        }
    }
}

/// Sets up the window chrome once and makes new windows join the opener's tab group.
struct WindowAccessor: NSViewRepresentable {
    /// Window the next new window should join as a tab. Weak and one-shot: if
    /// no window appears (SwiftUI only focused an existing one), it is dropped
    /// shortly after, so a later ⌘N isn't tabbed into a stale parent.
    @MainActor private(set) static weak var pendingTabParent: NSWindow?
    @MainActor private static var pendingGeneration = 0

    @MainActor static func setPendingParent(_ window: NSWindow?) {
        pendingTabParent = window
        pendingGeneration += 1
        let generation = pendingGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if pendingGeneration == generation { pendingTabParent = nil }
        }
    }

    func makeNSView(context: Context) -> NSView { TrackingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TrackingView: NSView {
        private weak var configured: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== configured else { return }
            configured = window
            WindowChrome.configure(window)
            let parent = WindowAccessor.pendingTabParent
            WindowAccessor.pendingTabParent = nil
            if let parent, parent !== window, parent.isVisible {
                DispatchQueue.main.async {
                    parent.addTabbedWindow(window, ordered: .above)
                    window.makeKeyAndOrderFront(nil)
                    WindowChrome.showTabBar(window)
                }
            } else {
                DispatchQueue.main.async { WindowChrome.showTabBar(window) }
            }
        }
    }
}
