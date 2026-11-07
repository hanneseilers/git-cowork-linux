import CGtk
import Foundation
import GitCoworkCore

/// The right panel: the selected commit, the working copy (stage, discard,
/// commit, amend), or the selected task / review on Board and Reviews.
@MainActor
final class InspectorView {
    let root = Stack()
    unowned let page: RepoPage
    private var model: RepoModel { page.model }
    private let commitPanel: CommitPanel
    private let changesPanel: ChangesPanel
    private let coworkPanel: CoworkPanel

    init(page: RepoPage) {
        self.page = page
        commitPanel = CommitPanel(page: page)
        changesPanel = ChangesPanel(page: page)
        coworkPanel = CoworkPanel(page: page)
        root.add("commit", commitPanel.root)
        root.add("changes", changesPanel.root)
        root.add("cowork", coworkPanel.root)
        root.size(340, -1)
        root.track { [weak self] in
            guard let self else { return }
            let m = self.model
            if m.centerMode != .history, m.openDiff == nil {
                self.root.visibleName = "cowork"
                return
            }
            switch m.selection {
            case .workingCopy?: self.root.visibleName = "changes"
            default: self.root.visibleName = "commit"
            }
        }
    }

    func commitShortcut() { changesPanel.commit() }
    func focusSummary() {
        model.selection = .workingCopy
        DispatchQueue.main.async { [weak self] in self?.changesPanel.focusSummary() }
    }
}

/// A file row: status letter in its color, name, folder.
@MainActor
func fileRow(_ f: FileChange, selected: Bool = false) -> Box {
    let row = Box.h(6).margins(2, 6, 2, 6)
    let letter = Label(String(f.status.rawValue == "?" ? "U" : f.status.rawValue), "gc-mono")
    letter.markup("<span foreground=\"\(Theme.statusColor(f.status).hex)\" weight=\"bold\">\(f.status.rawValue == "?" ? "U" : String(f.status.rawValue))</span>")
    letter.size(14, -1)
    row.append(letter)
    let texts = Box.h(6).hexpand()
    texts.append(Label(f.fileName).ellipsize(PANGO_ELLIPSIZE_MIDDLE))
    if !f.directory.isEmpty { texts.append(Label(f.directory, "dim-label", "caption").ellipsize(PANGO_ELLIPSIZE_START).hexpand()) }
    row.append(texts)
    row.tooltip(f.oldPath.map { "\($0) → \(f.path)" } ?? f.path)
    return row
}

// MARK: Commit

@MainActor
final class CommitPanel {
    let root = Box.v(0)
    unowned let page: RepoPage
    private var model: RepoModel { page.model }
    private let content = Box.v(8)
    private let files = ListBox()
    private var loadedSHA: String?
    private var loadTask: Task<Void, Never>?

    init(page: RepoPage) {
        self.page = page
        let header = Box.h(6)
        header.css("gc-panel-header")
        header.append(Label(L("Commit"), "heading").hexpand())
        root.append(header)
        let body = Box.v(8).margins(10, 10, 10, 10)
        body.append(content)
        body.append(files)
        files.css("boxed-list")
        root.append(Scrolled(body).vexpand())
        root.track { [weak self] in
            guard let self else { return }
            guard case .commit(let sha)? = self.model.selection else { return }
            _ = self.model.historyVersion
            if sha != self.loadedSHA { self.load(sha) }
        }
    }

    private func load(_ sha: String) {
        loadedSHA = sha
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            guard let detail = await self.model.commitDetail(sha) else { return }
            let changed = await self.model.changedFiles(detail)
            guard !Task.isCancelled, self.loadedSHA == sha else { return }
            self.show(detail, changed)
        }
    }

    private func show(_ d: CommitDetail, _ changed: [FileChange]) {
        content.removeAll()
        let subject = Label(d.subject, "title-4").wrap().selectable()
        content.append(subject)
        let (text, coAuthors) = Self.split(body: d.body)
        if !text.isEmpty { content.append(Label(text).wrap().selectable()) }

        let author = Box.h(8)
        author.append(avatar(d.authorName, email: d.authorEmail, size: 28))
        let who = Box.v(0).hexpand()
        who.append(Label(d.authorName, "heading").ellipsize())
        who.append(Label("\(d.authorEmail) · \(fullDate(d.authorDate))", "dim-label", "caption").ellipsize())
        author.append(who)
        content.append(author)
        for c in coAuthors {
            let row = Box.h(8)
            row.append(avatar(c.name, email: c.email, size: 20))
            row.append(Label(String(localized: "with \(c.name)"), "dim-label").ellipsize())
            content.append(row)
        }
        if d.committerEmail != d.authorEmail {
            content.append(Label(String(localized: "Committed by \(d.committerName) · \(fullDate(d.committerDate))"), "dim-label", "caption").wrap())
        }

        let shaRow = Box.h(6)
        shaRow.append(Label("SHA", "dim-label", "caption"))
        shaRow.append(Label(d.id, "gc-mono", "caption").selectable().ellipsize(PANGO_ELLIPSIZE_MIDDLE).hexpand())
        shaRow.append(Button(icon: "edit-copy-symbolic", "flat") { External.copy(d.id) }.tooltip(L("Copy SHA")))
        content.append(shaRow)
        if !d.parents.isEmpty {
            let parents = Box.h(6)
            parents.append(Label(d.parents.count > 1 ? L("Parents") : L("Parent"), "dim-label", "caption"))
            for p in d.parents {
                parents.append(Button(String(p.prefix(7)), "flat", "gc-mono") { [weak self] in self?.model.reveal(p) })
            }
            content.append(parents)
        }
        let refs = model.refsByCommit[d.id] ?? []
        if !refs.isEmpty {
            let flow = Box.h(4)
            for r in refs.prefix(6) {
                flow.append(chip(r.name, color: r.kind == .tag ? Theme.secondaryText : Theme.lane(model.graph[safe: model.commitIndex[d.id] ?? -1]?.color ?? 0)))
            }
            content.append(flow)
        }
        if let links = model.links(for: nil), let url = links.commitURL(d.id) {
            content.append(Button(String(localized: "Open Commit on \(links.host)"), icon: "web-browser-symbolic", "flat") { External.browse(url) }.halign(GTK_ALIGN_START))
        }

        let counts = ChangeCounts(changed)
        content.append(Label((changed.count == 1 ? L("1 file changed") : String(localized: "\(changed.count) files changed")) + "  " +
                             [counts.added > 0 ? "+\(counts.added)" : nil, counts.modified > 0 ? "~\(counts.modified)" : nil,
                              counts.deleted > 0 ? "−\(counts.deleted)" : nil].compactMap { $0 }.joined(separator: " "), "dim-label").margins(8, 0, 0, 0))
        files.removeAll()
        for f in changed {
            files.append(fileRow(f), action: { [weak self] in self?.model.openDiff = .commit(d, f) }, menu: { [weak self] x, y, w in
                guard let self else { return }
                Menus.popup([
                    MenuItem(L("Show Diff")) { self.model.openDiff = .commit(d, f) },
                    MenuItem(L("Open in Editor")) { External.openEditor(self.model.root.path + "/" + f.path) },
                    MenuItem(L("Copy Path")) { External.copy(f.path) },
                ], at: x, y, in: w)
            })
        }
    }

    /// Body text without its Co-authored-by trailers, and those trailers.
    static func split(body: String) -> (text: String, coAuthors: [(name: String, email: String)]) {
        var lines: [Substring] = []
        var authors: [(name: String, email: String)] = []
        let prefix = "co-authored-by:"
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix(prefix) {
                let value = t.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                if let lt = value.firstIndex(of: "<"), let gt = value.lastIndex(of: ">"), lt < gt {
                    let name = value[..<lt].trimmingCharacters(in: .whitespaces)
                    let email = String(value[value.index(after: lt)..<gt])
                    if !authors.contains(where: { $0.email.lowercased() == email.lowercased() }) {
                        authors.append((name.isEmpty ? email : name, email))
                    }
                }
                continue
            }
            lines.append(line)
        }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), authors)
    }
}

// MARK: Changes

@MainActor
final class ChangesPanel {
    let root = Box.v(0)
    unowned let page: RepoPage
    private var model: RepoModel { page.model }
    private let lists = Box.v(10).margins(8, 8, 8, 8)
    private let summary = Entry(placeholder: L("Summary"))
    private let details = TextView()
    private let amend = Check(L("Amend previous commit"))
    private let commitButton = Button(L("Commit"), "suggested-action")
    private let remaining = Label("", "dim-label", "caption")
    private var signature = ""
    private var preAmendDraft: (String, String)?
    private var loadedAmendMessage: (String, String)?

    init(page: RepoPage) {
        self.page = page
        let header = Box.h(6)
        header.css("gc-panel-header")
        header.append(Label(L("Uncommitted Changes"), "heading").hexpand())
        root.append(header)
        root.append(Scrolled(lists).vexpand())

        // Composer
        let composer = Box.v(6).margins(8, 8, 8, 8)
        composer.append(Separator())
        let line = Box.h(6)
        summary.hexpand()
        summary.onChanged { [weak self] in
            guard let self else { return }
            if self.model.draftSummary != self.summary.text { self.model.draftSummary = self.summary.text }
        }
        summary.onActivate { [weak self] in self?.commit() }
        line.append(summary)
        line.append(remaining)
        composer.append(line)
        details.onChanged { [weak self] in
            guard let self else { return }
            if self.model.draftDetails != self.details.text { self.model.draftDetails = self.details.text }
        }
        let detailsScroll = Scrolled(details)
        detailsScroll.size(-1, 70)
        detailsScroll.css("card")
        composer.append(detailsScroll)
        Signal.on(amend.raw, "toggled") { [weak self] in self?.amendChanged() }
        composer.append(amend)
        commitButton.onClicked { [weak self] in self?.commit() }
        commitButton.tooltip(L("Commit (Ctrl+Enter)"))
        composer.append(commitButton)
        root.append(composer)

        root.track { [weak self] in self?.render() }
    }

    func focusSummary() { summary.grabFocus() }

    private var canAmend: Bool { model.operation == nil && model.headSHA != nil }

    private func render() {
        let m = model
        let st = m.status
        if summary.text != m.draftSummary { summary.text = m.draftSummary }
        if details.text != m.draftDetails { details.text = m.draftDetails }
        if !canAmend && amend.isOn { amend.isOn = false }
        amend.sensitive = canAmend
        let left = 72 - m.draftSummary.count
        remaining.text = m.draftSummary.isEmpty ? "" : "\(left)"
        let n = st.staged.count
        let isAmend = amend.isOn
        let title: String
        if m.operation == .merge { title = L("Commit Merge") }
        else if isAmend { title = n == 0 ? L("Amend Previous Commit") : (n == 1 ? L("Amend Previous Commit with 1 file") : String(localized: "Amend Previous Commit with \(n) files")) }
        else if n == 0 { title = L("Stage Changes to Commit") }
        else { title = n == 1 ? L("Commit Changes to 1 file") : String(localized: "Commit Changes to \(n) files") }
        commitButton.setLabel(title)
        commitButton.sensitive = canCommit

        let sig = "\(st.staged)\(st.unstaged)\(st.untracked)\(st.conflicted)\(m.busy ?? "")\(String(describing: m.openDiff))\(m.operation?.rawValue ?? "")"
        guard sig != signature else { return }
        signature = sig
        lists.removeAll()
        let open = m.openDiff?.file
        if !st.conflicted.isEmpty {
            section(L("Conflicts"), st.conflicted, open: open, header: [])
        }
        let unstaged = st.unstaged + st.untracked
        section(L("Unstaged"), unstaged, open: open, header: unstaged.isEmpty ? [] : [
            Button(L("Discard All"), "flat", "error") { [weak self] in self?.model.discard(unstaged) },
            Button(L("Stage All"), "flat") { [weak self] in self?.page.run { await $0.stageAll() } },
        ])
        section(L("Staged"), st.staged, open: open, header: st.staged.isEmpty ? [] : [
            Button(L("Unstage All"), "flat") { [weak self] in self?.page.run { await $0.unstageAll() } },
        ])
        if st.isClean {
            lists.append(Label(L("No changes. Edit files in this worktree and they show up here."), "dim-label").wrap().margins(20, 10, 0, 10))
        }
    }

    private var canCommit: Bool {
        let m = model
        if m.busy != nil { return false }
        if m.operation == .merge { return m.status.conflicted.isEmpty }
        if amend.isOn { return true }
        return !m.status.staged.isEmpty && !m.draftSummary.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func section(_ title: String, _ files: [FileChange], open: FileChange?, header: [Widget]) {
        let h = Box.h(4)
        h.append(Label("\(title.uppercased())  \(files.count)", "gc-section", "dim-label").hexpand())
        header.forEach { h.append($0) }
        lists.append(h)
        guard !files.isEmpty else { return }
        let list = ListBox("boxed-list")
        for f in files {
            let row = fileRow(f, selected: open == f)
            switch f.area {
            case .staged:
                row.append(Button(icon: "list-remove-symbolic", "flat", "circular") { [weak self] in self?.page.run { _ = await $0.unstage([f]) } }.tooltip(L("Unstage")))
            case .unstaged, .untracked:
                row.append(Button(icon: "edit-undo-symbolic", "flat", "circular") { [weak self] in self?.model.discard([f]) }.tooltip(L("Discard")))
                row.append(Button(icon: "list-add-symbolic", "flat", "circular") { [weak self] in self?.page.run { _ = await $0.stage([f]) } }.tooltip(L("Stage")))
            case .conflicted:
                row.append(Button(L("Mine"), "flat") { [weak self] in self?.page.run { await $0.resolve(f, mine: true) } }.tooltip(L("Use my version")))
                row.append(Button(L("Theirs"), "flat") { [weak self] in self?.page.run { await $0.resolve(f, mine: false) } }.tooltip(L("Use their version")))
            }
            list.append(row, selected: open == f, action: { [weak self] in self?.model.openDiff = .working(f) }, menu: { [weak self] x, y, w in
                guard let self else { return }
                let path = self.model.root.path + "/" + f.path
                var items: [MenuItem] = [MenuItem(L("Show Diff")) { self.model.openDiff = .working(f) }]
                switch f.area {
                case .staged: items.append(MenuItem(L("Unstage")) { self.page.run { _ = await $0.unstage([f]) } })
                case .unstaged, .untracked:
                    items.append(MenuItem(L("Stage")) { self.page.run { _ = await $0.stage([f]) } })
                    items.append(MenuItem(L("Discard Changes…"), destructive: true) { self.model.discard([f]) })
                case .conflicted:
                    items.append(MenuItem(L("Use Mine")) { self.page.run { await $0.resolve(f, mine: true) } })
                    items.append(MenuItem(L("Use Theirs")) { self.page.run { await $0.resolve(f, mine: false) } })
                    items.append(MenuItem(L("Mark as Resolved")) { self.page.run { _ = await $0.stage([f]) } })
                }
                items += [.separator,
                          MenuItem(L("Open in Editor")) { External.openEditor(path) },
                          MenuItem(L("Show in File Manager")) { External.reveal(path) },
                          MenuItem(L("Copy Path")) { External.copy(f.path) }]
                Menus.popup(items, at: x, y, in: w)
            })
        }
        lists.append(list)
    }

    // MARK: Committing

    private var message: String {
        let s = model.draftSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = model.draftDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        return d.isEmpty ? s : s + "\n\n" + d
    }

    func commit() {
        guard canCommit else { return }
        let msg = message
        let isAmend = amend.isOn && canAmend
        Task { [weak self] in
            guard let self else { return }
            if await self.model.commit(message: msg, amend: isAmend) {
                self.model.draftSummary = ""
                self.model.draftDetails = ""
                self.preAmendDraft = nil
                self.loadedAmendMessage = nil
                self.amend.isOn = false
            }
        }
    }

    /// Ticking amend borrows HEAD's message (if the draft is empty); unticking
    /// gives back the draft from before.
    private func amendChanged() {
        if amend.isOn {
            preAmendDraft = (model.draftSummary, model.draftDetails)
            guard model.draftSummary.isEmpty, let head = model.headSHA else { return }
            Task { [weak self] in
                guard let self, let d = await self.model.commitDetail(head), self.amend.isOn, self.model.draftSummary.isEmpty else { return }
                self.model.draftSummary = d.subject
                self.model.draftDetails = d.body
                self.loadedAmendMessage = (d.subject, d.body)
            }
        } else {
            if let loaded = loadedAmendMessage, model.draftSummary == loaded.0, model.draftDetails == loaded.1 {
                model.draftSummary = preAmendDraft?.0 ?? ""
                model.draftDetails = preAmendDraft?.1 ?? ""
            }
            loadedAmendMessage = nil
        }
        signature = ""
        render()
    }
}
