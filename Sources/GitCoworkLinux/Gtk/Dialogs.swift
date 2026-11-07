import CGtk
import Foundation

/// Alerts, confirmations, small forms and pickers (libadwaita dialogs).
@MainActor
enum Dialogs {
    /// Dialogs being shown, kept alive until they answer.
    private static var open: [ObjectIdentifier: AnyObject] = [:]

    /// A message with an OK button.
    static func alert(_ title: String, _ message: String, parent: Widget?) {
        let d = AlertDialog(title, message)
        d.addResponse("ok", L("OK"))
        d.present(parent) { _ in }
    }

    /// Asks before doing something; `action` runs on confirm.
    static func confirm(_ title: String, _ message: String, confirm: String, destructive: Bool = true,
                        parent: Widget?, action: @escaping Action) {
        let d = AlertDialog(title, message)
        d.addResponse("cancel", L("Cancel"))
        d.addResponse("ok", confirm, appearance: destructive ? ADW_RESPONSE_DESTRUCTIVE : ADW_RESPONSE_SUGGESTED)
        d.defaultResponse("cancel")
        d.present(parent) { if $0 == "ok" { action() } }
    }

    /// A small form: `content` below the message, OK runs `done` (return false to keep the dialog open).
    static func form(_ title: String, message: String = "", content: Widget, confirm: String,
                     destructive: Bool = false, parent: Widget?, focus: Widget? = nil,
                     done: @escaping @MainActor () -> Bool) -> AlertDialog {
        let d = AlertDialog(title, message)
        d.setExtra(content)
        d.addResponse("cancel", L("Cancel"))
        d.addResponse("ok", confirm, appearance: destructive ? ADW_RESPONSE_DESTRUCTIVE : ADW_RESPONSE_SUGGESTED)
        d.defaultResponse("ok")
        d.closeResponse("cancel")
        d.present(parent, keepOpen: { $0 == "ok" && !done() }) { _ in }
        if let focus { DispatchQueue.main.async { focus.grabFocus() } }
        return d
    }

    static func retain(_ o: AnyObject) { open[ObjectIdentifier(o)] = o }
    static func release(_ o: AnyObject) { open[ObjectIdentifier(o)] = nil }

    /// Folder picker. Calls `done` with the chosen path.
    static func chooseFolder(title: String, parent: Widget?, done: @escaping @MainActor (String) -> Void) {
        let dialog = gtk_file_dialog_new()!
        gtk_file_dialog_set_title(dialog, title)
        gtk_file_dialog_set_modal(dialog, 1)
        let box = Unmanaged.passRetained(ClosureBox(done)).toOpaque()
        gtk_file_dialog_select_folder(dialog, parent?.window, nil, { source, result, data in
            let fn = Unmanaged<ClosureBox>.fromOpaque(data!).takeRetainedValue().fn as! @MainActor (String) -> Void
            var error: UnsafeMutablePointer<GError>?
            let file = gtk_file_dialog_select_folder_finish(OpaquePointer(source), result, &error)
            if let error { g_error_free(error) }
            guard let file else { return }
            defer { g_object_unref(RawPtr(file)) }
            guard let cPath = g_file_get_path(file) else { return }
            let path = String(cString: cPath)
            g_free(cPath)
            MainActor.assumeIsolated { fn(path) }
        }, box)
        g_object_unref(RP(dialog))
    }

    /// A small toast at the bottom of the window.
    static func toast(_ text: String, in overlay: Widget?) {
        guard let overlay else { return }
        let t = adw_toast_new(text)
        adw_toast_set_timeout(t, 3)
        adw_toast_overlay_add_toast(overlay.op, t)
    }
}

/// adw_alert_dialog with Swift responses.
@MainActor
final class AlertDialog {
    let raw: RawPtr
    private var extra: Widget?
    private var onResponse: ((String) -> Void)?

    private var ad: UnsafeMutablePointer<AdwAlertDialog> { raw.assumingMemoryBound(to: AdwAlertDialog.self) }
    private var dlg: UnsafeMutablePointer<AdwDialog> { raw.assumingMemoryBound(to: AdwDialog.self) }

    init(_ heading: String, _ body: String) {
        raw = RP(gc_alert_new(heading, body))
        g_object_ref_sink(raw)
        Signal.onString(raw, "response") { [weak self] response in
            self?.onResponse?(response)
        }
        Signal.on(raw, "closed") { [weak self] in
            guard let self else { return }
            Dialogs.release(self)
        }
    }

    deinit { g_object_unref(raw) }

    func addResponse(_ id: String, _ label: String, appearance: AdwResponseAppearance = ADW_RESPONSE_DEFAULT) {
        adw_alert_dialog_add_response(ad, id, label)
        adw_alert_dialog_set_response_appearance(ad, id, appearance)
    }
    func defaultResponse(_ id: String) { adw_alert_dialog_set_default_response(ad, id) }
    func closeResponse(_ id: String) { adw_alert_dialog_set_close_response(ad, id) }
    func setExtra(_ w: Widget) { adw_alert_dialog_set_extra_child(ad, w.w); extra = w }
    func setEnabled(_ id: String, _ enabled: Bool) { adw_alert_dialog_set_response_enabled(ad, id, gbool(enabled)) }
    func setBody(_ body: String) { adw_alert_dialog_set_body(ad, body) }

    /// Shows the dialog. With `keepOpen` returning true for a response, the
    /// dialog stays (a form whose input isn't valid yet shows why and waits).
    func present(_ parent: Widget?, keepOpen: ((String) -> Bool)? = nil, _ handler: @escaping (String) -> Void) {
        Dialogs.retain(self)
        if let keepOpen {
            // With can-close off, a response is emitted but the dialog stays;
            // we close it ourselves once the form is fine.
            adw_dialog_set_can_close(dlg, 0)
            onResponse = { [weak self] response in
                guard let self else { return }
                if keepOpen(response) { return }
                handler(response)
                self.close()
            }
        } else {
            onResponse = handler
        }
        adw_dialog_present(dlg, parent?.w)
    }

    func close() {
        adw_dialog_set_can_close(dlg, 1)
        adw_dialog_force_close(dlg)
    }
}

/// A list of actions shown in a popover, used for context menus and ▾ menus.
@MainActor
struct MenuItem {
    var title: String
    var icon: String?
    var destructive = false
    var enabled = true
    var action: Action?
    var isSeparator = false
    var isHeader = false

    init(_ title: String, icon: String? = nil, destructive: Bool = false, enabled: Bool = true, action: @escaping Action) {
        self.title = title; self.icon = icon; self.destructive = destructive; self.enabled = enabled; self.action = action
    }
    private init(separator: Bool, header: String = "") {
        title = header; isSeparator = separator; isHeader = !separator
    }
    static let separator = MenuItem(separator: true)
    static func header(_ title: String) -> MenuItem { MenuItem(separator: false, header: title) }
}

@MainActor
enum Menus {
    /// Fills a popover with menu rows.
    static func fill(_ popover: Popover, _ items: [MenuItem]) {
        let box = Box.v(0)
        box.css("gc-menu")
        for item in items {
            if item.isSeparator { box.append(Separator().margins(4, 0, 4, 0)); continue }
            if item.isHeader {
                box.append(Label(item.title, "dim-label", "caption-heading").margins(6, 10, 2, 10))
                continue
            }
            let row = Box.h(8)
            if let icon = item.icon { row.append(Image(icon)) }
            row.append(Label(item.title).hexpand())
            let b = Button(nil, "flat", "gc-menu-item")
            b.setChild(row)
            b.sensitive = item.enabled
            if item.destructive { b.css("error") }
            let action = item.action
            b.onClicked { [weak popover] in
                popover?.popdown()
                // Let the popover close before the action opens a dialog.
                DispatchQueue.main.async { MainActor.assumeIsolated { action?() } }
            }
            box.append(b)
        }
        popover.setChild(box)
    }

    /// Context menu at (x, y) inside `widget`.
    static func popup(_ items: [MenuItem], at x: Double, _ y: Double, in widget: Widget) {
        guard !items.isEmpty else { return }
        let popover = Popover()
        popover.noArrow()
        gtk_widget_set_parent(popover.w, widget.w)
        popover.point(at: x, y)
        fill(popover, items)
        // Unparent once closed (and drop our reference with it).
        let holder = Holder(popover)
        Signal.on(popover.raw, "closed") {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    gtk_widget_unparent(holder.popover?.w)
                    holder.popover = nil
                }
            }
        }
        popover.popup()
    }

    private final class Holder {
        var popover: Popover?
        init(_ p: Popover) { popover = p }
    }
}
