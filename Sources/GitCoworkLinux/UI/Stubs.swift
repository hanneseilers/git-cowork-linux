import CGtk
import Foundation
import GitCoworkCore

// Placeholders for views built in the following feature branches
// (linux/history, linux/cowork, linux/accounts). Each branch removes its part.

@MainActor
private func placeholder(_ title: String) -> Widget {
    let s = Widget(raw: RP(adw_status_page_new()))
    adw_status_page_set_title(s.op, title)
    return s
}

@MainActor final class BoardView {
    let root: Widget
    init(page: RepoPage) { root = placeholder(L("Board")) }
    func move(_ id: String, by step: Int) {}
}

@MainActor final class ReviewsView {
    let root: Widget
    init(page: RepoPage) { root = placeholder(L("Reviews")) }
}

@MainActor final class InboxButton {
    let root: Widget
    init(page: RepoPage) { root = Button(icon: "mail-unread-symbolic", "flat") }
}

@MainActor enum CoworkSheets {
    static func newTask(status: TaskStatus, page: RepoPage) {}
    static func requestReview(branch: String, page: RepoPage) {}
    static func team(page: RepoPage) {}
}

@MainActor final class CoworkPanel {
    let root: Widget
    init(page: RepoPage) { root = placeholder(L("Select a task or review")) }
}

@MainActor enum CloneDialog {
    static func present(parent: Widget?, done: @escaping @MainActor (String) -> Void) {}
}

@MainActor enum AccountsPage {
    static func make() -> Widget {
        let p = Widget(raw: RP(adw_preferences_page_new()))
        adw_preferences_page_set_title(p.p(), L("Accounts"))
        adw_preferences_page_set_icon_name(p.p(), "system-users-symbolic")
        return p
    }
}
