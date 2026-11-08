import CGtk
import Foundation
import Observation

// A thin Swift layer over the GTK 4 / libadwaita C API: one class per widget
// kind we use, closures for signals, and a tracker that re-renders a piece of
// UI when the @Observable models it read change. No third-party bindings.

typealias RawPtr = UnsafeMutableRawPointer

func gbool(_ b: Bool) -> gboolean { b ? 1 : 0 }

/// Pointer conversions between the ways GTK types come into Swift
/// (struct pointers, or OpaquePointer for final types).
func OP<T>(_ p: UnsafeMutablePointer<T>) -> OpaquePointer { OpaquePointer(p) }
func OP(_ p: OpaquePointer) -> OpaquePointer { p }
func OP(_ p: RawPtr) -> OpaquePointer { OpaquePointer(p) }
func RP<T>(_ p: UnsafeMutablePointer<T>) -> RawPtr { RawPtr(p) }
func RP(_ p: OpaquePointer) -> RawPtr { RawPtr(p) }
func RP(_ p: RawPtr) -> RawPtr { p }

// MARK: Signals

/// Holds a Swift closure for the lifetime of a signal connection.
final class ClosureBox {
    let fn: Any
    init(_ fn: Any) { self.fn = fn }
}

private let releaseBox: GClosureNotify = { data, _ in
    if let data { Unmanaged<ClosureBox>.fromOpaque(data).release() }
}

private func box(_ fn: Any) -> RawPtr { Unmanaged.passRetained(ClosureBox(fn)).toOpaque() }
private func unbox<T>(_ data: RawPtr?) -> T? { data.flatMap { Unmanaged<ClosureBox>.fromOpaque($0).takeUnretainedValue().fn as? T } }

typealias Action = @MainActor () -> Void

@discardableResult
private func connectRaw(_ instance: RawPtr, _ signal: String, _ thunk: GCallback, _ fn: Any) -> UInt {
    UInt(g_signal_connect_data(instance, signal, thunk, box(fn), releaseBox, GConnectFlags(rawValue: 0)))
}

private let thunkVoid: @convention(c) (RawPtr?, RawPtr?) -> Void = { _, data in
    guard let fn: Action = unbox(data) else { return }
    MainActor.assumeIsolated { fn() }
}
private let thunkPtr: @convention(c) (RawPtr?, RawPtr?, RawPtr?) -> Void = { _, arg, data in
    guard let fn: @MainActor (RawPtr?) -> Void = unbox(data) else { return }
    MainActor.assumeIsolated { fn(arg) }
}
private let thunkBool: @convention(c) (RawPtr?, RawPtr?) -> gboolean = { _, data in
    guard let fn: @MainActor () -> Bool = unbox(data) else { return 0 }
    return MainActor.assumeIsolated { gbool(fn()) }
}
private let thunkPtrBool: @convention(c) (RawPtr?, RawPtr?, RawPtr?) -> gboolean = { _, arg, data in
    guard let fn: @MainActor (RawPtr?) -> Bool = unbox(data) else { return 0 }
    return MainActor.assumeIsolated { gbool(fn(arg)) }
}
private let thunkPressed: @convention(c) (RawPtr?, Int32, Double, Double, RawPtr?) -> Void = { gesture, n, x, y, data in
    guard let fn: @MainActor (RawPtr?, Int, Double, Double) -> Void = unbox(data) else { return }
    MainActor.assumeIsolated { fn(gesture, Int(n), x, y) }
}
private let thunkXY: @convention(c) (RawPtr?, Double, Double, RawPtr?) -> Void = { _, x, y, data in
    guard let fn: @MainActor (Double, Double) -> Void = unbox(data) else { return }
    MainActor.assumeIsolated { fn(x, y) }
}
private let thunkScroll: @convention(c) (RawPtr?, Double, Double, RawPtr?) -> gboolean = { _, dx, dy, data in
    guard let fn: @MainActor (Double, Double) -> Bool = unbox(data) else { return 0 }
    return MainActor.assumeIsolated { gbool(fn(dx, dy)) }
}
private let thunkKey: @convention(c) (RawPtr?, guint, guint, GdkModifierType, RawPtr?) -> gboolean = { _, keyval, _, state, data in
    guard let fn: @MainActor (UInt32, GdkModifierType) -> Bool = unbox(data) else { return 0 }
    return MainActor.assumeIsolated { gbool(fn(keyval, state)) }
}
private let thunkString: @convention(c) (RawPtr?, UnsafePointer<CChar>?, RawPtr?) -> Void = { _, s, data in
    guard let fn: @MainActor (String) -> Void = unbox(data) else { return }
    let value = s.map { String(cString: $0) } ?? ""
    MainActor.assumeIsolated { fn(value) }
}
private let thunkIntInt: @convention(c) (RawPtr?, Int32, Int32, RawPtr?) -> Void = { _, a, b, data in
    guard let fn: @MainActor (Int, Int) -> Void = unbox(data) else { return }
    MainActor.assumeIsolated { fn(Int(a), Int(b)) }
}
private let thunkProvider: @convention(c) (RawPtr?, Double, Double, RawPtr?) -> UnsafeMutablePointer<GdkContentProvider>? = { _, _, _, data in
    guard let fn: @MainActor () -> String = unbox(data) else { return nil }
    let text = MainActor.assumeIsolated { fn() }
    return gc_string_provider(text)
}
private let thunkDropString: @convention(c) (RawPtr?, UnsafePointer<GValue>?, Double, Double, RawPtr?) -> gboolean = { _, value, _, _, data in
    guard let fn: @MainActor (String) -> Bool = unbox(data), let value, let s = gc_value_string(value) else { return 0 }
    let text = String(cString: s)
    return MainActor.assumeIsolated { gbool(fn(text)) }
}
private let thunkDrop: @convention(c) (RawPtr?, UnsafePointer<GValue>?, Double, Double, RawPtr?) -> gboolean = { _, value, _, _, data in
    guard let fn: @MainActor ([String]) -> Bool = unbox(data), let value else { return 0 }
    var paths: [String] = []
    if let list = gc_dropped_paths(value) {
        var i = 0
        while let p = list[i] { paths.append(String(cString: p)); i += 1 }
        g_strfreev(list)
    }
    return MainActor.assumeIsolated { gbool(fn(paths)) }
}

enum Signal {
    @discardableResult
    static func on(_ instance: RawPtr, _ signal: String, _ fn: @escaping Action) -> UInt {
        connectRaw(instance, signal, unsafeBitCast(thunkVoid, to: GCallback.self), fn)
    }
    @discardableResult
    static func onPtr(_ instance: RawPtr, _ signal: String, _ fn: @escaping @MainActor (RawPtr?) -> Void) -> UInt {
        connectRaw(instance, signal, unsafeBitCast(thunkPtr, to: GCallback.self), fn)
    }
    @discardableResult
    static func onBool(_ instance: RawPtr, _ signal: String, _ fn: @escaping @MainActor () -> Bool) -> UInt {
        connectRaw(instance, signal, unsafeBitCast(thunkBool, to: GCallback.self), fn)
    }
    @discardableResult
    static func onPtrBool(_ instance: RawPtr, _ signal: String, _ fn: @escaping @MainActor (RawPtr?) -> Bool) -> UInt {
        connectRaw(instance, signal, unsafeBitCast(thunkPtrBool, to: GCallback.self), fn)
    }
    @discardableResult
    static func onPressed(_ instance: RawPtr, _ fn: @escaping @MainActor (RawPtr?, Int, Double, Double) -> Void) -> UInt {
        connectRaw(instance, "pressed", unsafeBitCast(thunkPressed, to: GCallback.self), fn)
    }
    @discardableResult
    static func onXY(_ instance: RawPtr, _ signal: String, _ fn: @escaping @MainActor (Double, Double) -> Void) -> UInt {
        connectRaw(instance, signal, unsafeBitCast(thunkXY, to: GCallback.self), fn)
    }
    @discardableResult
    static func onScroll(_ instance: RawPtr, _ fn: @escaping @MainActor (Double, Double) -> Bool) -> UInt {
        connectRaw(instance, "scroll", unsafeBitCast(thunkScroll, to: GCallback.self), fn)
    }
    @discardableResult
    static func onKey(_ instance: RawPtr, _ fn: @escaping @MainActor (UInt32, GdkModifierType) -> Bool) -> UInt {
        connectRaw(instance, "key-pressed", unsafeBitCast(thunkKey, to: GCallback.self), fn)
    }
    @discardableResult
    static func onString(_ instance: RawPtr, _ signal: String, _ fn: @escaping @MainActor (String) -> Void) -> UInt {
        connectRaw(instance, signal, unsafeBitCast(thunkString, to: GCallback.self), fn)
    }
    /// Signals with two int arguments, e.g. GtkDrawingArea "resize".
    @discardableResult
    static func onIntInt(_ instance: RawPtr, _ signal: String, _ fn: @escaping @MainActor (Int, Int) -> Void) -> UInt {
        connectRaw(instance, signal, unsafeBitCast(thunkIntInt, to: GCallback.self), fn)
    }
    /// GtkDragSource "prepare": the dragged content is the returned string.
    @discardableResult
    static func onXYProvider(_ instance: RawPtr, _ fn: @escaping @MainActor () -> String) -> UInt {
        connectRaw(instance, "prepare", unsafeBitCast(thunkProvider, to: GCallback.self), fn)
    }
    /// GtkDropTarget "drop" with a string.
    @discardableResult
    static func onDropString(_ instance: RawPtr, _ fn: @escaping @MainActor (String) -> Bool) -> UInt {
        connectRaw(instance, "drop", unsafeBitCast(thunkDropString, to: GCallback.self), fn)
    }
    @discardableResult
    static func onDrop(_ instance: RawPtr, _ fn: @escaping @MainActor ([String]) -> Bool) -> UInt {
        connectRaw(instance, "drop", unsafeBitCast(thunkDrop, to: GCallback.self), fn)
    }
}

// MARK: Observation

/// Runs `render` now and again whenever an @Observable property it read
/// changes. Changes are coalesced into one re-render per main-loop turn.
@MainActor
final class Tracker {
    private let render: @MainActor () -> Void
    private var scheduled = false
    private var cancelled = false

    @discardableResult
    init(_ render: @escaping @MainActor () -> Void) {
        self.render = render
        run()
    }

    func cancel() { cancelled = true }

    private func run() {
        scheduled = false
        guard !cancelled else { return }
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.schedule() } }
        }
    }

    private func schedule() {
        guard !scheduled, !cancelled else { return }
        scheduled = true
        DispatchQueue.main.async { MainActor.assumeIsolated { self.run() } }
    }
}

// MARK: Widgets

@MainActor
class Widget {
    let raw: RawPtr
    /// Trackers and helpers that live as long as this wrapper.
    var retained: [AnyObject] = []

    init(raw: RawPtr) {
        self.raw = raw
        g_object_ref_sink(raw)
    }
    convenience init(_ w: UnsafeMutablePointer<GtkWidget>) { self.init(raw: RawPtr(w)) }
    convenience init(op: OpaquePointer) { self.init(raw: RawPtr(op)) }

    deinit {
        g_object_unref(raw)
    }

    var w: UnsafeMutablePointer<GtkWidget> { raw.assumingMemoryBound(to: GtkWidget.self) }
    var op: OpaquePointer { OpaquePointer(raw) }
    func p<T>(_: T.Type = T.self) -> UnsafeMutablePointer<T> { raw.assumingMemoryBound(to: T.self) }

    @discardableResult func hexpand(_ v: Bool = true) -> Self { gtk_widget_set_hexpand(w, gbool(v)); return self }
    @discardableResult func vexpand(_ v: Bool = true) -> Self { gtk_widget_set_vexpand(w, gbool(v)); return self }
    @discardableResult func halign(_ a: GtkAlign) -> Self { gtk_widget_set_halign(w, a); return self }
    @discardableResult func valign(_ a: GtkAlign) -> Self { gtk_widget_set_valign(w, a); return self }
    @discardableResult func css(_ classes: String...) -> Self { for c in classes { gtk_widget_add_css_class(w, c) }; return self }
    @discardableResult func uncss(_ c: String) -> Self { gtk_widget_remove_css_class(w, c); return self }
    func setCSS(_ c: String, _ on: Bool) { if on { gtk_widget_add_css_class(w, c) } else { gtk_widget_remove_css_class(w, c) } }
    @discardableResult func tooltip(_ t: String?) -> Self { gtk_widget_set_tooltip_text(w, t); return self }
    @discardableResult func margin(_ m: Int32) -> Self { margins(m, m, m, m) }
    @discardableResult func margins(_ top: Int32, _ end: Int32, _ bottom: Int32, _ start: Int32) -> Self {
        gtk_widget_set_margin_top(w, top); gtk_widget_set_margin_end(w, end)
        gtk_widget_set_margin_bottom(w, bottom); gtk_widget_set_margin_start(w, start)
        return self
    }
    @discardableResult func size(_ width: Int32, _ height: Int32) -> Self { gtk_widget_set_size_request(w, width, height); return self }
    @discardableResult func name(_ n: String) -> Self { gtk_widget_set_name(w, n); return self }
    var visible: Bool {
        get { gtk_widget_get_visible(w) != 0 }
        set { gtk_widget_set_visible(w, gbool(newValue)) }
    }
    var sensitive: Bool {
        get { gtk_widget_get_sensitive(w) != 0 }
        set { gtk_widget_set_sensitive(w, gbool(newValue)) }
    }
    func grabFocus() { _ = gtk_widget_grab_focus(w) }
    func queueDraw() { gtk_widget_queue_draw(w) }
    var width: Int { Int(gtk_widget_get_width(w)) }
    var height: Int { Int(gtk_widget_get_height(w)) }
    /// Accessible name for screen readers and UI tests.
    @discardableResult func label(_ text: String) -> Self {
        var value = GValue()
        g_value_init(&value, GType(16 << 2))   // G_TYPE_STRING
        g_value_set_string(&value, text)
        var properties = [GTK_ACCESSIBLE_PROPERTY_LABEL]
        var values = [value]
        gtk_accessible_update_property_value(OpaquePointer(raw), 1, &properties, &values)
        g_value_unset(&values[0])
        return self
    }

    /// The toplevel window this widget is in.
    var window: UnsafeMutablePointer<GtkWindow>? {
        guard let root = gtk_widget_get_root(w) else { return nil }
        return RawPtr(root).assumingMemoryBound(to: GtkWindow.self)
    }

    func keep(_ o: AnyObject) { retained.append(o) }

    /// Re-renders with `body` whenever models it reads change.
    func track(_ body: @escaping @MainActor () -> Void) {
        retained.append(Tracker(body))
    }

    func addController<T>(_ controller: UnsafeMutablePointer<T>) { gtk_widget_add_controller(w, OpaquePointer(controller)) }
    func addController(_ controller: OpaquePointer) { gtk_widget_add_controller(w, controller) }

    /// Click handler (any button). `button` is 1 left, 2 middle, 3 right.
    func onClick(button: UInt32 = 0, _ fn: @escaping @MainActor (_ button: UInt32, _ count: Int, _ x: Double, _ y: Double) -> Void) {
        let g = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(OP(g), button)
        Signal.onPressed(RP(g)) { gesture, n, x, y in
            let b = gesture.map { gtk_gesture_single_get_current_button(OP($0)) } ?? 1
            fn(b, n, x, y)
        }
        addController(OP(g))
    }

    /// Right click (or long press) for context menus.
    func onContextMenu(_ fn: @escaping @MainActor (_ x: Double, _ y: Double) -> Void) {
        onClick(button: 3) { _, _, x, y in fn(x, y) }
        let lp = gtk_gesture_long_press_new()!
        Signal.onXY(RP(lp), "pressed") { x, y in fn(x, y) }
        gtk_gesture_single_set_touch_only(OP(lp), 1)
        addController(OP(lp))
    }

    func onKey(_ fn: @escaping @MainActor (UInt32, GdkModifierType) -> Bool) {
        let c = gtk_event_controller_key_new()!
        Signal.onKey(RP(c), fn)
        addController(OP(c))
    }

    /// Files or folders dropped on the widget.
    func onDropFiles(_ fn: @escaping @MainActor ([String]) -> Bool) {
        let t = gtk_drop_target_new(gc_file_list_type(), GDK_ACTION_COPY)!
        Signal.onDrop(RP(t), fn)
        addController(OP(t))
    }
}

final class Label: Widget {
    init(_ text: String = "", _ classes: String...) {
        super.init(raw: RawPtr(gtk_label_new(text)))
        gtk_label_set_xalign(op, 0)
        for c in classes { gtk_widget_add_css_class(w, c) }
    }
    var text: String {
        get { String(cString: gtk_label_get_text(op)) }
        set { if text != newValue { gtk_label_set_text(op, newValue) } }
    }
    func markup(_ m: String) { gtk_label_set_markup(op, m) }
    @discardableResult func ellipsize(_ mode: PangoEllipsizeMode = PANGO_ELLIPSIZE_END) -> Self { gtk_label_set_ellipsize(op, mode); return self }
    @discardableResult func wrap(_ v: Bool = true) -> Self {
        gtk_label_set_wrap(op, gbool(v))
        gtk_label_set_wrap_mode(op, PANGO_WRAP_WORD_CHAR)
        return self
    }
    /// Text can be selected with the mouse; the label doesn't take keyboard
    /// focus (it would grab it, all text selected, whenever a panel rebuilds).
    @discardableResult func selectable(_ v: Bool = true) -> Self {
        gtk_label_set_selectable(op, gbool(v))
        gtk_widget_set_focusable(w, 0)
        return self
    }
    @discardableResult func xalign(_ v: Float) -> Self { gtk_label_set_xalign(op, v); return self }
    @discardableResult func lines(_ n: Int32) -> Self { gtk_label_set_lines(op, n); return self }
    @discardableResult func maxChars(_ n: Int32) -> Self { gtk_label_set_max_width_chars(op, n); return self }
}

final class Button: Widget {
    /// AdwButtonContent when the button has an icon and a label.
    private var content: OpaquePointer?

    init(_ label: String? = nil, icon: String? = nil, _ classes: String..., action: Action? = nil) {
        let b: UnsafeMutablePointer<GtkWidget>
        if let label, let icon {
            b = gtk_button_new()
            let content = adw_button_content_new()!
            adw_button_content_set_icon_name(OpaquePointer(content), icon)
            adw_button_content_set_label(OpaquePointer(content), label)
            gtk_button_set_child(RawPtr(b).assumingMemoryBound(to: GtkButton.self), content)
            self.content = OpaquePointer(content)
        } else if let icon {
            b = gtk_button_new_from_icon_name(icon)
        } else {
            b = gtk_button_new_with_label(label ?? "")
        }
        super.init(raw: RawPtr(b))
        for c in classes { gtk_widget_add_css_class(w, c) }
        if let label, icon != nil { _ = self.label(label) }
        if let action { onClicked(action) }
    }
    func onClicked(_ fn: @escaping Action) { Signal.on(raw, "clicked", fn) }
    func setLabel(_ s: String) {
        if let content { adw_button_content_set_label(content, s) } else { gtk_button_set_label(p(GtkButton.self), s) }
    }
    func setChild(_ c: Widget) { gtk_button_set_child(p(GtkButton.self), c.w); keep(c) }
}

final class Box: Widget {
    private(set) var children: [Widget] = []

    init(_ orientation: GtkOrientation = GTK_ORIENTATION_VERTICAL, spacing: Int32 = 0, _ classes: String...) {
        super.init(raw: RawPtr(gtk_box_new(orientation, spacing)))
        for c in classes { gtk_widget_add_css_class(w, c) }
    }
    static func h(_ spacing: Int32 = 6, _ items: [Widget] = []) -> Box {
        let b = Box(GTK_ORIENTATION_HORIZONTAL, spacing: spacing)
        items.forEach { b.append($0) }
        return b
    }
    static func v(_ spacing: Int32 = 6, _ items: [Widget] = []) -> Box {
        let b = Box(GTK_ORIENTATION_VERTICAL, spacing: spacing)
        items.forEach { b.append($0) }
        return b
    }
    @discardableResult func append(_ child: Widget) -> Self {
        gtk_box_append(p(GtkBox.self), child.w)
        children.append(child)
        return self
    }
    func prepend(_ child: Widget) {
        gtk_box_prepend(p(GtkBox.self), child.w)
        children.insert(child, at: 0)
    }
    func remove(_ child: Widget) {
        gtk_box_remove(p(GtkBox.self), child.w)
        children.removeAll { $0 === child }
    }
    func removeAll() {
        for c in children { gtk_box_remove(p(GtkBox.self), c.w) }
        children.removeAll()
    }
    @discardableResult func homogeneous(_ v: Bool = true) -> Self { gtk_box_set_homogeneous(p(GtkBox.self), gbool(v)); return self }
}

/// Fills the space between items in a Box.
@MainActor func spacer() -> Widget { Box().hexpand() }

final class Entry: Widget {
    init(placeholder: String = "", text: String = "", search: Bool = false) {
        super.init(raw: RawPtr(search ? gtk_search_entry_new() : gtk_entry_new()))
        if search {
            gc_object_set_string(raw, "placeholder-text", placeholder)
        } else {
            gtk_entry_set_placeholder_text(p(GtkEntry.self), placeholder)
            // Enter in a dialog's field answers with the default response.
            gtk_entry_set_activates_default(p(GtkEntry.self), 1)
        }
        self.text = text
    }
    var text: String {
        get { String(cString: gtk_editable_get_text(OpaquePointer(raw))) }
        set { if text != newValue { gtk_editable_set_text(OpaquePointer(raw), newValue) } }
    }
    func onChanged(_ fn: @escaping Action) { Signal.on(raw, "changed", fn) }
    func onActivate(_ fn: @escaping Action) { Signal.on(raw, "activate", fn) }
    func selectAll() { gtk_editable_select_region(OpaquePointer(raw), 0, -1) }
}

final class TextView: Widget {
    init(text: String = "", monospace: Bool = false, editable: Bool = true) {
        super.init(raw: RawPtr(gtk_text_view_new()))
        gtk_text_view_set_wrap_mode(p(GtkTextView.self), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_monospace(p(GtkTextView.self), gbool(monospace))
        gtk_text_view_set_editable(p(GtkTextView.self), gbool(editable))
        gtk_text_view_set_cursor_visible(p(GtkTextView.self), gbool(editable))
        gtk_text_view_set_top_margin(p(GtkTextView.self), 6)
        gtk_text_view_set_bottom_margin(p(GtkTextView.self), 6)
        gtk_text_view_set_left_margin(p(GtkTextView.self), 6)
        gtk_text_view_set_right_margin(p(GtkTextView.self), 6)
        self.text = text
    }
    var buffer: UnsafeMutablePointer<GtkTextBuffer> { gtk_text_view_get_buffer(p(GtkTextView.self)) }
    var text: String {
        get {
            var start = GtkTextIter(), end = GtkTextIter()
            gtk_text_buffer_get_bounds(buffer, &start, &end)
            guard let c = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
            defer { g_free(c) }
            return String(cString: c)
        }
        set { gtk_text_buffer_set_text(buffer, newValue, -1) }
    }
    func onChanged(_ fn: @escaping Action) { Signal.on(RawPtr(buffer), "changed", fn) }
    func wrap(_ mode: GtkWrapMode) { gtk_text_view_set_wrap_mode(p(GtkTextView.self), mode) }
}

final class Scrolled: Widget {
    private var child: Widget?
    init(_ child: Widget? = nil, hscroll: Bool = false) {
        super.init(raw: RawPtr(gtk_scrolled_window_new()))
        gtk_scrolled_window_set_policy(op, hscroll ? GTK_POLICY_AUTOMATIC : GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        if let child { setChild(child) }
    }
    func setChild(_ c: Widget?) {
        gtk_scrolled_window_set_child(op, c?.w)
        child = c
    }
    var vadjustment: UnsafeMutablePointer<GtkAdjustment> { gtk_scrolled_window_get_vadjustment(op) }
    var scrollY: Double {
        get { gtk_adjustment_get_value(vadjustment) }
        set { gtk_adjustment_set_value(vadjustment, newValue) }
    }
    @discardableResult func minHeight(_ h: Int32) -> Self { gtk_scrolled_window_set_min_content_height(op, h); return self }
    @discardableResult func propagateHeight(_ v: Bool = true) -> Self { gtk_scrolled_window_set_propagate_natural_height(op, gbool(v)); return self }
}

final class Paned: Widget {
    private var start: Widget?, end: Widget?
    init(_ orientation: GtkOrientation = GTK_ORIENTATION_HORIZONTAL, start: Widget? = nil, end: Widget? = nil, position: Int32? = nil) {
        super.init(raw: RawPtr(gtk_paned_new(orientation)))
        if let start { setStart(start) }
        if let end { setEnd(end) }
        if let position { gtk_paned_set_position(op, position) }
        gtk_paned_set_shrink_start_child(op, 0)
        gtk_paned_set_shrink_end_child(op, 0)
    }
    func setStart(_ c: Widget?) { gtk_paned_set_start_child(op, c?.w); start = c }
    func setEnd(_ c: Widget?) { gtk_paned_set_end_child(op, c?.w); end = c }
    var position: Int32 {
        get { gtk_paned_get_position(op) }
        set { gtk_paned_set_position(op, newValue) }
    }
    func resizeStart(_ v: Bool) { gtk_paned_set_resize_start_child(op, gbool(v)) }
    func resizeEnd(_ v: Bool) { gtk_paned_set_resize_end_child(op, gbool(v)) }
}

/// A list of rows, each a widget with an optional click action.
final class ListBox: Widget {
    private var rows: [(row: UnsafeMutablePointer<GtkWidget>, widget: Widget, action: Action?, menu: (@MainActor (Double, Double, Widget) -> Void)?)] = []

    init(_ classes: String...) {
        super.init(raw: RawPtr(gtk_list_box_new()))
        gtk_list_box_set_selection_mode(op, GTK_SELECTION_NONE)
        for c in classes { gtk_widget_add_css_class(w, c) }
        Signal.onPtr(raw, "row-activated") { [weak self] row in
            guard let self, let row else { return }
            let index = Int(gtk_list_box_row_get_index(row.assumingMemoryBound(to: GtkListBoxRow.self)))
            if self.rows.indices.contains(index) { self.rows[index].action?() }
        }
    }

    func removeAll() {
        gtk_list_box_remove_all(op)
        rows.removeAll()
    }

    /// Adds a row. `action` runs on click / Enter; `menu` on right click.
    func append(_ child: Widget, activatable: Bool = true, selected: Bool = false,
                action: Action? = nil, menu: (@MainActor (Double, Double, Widget) -> Void)? = nil) {
        let row = gtk_list_box_row_new()!
        gtk_list_box_row_set_child(RawPtr(row).assumingMemoryBound(to: GtkListBoxRow.self), child.w)
        gtk_list_box_row_set_activatable(RawPtr(row).assumingMemoryBound(to: GtkListBoxRow.self), gbool(activatable && action != nil))
        gtk_list_box_row_set_selectable(RawPtr(row).assumingMemoryBound(to: GtkListBoxRow.self), 0)
        if selected { gtk_widget_add_css_class(row, "gc-selected") }
        gtk_list_box_append(op, row)
        rows.append((row, child, action, menu))
        if let menu {
            child.onContextMenu { [weak child] x, y in
                guard let child else { return }
                menu(x, y, child)
            }
        }
    }

    var count: Int { rows.count }
    func setPlaceholder(_ widget: Widget) {
        gtk_list_box_set_placeholder(op, widget.w)
        keep(widget)
    }
}

final class Stack: Widget {
    private var pages: [String: Widget] = [:]
    init() {
        super.init(raw: RawPtr(gtk_stack_new()))
        gtk_stack_set_transition_type(op, GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_stack_set_transition_duration(op, 120)
    }
    func add(_ name: String, _ child: Widget) {
        gtk_stack_add_named(op, child.w, name)
        pages[name] = child
    }
    var visibleName: String? {
        get { gtk_stack_get_visible_child_name(op).map { String(cString: $0) } }
        set { if let newValue, newValue != visibleName { gtk_stack_set_visible_child_name(op, newValue) } }
    }
}

final class Switch: Widget {
    init(_ on: Bool = false, onToggle: (@MainActor (Bool) -> Void)? = nil) {
        super.init(raw: RawPtr(gtk_switch_new()))
        gtk_switch_set_active(op, gbool(on))
        gtk_widget_set_valign(w, GTK_ALIGN_CENTER)
        if let onToggle {
            Signal.onPtr(raw, "notify::active") { [weak self] _ in
                guard let self else { return }
                onToggle(self.isOn)
            }
        }
    }
    var isOn: Bool {
        get { gtk_switch_get_active(op) != 0 }
        set { gtk_switch_set_active(op, gbool(newValue)) }
    }
}

final class Check: Widget {
    init(_ label: String, _ on: Bool = false, onToggle: (@MainActor (Bool) -> Void)? = nil) {
        super.init(raw: RawPtr(gtk_check_button_new_with_label(label)))
        gtk_check_button_set_active(p(GtkCheckButton.self), gbool(on))
        if let onToggle {
            Signal.on(raw, "toggled") { [weak self] in
                guard let self else { return }
                onToggle(self.isOn)
            }
        }
    }
    var isOn: Bool {
        get { gtk_check_button_get_active(p(GtkCheckButton.self)) != 0 }
        set { gtk_check_button_set_active(p(GtkCheckButton.self), gbool(newValue)) }
    }
}

/// A drop-down list of strings.
final class DropDown: Widget {
    let items: [String]
    init(_ items: [String], selected: Int = 0, onSelect: (@MainActor (Int) -> Void)? = nil) {
        self.items = items
        var cStrings = items.map { strdup($0) } + [nil]
        let dd = cStrings.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { gtk_drop_down_new_from_strings($0) }
        }!
        cStrings.forEach { free($0) }
        super.init(raw: RP(dd))
        if !items.isEmpty { gtk_drop_down_set_selected(OpaquePointer(raw), guint(max(0, min(selected, items.count - 1)))) }
        if let onSelect {
            Signal.onPtr(raw, "notify::selected") { [weak self] _ in
                guard let self else { return }
                onSelect(self.selected)
            }
        }
    }
    var selected: Int {
        get {
            let s = gtk_drop_down_get_selected(OpaquePointer(raw))
            return s == GTK_INVALID_LIST_POSITION ? -1 : Int(s)
        }
        set { gtk_drop_down_set_selected(OpaquePointer(raw), guint(newValue)) }
    }
    var selectedItem: String? { items.indices.contains(selected) ? items[selected] : nil }
}

final class Image: Widget {
    init(_ icon: String, size: Int32 = 16) {
        super.init(raw: RawPtr(gtk_image_new_from_icon_name(icon)))
        gtk_image_set_pixel_size(op, size)
    }
    func setIcon(_ icon: String) { gtk_image_set_from_icon_name(op, icon) }
}

final class Separator: Widget {
    init(_ orientation: GtkOrientation = GTK_ORIENTATION_HORIZONTAL) {
        super.init(raw: RawPtr(gtk_separator_new(orientation)))
    }
}

final class Revealer: Widget {
    private var child: Widget?
    init(_ child: Widget? = nil, transition: GtkRevealerTransitionType = GTK_REVEALER_TRANSITION_TYPE_SLIDE_UP) {
        super.init(raw: RawPtr(gtk_revealer_new()))
        gtk_revealer_set_transition_type(op, transition)
        if let child { setChild(child) }
    }
    func setChild(_ c: Widget?) { gtk_revealer_set_child(op, c?.w); child = c }
    var revealed: Bool {
        get { gtk_revealer_get_reveal_child(op) != 0 }
        set { gtk_revealer_set_reveal_child(op, gbool(newValue)) }
    }
}

/// A button that shows a popover; the popover's content is built on demand.
final class MenuButton: Widget {
    private var builder: (@MainActor (Popover) -> Void)?
    let popover = Popover()

    init(_ label: String? = nil, icon: String? = nil, _ classes: String...) {
        super.init(raw: RawPtr(gtk_menu_button_new()))
        if let label, let icon {
            let content = adw_button_content_new()!
            adw_button_content_set_icon_name(OpaquePointer(content), icon)
            adw_button_content_set_label(OpaquePointer(content), label)
            gtk_menu_button_set_child(OpaquePointer(raw), content)
        } else if let icon {
            gtk_menu_button_set_icon_name(OpaquePointer(raw), icon)
        } else if let label {
            gtk_menu_button_set_label(OpaquePointer(raw), label)
        }
        for c in classes { gtk_widget_add_css_class(w, c) }
        gtk_menu_button_set_popover(OpaquePointer(raw), popover.w)
        Signal.on(popover.raw, "show") { [weak self] in
            guard let self, let builder = self.builder else { return }
            builder(self.popover)
        }
    }

    /// `build` fills the popover each time it opens (so menus show current state).
    func content(_ build: @escaping @MainActor (Popover) -> Void) { builder = build }
    func setLabel(_ s: String) { gtk_menu_button_set_label(OpaquePointer(raw), s) }
}

final class Popover: Widget {
    private var child: Widget?
    init() {
        super.init(raw: RawPtr(gtk_popover_new()))
    }
    func setChild(_ c: Widget) { gtk_popover_set_child(p(GtkPopover.self), c.w); child = c }
    func popup() { gtk_popover_popup(p(GtkPopover.self)) }
    func popdown() { gtk_popover_popdown(p(GtkPopover.self)) }
    func point(at x: Double, _ y: Double) {
        var rect = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
        gtk_popover_set_pointing_to(p(GtkPopover.self), &rect)
    }
    func noArrow() { gtk_popover_set_has_arrow(p(GtkPopover.self), 0) }
}

/// A drawing area whose content is painted by a closure with Cairo.
final class Canvas: Widget {
    var draw: (@MainActor (OpaquePointer, Double, Double) -> Void)?

    init() {
        super.init(raw: RawPtr(gtk_drawing_area_new()))
        let me = Unmanaged.passUnretained(self).toOpaque()
        gtk_drawing_area_set_draw_func(p(GtkDrawingArea.self), { _, cr, width, height, data in
            guard let data, let cr else { return }
            let canvas = Unmanaged<Canvas>.fromOpaque(data).takeUnretainedValue()
            MainActor.assumeIsolated { canvas.draw?(cr, Double(width), Double(height)) }
        }, me, nil)
        gtk_widget_set_focusable(w, 1)
    }

    func onMotion(_ fn: @escaping @MainActor (Double, Double) -> Void, leave: Action? = nil) {
        let c = gtk_event_controller_motion_new()!
        Signal.onXY(RP(c), "motion", fn)
        if let leave { Signal.on(RP(c), "leave", leave) }
        addController(OP(c))
    }

    func onScroll(_ fn: @escaping @MainActor (Double, Double) -> Bool) {
        let c = gtk_event_controller_scroll_new(GtkEventControllerScrollFlags(rawValue: GTK_EVENT_CONTROLLER_SCROLL_VERTICAL.rawValue | GTK_EVENT_CONTROLLER_SCROLL_KINETIC.rawValue))!
        Signal.onScroll(RP(c), fn)
        addController(OP(c))
    }

    deinit {
        // The draw func holds an unretained pointer to us; clear it first.
        gtk_drawing_area_set_draw_func(raw.assumingMemoryBound(to: GtkDrawingArea.self), nil, nil, nil)
    }
}

final class Scrollbar: Widget {
    let adjustment: UnsafeMutablePointer<GtkAdjustment>
    init(_ orientation: GtkOrientation = GTK_ORIENTATION_VERTICAL) {
        adjustment = gtk_adjustment_new(0, 0, 1, 1, 10, 1)
        super.init(raw: RawPtr(gtk_scrollbar_new(orientation, adjustment)))
    }
    var value: Double {
        get { gtk_adjustment_get_value(adjustment) }
        set { gtk_adjustment_set_value(adjustment, newValue) }
    }
    func configure(upper: Double, page: Double, step: Double) {
        let v = min(value, max(0, upper - page))
        gtk_adjustment_configure(adjustment, v, 0, upper, step, page * 0.9, page)
    }
    func onChanged(_ fn: @escaping Action) { Signal.on(RawPtr(adjustment), "value-changed", fn) }
}

/// Wraps any widget pointer we didn't make ourselves (libadwaita containers etc.).
final class AnyWidget: Widget {}
