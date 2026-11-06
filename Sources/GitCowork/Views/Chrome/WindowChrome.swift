import AppKit
import SwiftUI

/// AppKit-level window chrome: always-visible repo tabs, new tabs, filter focus.
@MainActor
enum WindowChrome {
    static let tabbingIdentifier = "git-cowork.repo"

    /// Called once when a window first appears. The tab bar stays visible even
    /// with a single repo open, like GitKraken's repo tabs.
    static func configure(_ window: NSWindow) {
        window.tabbingMode = .preferred
        window.tabbingIdentifier = tabbingIdentifier
        // The repository picker shows the name; keep the title for tabs only.
        window.titleVisibility = .hidden
    }

    static func showTabBar(_ window: NSWindow) {
        guard let group = window.tabGroup, !group.isTabBarVisible else { return }
        window.toggleTabBar(nil)
    }

    /// New empty tab (welcome screen) next to the key window. Used by the
    /// tab bar's "+" and File > New Tab.
    static func newTab() {
        WindowAccessor.setPendingParent(NSApp.keyWindow ?? NSApp.mainWindow)
        LaunchFolders.newWindow()
    }

    /// Moves keyboard focus to the toolbar's commit filter field.
    static func focusFilter() {
        guard let window = NSApp.keyWindow else { return }
        if let item = window.toolbar?.items.lazy.compactMap({ $0 as? NSSearchToolbarItem }).first {
            item.beginSearchInteraction()
        } else if let field = searchField(in: window.contentView?.superview) {
            window.makeFirstResponder(field)
        }
    }

    private static func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        for sub in view.subviews {
            if let found = searchField(in: sub) { return found }
        }
        return nil
    }
}

/// Hides the window title in the toolbar (the repository picker shows it).
/// The title still names the tab.
struct HideToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}
