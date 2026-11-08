import CGtk
import Foundation
import GitCoworkCore

/// Review requests: waiting for me, mine, all open, closed.
@MainActor
final class ReviewsView {
    enum Filter: Int, CaseIterable {
        case waiting, mine, open, closed
        var title: String {
            switch self {
            case .waiting: L("Waiting for me")
            case .mine: L("Requested by me")
            case .open: L("All open")
            case .closed: L("Closed")
            }
        }
    }

    let root = Box.v(0)
    unowned let page: RepoPage
    private var model: RepoModel { page.model }
    private let filterDrop = DropDown(Filter.allCases.map(\.title), selected: 2)
    private let list = ListBox("boxed-list")
    private let empty = Label("", "dim-label")
    private var signature = ""

    init(page: RepoPage) {
        self.page = page
        let header = Box.h(8)
        header.css("gc-panel-header")
        header.append(Label(L("Reviews"), "heading").hexpand())
        header.append(filterDrop)
        header.append(Button(L("Request Review"), icon: "mail-send-symbolic", "suggested-action") { [weak page] in page?.requestReview() }
            .tooltip(L("Request review of the current branch (Ctrl+Shift+R)")))
        root.append(header)
        let body = Box.v(8).margins(10, 10, 10, 10)
        body.append(list)
        empty.wrap().margins(30, 10, 0, 10)
        body.append(empty)
        root.append(Scrolled(body).vexpand())
        Signal.onPtr(filterDrop.raw, "notify::selected") { [weak self] _ in self?.render(force: true) }
        root.track { [weak self] in self?.render() }
    }

    private func render(force: Bool = false) {
        let store = model.cowork
        let sig = "\(store.version)|\(String(describing: model.coworkSelection))|\(filterDrop.selected)"
        guard force || sig != signature else { return }
        signature = sig
        let me = store.me.id
        let filter = Filter(rawValue: filterDrop.selected) ?? .open
        let reviews = store.reviews.filter { r in
            switch filter {
            case .waiting: r.status == .open && r.reviewers.contains { $0.key.lowercased() == me && $0.value == .requested }
            case .mine: r.status == .open && r.requester.lowercased() == me
            case .open: r.status == .open
            case .closed: r.status == .closed
            }
        }.sorted { $0.updated > $1.updated }
        list.removeAll()
        list.visible = !reviews.isEmpty
        empty.visible = reviews.isEmpty
        empty.text = store.reviews.isEmpty
            ? L("No review requests yet. Request a review of a branch with Ctrl+Shift+R, from the branch's menu, or with git cowork review.")
            : L("Nothing here with this filter.")
        for r in reviews {
            let row = Box.h(10).margins(8, 10, 8, 10)
            let texts = Box.v(2).hexpand()
            texts.append(Label(r.title.isEmpty ? r.branch : r.title, "heading").ellipsize())
            texts.append(Label("\(r.id) · \(r.branch) → \(r.base) · \(displayName(r.requester, in: store)) · \(relativeDate(r.updated))", "dim-label", "caption").ellipsize())
            row.append(texts)
            let verdicts = Box.h(2)
            for (email, v) in r.reviewers.sorted(by: { $0.key < $1.key }).prefix(5) {
                let a = avatar(displayName(email, in: store), email: email, size: 20)
                a.tooltip("\(displayName(email, in: store)): \(verdictTitle(v))")
                verdicts.append(a)
            }
            row.append(verdicts)
            row.append(chip(verdictTitle(r.overall), color: verdictColor(r.overall)))
            let selected = model.coworkSelection == .review(r.id)
            list.append(row, selected: selected, action: { [weak self] in self?.model.coworkSelection = .review(r.id) }, menu: { [weak self] x, y, w in
                guard let self else { return }
                Menus.popup([
                    MenuItem(L("Open Review")) { self.model.coworkSelection = .review(r.id) },
                    MenuItem(r.status == .open ? L("Close Review") : L("Reopen Review")) {
                        Task { await self.model.cowork.updateReview(r.id) { $0.status = r.status == .open ? .closed : .open } }
                    },
                    MenuItem(L("Copy Branch Name")) { External.copy(r.branch) },
                ], at: x, y, in: w)
            })
        }
    }
}

/// Inbox: assigned to me, review requests, verdicts, @mentions, replies.
@MainActor
final class InboxButton {
    let root: Widget
    unowned let page: RepoPage
    private let button = MenuButton(icon: "mail-unread-symbolic", "flat")
    private let badge = Label("", "gc-count")

    init(page: RepoPage) {
        self.page = page
        let overlay = Widget(raw: RP(gtk_overlay_new()))
        gtk_overlay_set_child(OP(overlay.raw), button.w)
        badge.halign(GTK_ALIGN_END).valign(GTK_ALIGN_START)
        gtk_overlay_add_overlay(OP(overlay.raw), badge.w)
        gtk_widget_set_can_target(badge.w, 0)
        overlay.keep(button)
        overlay.keep(badge)
        root = overlay
        button.tooltip(L("Inbox"))
        button.content { [weak self] p in self?.fill(p) }
        root.track { [weak self] in
            guard let self else { return }
            let m = self.page.model
            let unseen = CoworkNotifier.shared.unseen(m.cowork.inbox, repo: m.mainWorktreePath ?? m.root.path)
            self.badge.text = unseen.isEmpty ? "" : (unseen.count > 99 ? "99+" : "\(unseen.count)")
            self.badge.visible = !unseen.isEmpty
        }
    }

    private func fill(_ p: Popover) {
        let m = page.model
        let repo = m.mainWorktreePath ?? m.root.path
        let items = m.cowork.inbox
        let seen = CoworkNotifier.shared.seen(repo: repo)
        let box = Box.v(6).margins(8, 8, 8, 8)
        let header = Box.h(6)
        header.append(Label(L("Inbox"), "heading").hexpand())
        header.append(Button(L("Mark All as Read"), "flat") { [weak self, weak p] in
            CoworkNotifier.shared.markSeen(items.map(\.id), repo: repo)
            p?.popdown()
            self?.page.model.cowork.drafts["inbox.refresh"] = UUID().uuidString   // re-render the badge
        })
        box.append(header)
        let list = ListBox("boxed-list")
        if items.isEmpty {
            box.append(Label(L("Nothing for you yet. Tasks assigned to you, review requests and @mentions show up here."), "dim-label").wrap().size(320, -1))
        }
        for item in items.prefix(40) {
            let row = Box.h(8).margins(6, 8, 6, 8)
            if !seen.contains(item.id) { row.append(Label("●", "accent")) }
            let texts = Box.v(2).hexpand()
            texts.append(Label(item.title, "heading").ellipsize())
            texts.append(Label(item.detail, "dim-label", "caption").ellipsize())
            row.append(texts)
            row.append(Label(relativeDate(item.date), "dim-label", "caption"))
            list.append(row, action: { [weak self, weak p] in
                guard let self else { return }
                CoworkNotifier.shared.markSeen([item.id], repo: repo)
                p?.popdown()
                openCoworkTarget(item.target, page: self.page)
                self.page.model.cowork.drafts["inbox.refresh"] = UUID().uuidString
            })
        }
        if !items.isEmpty {
            let scroll = Scrolled(list)
            scroll.size(380, min(420, Int32(items.count) * 56 + 10))
            box.append(scroll)
        }
        p.setChild(box)
    }
}
