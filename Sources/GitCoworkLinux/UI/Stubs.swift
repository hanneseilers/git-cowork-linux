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
