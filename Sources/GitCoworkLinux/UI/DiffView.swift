import CGtk
import Foundation
import GitCoworkCore

/// One file's diff: unified ("hunks") or side by side, intra-line highlights,
/// and stage / unstage / discard per hunk for working-copy files.
@MainActor
final class DiffView {
    let root = Box.v(0)
    unowned let page: RepoPage
    private var model: RepoModel { page.model }

    private let titleLabel = Label("", "heading")
    private let statsLabel = Label("", "dim-label")
    private let actions = Box.h(4)
    private let modeToggle = DropDown([L("Hunks"), L("Split")], selected: UserDefaults.standard.integer(forKey: "diff.mode"))
    private let unified = TextView(monospace: true, editable: false)
    private let left = TextView(monospace: true, editable: false)
    private let right = TextView(monospace: true, editable: false)
    private let stack = Stack()
    private let note = Label("", "dim-label")

    private var document = DiffDocument()
    private var target: DiffTarget?
    private var loadedRefresh = -1
    private var loadTask: Task<Void, Never>?

    init(page: RepoPage) {
        self.page = page
        let header = Box.h(8)
        header.css("gc-panel-header")
        header.append(Button(icon: "go-previous-symbolic", "flat") { [weak self] in self?.model.openDiff = nil }.tooltip(L("Close the diff (Esc)")))
        titleLabel.ellipsize(PANGO_ELLIPSIZE_MIDDLE).hexpand()
        header.append(titleLabel)
        header.append(statsLabel)
        header.append(actions)
        header.append(modeToggle)
        root.append(header)
        note.margins(6, 10, 6, 10).wrap()
        root.append(note)

        for tv in [unified, left, right] {
            tv.wrap(GTK_WRAP_NONE)
            Self.installTags(tv)
        }
        stack.add("unified", Scrolled(unified, hscroll: true))
        let splitBox = Box.h(0).homogeneous()
        let ls = Scrolled(left, hscroll: true), rs = Scrolled(right, hscroll: true)
        // Scroll both sides together.
        gtk_scrolled_window_set_vadjustment(rs.op, ls.vadjustment)
        splitBox.append(ls)
        splitBox.append(Separator(GTK_ORIENTATION_VERTICAL))
        splitBox.append(rs)
        stack.add("split", splitBox)
        stack.vexpand()
        root.append(stack)

        Signal.onPtr(modeToggle.raw, "notify::selected") { [weak self] _ in
            guard let self else { return }
            UserDefaults.standard.set(self.modeToggle.selected, forKey: "diff.mode")
            self.renderDocument()
        }

        root.track { [weak self] in
            guard let self else { return }
            let t = self.model.openDiff
            let refresh = self.model.refreshCount
            guard let t else { self.target = nil; return }
            // Working-copy diffs reload after every refresh (the file may have changed).
            let isWorking: Bool = { if case .working = t { return true } else { return false } }()
            if t != self.target || (isWorking && refresh != self.loadedRefresh) {
                self.load(t, refresh: refresh)
            }
        }
    }

    private static func installTags(_ tv: TextView) {
        let buf = tv.buffer
        func tag(_ name: String, _ props: [(String, String)]) {
            let t = gc_text_tag(buf, name)!
            for (k, v) in props { gc_object_set_string(RP(t), k, v) }
        }
        let dark = Theme.dark
        tag("added", [("paragraph-background", dark ? "#1f3d2a" : "#e6f6ea")])
        tag("removed", [("paragraph-background", dark ? "#4a2326" : "#fbe9ea")])
        tag("added-change", [("background", dark ? "#2f6a43" : "#b8e6c4")])
        tag("removed-change", [("background", dark ? "#7a3338" : "#f3c0c4")])
        tag("hunk", [("paragraph-background", dark ? "#22303f" : "#eef3fb"), ("foreground", dark ? "#9bb6d8" : "#3a5f8f")])
        tag("meta", [("foreground", "#888888")])
        if let meta = gtk_text_tag_table_lookup(gtk_text_buffer_get_tag_table(buf), "meta") {
            gc_object_set_int(RP(meta), "style", Int32(PANGO_STYLE_ITALIC.rawValue))
        }
        tag("gutter", [("foreground", "#999999")])
        tag("empty", [("paragraph-background", dark ? "#2a2a2c" : "#f4f4f5")])
        let bold = gc_text_tag(buf, "bold")!
        gc_object_set_int(RP(bold), "weight", 700)
    }

    private func load(_ t: DiffTarget, refresh: Int) {
        target = t
        loadedRefresh = refresh
        let root = model.root
        loadTask?.cancel()
        let file = t.file
        titleLabel.text = file.oldPath.map { "\($0) → \(file.path)" } ?? file.path
        loadTask = Task { [weak self] in
            let data: Data
            switch t {
            case .working(let f): data = await DiffLoader.working(f, root: root)
            case .commit(let d, let f): data = await DiffLoader.commit(d, file: f, root: root)
            }
            let doc = await Task.detached { DiffDocument.parse(data) }.value
            guard let self, !Task.isCancelled, self.target == t else { return }
            self.document = doc
            self.renderDocument()
        }
    }

    private var hunkActions: [HunkAction] {
        guard let t = target, case .working(let f) = t, f.oldPath == nil, f.status != .typeChanged,
              document.supportsHunkActions else { return [] }
        switch f.area {
        case .unstaged: return [.discard, .stage]
        case .staged: return [.unstage]
        case .untracked, .conflicted: return []
        }
    }

    private func renderDocument() {
        let doc = document
        statsLabel.markup("<span foreground=\"\(Theme.green.hex)\">+\(doc.added)</span>  <span foreground=\"\(Theme.red.hex)\">−\(doc.removed)</span>")
        actions.removeAll()
        if let t = target, case .working(let f) = t {
            switch f.area {
            case .staged: actions.append(Button(L("Unstage File"), "flat") { [weak self] in self?.fileAction { _ = await $0.unstage([f]) } })
            case .unstaged, .untracked:
                actions.append(Button(L("Discard File"), "flat", "error") { [weak self] in self?.model.discard([f]) })
                actions.append(Button(L("Stage File"), "flat") { [weak self] in self?.fileAction { _ = await $0.stage([f]) } })
            case .conflicted:
                actions.append(Button(L("Use Mine"), "flat") { [weak self] in self?.fileAction { await $0.resolve(f, mine: true) } })
                actions.append(Button(L("Use Theirs"), "flat") { [weak self] in self?.fileAction { await $0.resolve(f, mine: false) } })
            }
            actions.append(Button(icon: "text-editor-symbolic", "flat") { [weak self] in
                guard let self else { return }
                External.openEditor(self.model.root.path + "/" + f.path)
            }.tooltip(L("Open in Editor")))
        }
        if doc.isEmpty {
            note.text = L("No text changes: binary file, empty file or a mode change.")
            note.visible = true
        } else if doc.truncated {
            note.text = L("Large diff: only the first 20,000 lines are shown.")
            note.visible = true
        } else {
            note.visible = false
        }
        if modeToggle.selected == 1 {
            stack.visibleName = "split"
            renderSplit(doc)
        } else {
            stack.visibleName = "unified"
            renderUnified(doc)
        }
    }

    /// Stage / unstage / discard the whole file, then show the other side or close.
    private func fileAction(_ fn: @escaping @MainActor (RepoModel) async -> Void) {
        guard let t = target, case .working(let f) = t else { return }
        Task { [weak self] in
            guard let self else { return }
            await fn(self.model)
            self.follow(f)
        }
    }

    private func follow(_ file: FileChange) {
        let st = model.status
        let same = file.area == .staged ? st.staged : (st.unstaged + st.untracked)
        if same.contains(where: { $0.path == file.path }) { return }
        let other = file.area == .staged ? (st.unstaged + st.untracked) : st.staged
        model.openDiff = other.first(where: { $0.path == file.path }).map { .working($0) }
    }

    // MARK: Unified

    private func renderUnified(_ doc: DiffDocument) {
        let tv = unified
        tv.text = ""
        let buf = tv.buffer
        let width = max(3, String(doc.maxLineNumber).count)
        var iter = GtkTextIter()
        let actions = hunkActions
        for (i, line) in doc.lines.enumerated() {
            gtk_text_buffer_get_end_iter(buf, &iter)
            let lineStart = gtk_text_iter_get_offset(&iter)
            switch line.kind {
            case .hunk:
                insert(buf, line.text, tags: ["hunk", "bold"])
                if !actions.isEmpty, line.hunk >= 0 {
                    insert(buf, "   ", tags: ["hunk"])
                    gtk_text_buffer_get_end_iter(buf, &iter)
                    for a in actions {
                        let anchor = gtk_text_buffer_create_child_anchor(buf, &iter)!
                        let hunk = line.hunk
                        let b = Button(a.title, "flat", a == .stage ? "success" : "error") { [weak self] in self?.hunkAction(a, hunk: hunk) }
                        b.css("caption")
                        gtk_text_view_add_child_at_anchor(tv.p(GtkTextView.self), b.w, anchor)
                        tv.keep(b)
                        gtk_text_buffer_get_end_iter(buf, &iter)
                    }
                }
            case .meta:
                insert(buf, line.text, tags: ["meta"])
            default:
                let old = line.old.map { String($0).leftPad(width) } ?? String(repeating: " ", count: width)
                let new = line.new.map { String($0).leftPad(width) } ?? String(repeating: " ", count: width)
                let sign = line.kind == .added ? "+" : line.kind == .removed ? "−" : " "
                insert(buf, "\(old) \(new) \(sign) ", tags: ["gutter"])
                let textStart = Int(gtk_text_buffer_get_char_count(buf))
                let kindTag = line.kind == .added ? "added" : line.kind == .removed ? "removed" : nil
                insert(buf, line.text, tags: kindTag.map { [$0] } ?? [])
                if let change = line.change, let kindTag {
                    highlight(buf, text: line.text, utf16: change, at: textStart, tag: kindTag + "-change")
                }
                if let kindTag { applyLineTag(buf, from: Int(lineStart), tag: kindTag) }
            }
            if i < doc.lines.count - 1 { insert(buf, "\n", tags: []) }
        }
    }

    // MARK: Split

    private func renderSplit(_ doc: DiffDocument) {
        left.text = ""
        right.text = ""
        let width = max(3, String(doc.maxLineNumber).count)
        for (i, row) in doc.splitRows.enumerated() {
            let nl = i < doc.splitRows.count - 1 ? "\n" : ""
            switch row.kind {
            case .hunk, .meta:
                let text = row.left.map { doc.lines[$0].text } ?? ""
                let tag = row.kind == .hunk ? "hunk" : "meta"
                insert(left.buffer, text + nl, tags: [tag])
                insert(right.buffer, text + nl, tags: [tag])
            case .code, .note:
                side(left.buffer, row.left.map { doc.lines[$0] }, number: { $0.old }, width: width, nl: nl)
                side(right.buffer, row.right.map { doc.lines[$0] }, number: { $0.new }, width: width, nl: nl)
            }
        }
    }

    private func side(_ buf: UnsafeMutablePointer<GtkTextBuffer>, _ line: DiffDocument.Line?, number: (DiffDocument.Line) -> Int?,
                      width: Int, nl: String) {
        var iter = GtkTextIter()
        gtk_text_buffer_get_end_iter(buf, &iter)
        let start = Int(gtk_text_iter_get_offset(&iter))
        guard let line else {
            insert(buf, " " + nl, tags: ["empty"])
            return
        }
        let n = number(line).map { String($0).leftPad(width) } ?? String(repeating: " ", count: width)
        insert(buf, n + " ", tags: ["gutter"])
        let textStart = Int(gtk_text_buffer_get_char_count(buf))
        let kindTag = line.kind == .added ? "added" : line.kind == .removed ? "removed" : (line.kind == .meta ? "meta" : nil)
        insert(buf, line.text, tags: kindTag.map { [$0] } ?? [])
        if let change = line.change, let kindTag, kindTag != "meta" {
            highlight(buf, text: line.text, utf16: change, at: textStart, tag: kindTag + "-change")
        }
        if let kindTag, kindTag != "meta" { applyLineTag(buf, from: start, tag: kindTag) }
        insert(buf, nl, tags: [])
    }

    // MARK: Text helpers

    private func insert(_ buf: UnsafeMutablePointer<GtkTextBuffer>, _ text: String, tags: [String]) {
        guard !text.isEmpty else { return }
        var iter = GtkTextIter()
        gtk_text_buffer_get_end_iter(buf, &iter)
        let start = gtk_text_iter_get_offset(&iter)
        gtk_text_buffer_insert(buf, &iter, text, -1)
        guard !tags.isEmpty else { return }
        var s = GtkTextIter(), e = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buf, &s, start)
        gtk_text_buffer_get_end_iter(buf, &e)
        for t in tags { gtk_text_buffer_apply_tag_by_name(buf, t, &s, &e) }
    }

    private func applyLineTag(_ buf: UnsafeMutablePointer<GtkTextBuffer>, from offset: Int, tag: String) {
        var s = GtkTextIter(), e = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buf, &s, Int32(offset))
        gtk_text_buffer_get_end_iter(buf, &e)
        gtk_text_buffer_apply_tag_by_name(buf, tag, &s, &e)
    }

    /// Marks the changed span (given in UTF-16 units) inside a just-inserted line.
    private func highlight(_ buf: UnsafeMutablePointer<GtkTextBuffer>, text: String, utf16 range: NSRange, at start: Int, tag: String) {
        let u = Array(text.utf16)
        guard range.location >= 0, range.location + range.length <= u.count, range.length > 0 else { return }
        let prefix = String(decoding: u[0..<range.location], as: UTF16.self).unicodeScalars.count
        let span = String(decoding: u[range.location..<(range.location + range.length)], as: UTF16.self).unicodeScalars.count
        var s = GtkTextIter(), e = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buf, &s, Int32(start + prefix))
        gtk_text_buffer_get_iter_at_offset(buf, &e, Int32(start + prefix + span))
        gtk_text_buffer_apply_tag_by_name(buf, tag, &s, &e)
    }

    // MARK: Hunk actions

    private func hunkAction(_ action: HunkAction, hunk: Int) {
        guard let t = target, case .working(let f) = t else { return }
        let doc = document
        if action == .discard {
            let lines = doc.newRange(ofHunk: hunk).map { " (lines \($0.lowerBound)–\($0.upperBound))" } ?? ""
            Dialogs.confirm(L("Discard this hunk?"),
                            String(localized: "Removes the change in \(f.fileName)\(lines) from the working copy. This can't be undone."),
                            confirm: L("Discard Hunk"), parent: root) { [weak self] in
                self?.runHunk(action, hunk: hunk, doc: doc, file: f)
            }
        } else {
            runHunk(action, hunk: hunk, doc: doc, file: f)
        }
    }

    private func runHunk(_ action: HunkAction, hunk: Int, doc: DiffDocument, file: FileChange) {
        guard let patch = doc.patch(forHunk: hunk) else { return }
        Task { [weak self] in
            guard let self else { return }
            if await self.model.applyHunk(patch, action, zeroContext: !doc.hunks[hunk].hasContext) {
                self.follow(file)
            }
        }
    }
}

extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
