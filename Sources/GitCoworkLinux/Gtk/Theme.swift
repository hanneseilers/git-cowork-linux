import CGtk
import Foundation
import GitCoworkCore

/// Colors and Cairo / Pango drawing helpers. Lane, person and label colors
/// match the macOS app (same palette, same stable hashes).
struct RGBA: Equatable {
    var r, g, b, a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    func alpha(_ a: Double) -> RGBA { RGBA(r, g, b, a) }
    func mix(_ o: RGBA, _ f: Double) -> RGBA { RGBA(r + (o.r - r) * f, g + (o.g - g) * f, b + (o.b - b) * f, a + (o.a - a) * f) }
    var hex: String { String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255)) }
    /// White or near-black, whichever reads better on this color.
    var readableText: RGBA {
        0.2126 * r + 0.7152 * g + 0.0722 * b > 0.62 ? RGBA(0.1, 0.1, 0.1) : RGBA(1, 1, 1)
    }
}

@MainActor
enum Theme {
    static let lanes: [RGBA] = [
        RGBA(0.27, 0.60, 0.96), RGBA(0.90, 0.42, 0.62), RGBA(0.36, 0.72, 0.42), RGBA(0.95, 0.62, 0.22),
        RGBA(0.63, 0.47, 0.86), RGBA(0.20, 0.72, 0.76), RGBA(0.84, 0.71, 0.20), RGBA(0.92, 0.38, 0.36),
        RGBA(0.52, 0.58, 0.94), RGBA(0.68, 0.53, 0.40),
    ]

    static func lane(_ i: Int) -> RGBA { lanes[((i % lanes.count) + lanes.count) % lanes.count] }
    static func personColor(_ email: String) -> RGBA { lane(email.lowercased().stableHash) }
    static func labelColor(_ label: String) -> RGBA { lane(label.lowercased().stableHash) }

    static let green = RGBA(0.20, 0.65, 0.33)
    static let orange = RGBA(0.90, 0.55, 0.10)
    static let red = RGBA(0.86, 0.24, 0.24)
    static let blue = RGBA(0.20, 0.50, 0.90)
    static let pink = RGBA(0.85, 0.30, 0.55)

    static var dark: Bool { adw_style_manager_get_dark(adw_style_manager_get_default()) != 0 }
    static var text: RGBA { dark ? RGBA(1, 1, 1, 0.92) : RGBA(0, 0, 0, 0.85) }
    static var secondaryText: RGBA { dark ? RGBA(1, 1, 1, 0.55) : RGBA(0, 0, 0, 0.55) }
    static var background: RGBA { dark ? RGBA(0.14, 0.14, 0.15) : RGBA(1, 1, 1) }
    static var hover: RGBA { dark ? RGBA(1, 1, 1, 0.05) : RGBA(0, 0, 0, 0.04) }
    static var accent: RGBA { RGBA(0.21, 0.52, 0.89) }

    static func statusColor(_ s: FileStatus) -> RGBA {
        switch s {
        case .added, .untracked, .copied: green
        case .modified, .typeChanged: orange
        case .deleted: red
        case .renamed: blue
        case .conflicted: pink
        case .unknown: secondaryText
        }
    }

    /// App-wide CSS: chips, cards, selection, diff colors.
    static let css = """
    .gc-sidebar { background: alpha(@window_fg_color, 0.03); }
    .gc-sidebar row { padding: 2px 6px; min-height: 26px; }
    .gc-sidebar .gc-section { font-weight: 700; font-size: 0.8em; opacity: 0.6; margin-top: 8px; }
    .gc-selected { background: alpha(@accent_bg_color, 0.18); border-radius: 6px; }
    .gc-count { font-size: 0.8em; padding: 0 6px; border-radius: 9px; background: alpha(@window_fg_color, 0.08); }
    .gc-chip { font-size: 0.8em; font-weight: 600; padding: 1px 6px; border-radius: 6px; }
    .gc-mono { font-family: monospace; }
    .gc-statusbar { padding: 2px 8px; font-size: 0.9em; border-top: 1px solid alpha(@window_fg_color, 0.1); }
    .gc-toolbar { padding: 4px 6px; border-bottom: 1px solid alpha(@window_fg_color, 0.1); }
    .gc-panel-header { padding: 6px 10px; border-bottom: 1px solid alpha(@window_fg_color, 0.1); }
    .gc-card { padding: 8px 10px; border-radius: 8px; background: @card_bg_color; box-shadow: 0 1px 2px alpha(black, 0.15); }
    .gc-card.gc-selected { box-shadow: 0 0 0 2px @accent_bg_color; }
    .gc-column { background: alpha(@window_fg_color, 0.04); border-radius: 10px; padding: 6px; }
    .gc-menu-item { padding: 4px 10px; min-height: 26px; }
    .gc-menu { min-width: 200px; }
    .gc-log { font-family: monospace; font-size: 0.9em; }
    .gc-ok { color: @success_color; }
    .gc-fail { color: @error_color; }
    .gc-avatar { border-radius: 999px; min-width: 20px; min-height: 20px; font-size: 0.7em; font-weight: 700; color: white; }
    .gc-banner { padding: 6px 10px; background: alpha(@warning_bg_color, 0.35); }
    .gc-comment { padding: 6px 8px; border-radius: 8px; background: alpha(@window_fg_color, 0.05); }
    """

    static func installCSS() {
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), OP(provider), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }
}

/// Cairo drawing with Pango text, for the history graph.
@MainActor
struct Painter {
    let cr: OpaquePointer

    func color(_ c: RGBA) { cairo_set_source_rgba(cr, c.r, c.g, c.b, c.a) }

    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: RGBA) {
        color(c); cairo_rectangle(cr, x, y, w, h); cairo_fill(cr)
    }

    func roundRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, radius r: Double, fill: RGBA?, stroke: RGBA? = nil, lineWidth: Double = 1) {
        let r = min(r, h / 2, w / 2)
        cairo_new_sub_path(cr)
        cairo_arc(cr, x + w - r, y + r, r, -.pi / 2, 0)
        cairo_arc(cr, x + w - r, y + h - r, r, 0, .pi / 2)
        cairo_arc(cr, x + r, y + h - r, r, .pi / 2, .pi)
        cairo_arc(cr, x + r, y + r, r, .pi, 3 * .pi / 2)
        cairo_close_path(cr)
        if let fill { color(fill); stroke == nil ? cairo_fill(cr) : cairo_fill_preserve(cr) }
        if let stroke { color(stroke); cairo_set_line_width(cr, lineWidth); cairo_stroke(cr) }
    }

    func circle(_ x: Double, _ y: Double, _ radius: Double, fill: RGBA?, stroke: RGBA? = nil, lineWidth: Double = 1) {
        cairo_new_sub_path(cr)
        cairo_arc(cr, x, y, radius, 0, 2 * .pi)
        if let fill { color(fill); stroke == nil ? cairo_fill(cr) : cairo_fill_preserve(cr) }
        if let stroke { color(stroke); cairo_set_line_width(cr, lineWidth); cairo_stroke(cr) }
    }

    func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ c: RGBA, width: Double, dash: [Double] = []) {
        color(c)
        cairo_set_line_width(cr, width)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        if !dash.isEmpty { dash.withUnsafeBufferPointer { cairo_set_dash(cr, $0.baseAddress, Int32(dash.count), 0) } }
        cairo_move_to(cr, x1, y1)
        cairo_line_to(cr, x2, y2)
        cairo_stroke(cr)
        if !dash.isEmpty { cairo_set_dash(cr, nil, 0, 0) }
    }

    /// A line that bends with a rounded corner (graph edges between lanes).
    func bend(from x1: Double, _ y1: Double, to x2: Double, _ y2: Double, _ c: RGBA, width: Double, radius: Double, dash: [Double] = []) {
        color(c)
        cairo_set_line_width(cr, width)
        if !dash.isEmpty { dash.withUnsafeBufferPointer { cairo_set_dash(cr, $0.baseAddress, Int32(dash.count), 0) } }
        cairo_move_to(cr, x1, y1)
        let midY = (y1 + y2) / 2
        cairo_curve_to(cr, x1, midY, x2, midY, x2, y2)
        cairo_stroke(cr)
        if !dash.isEmpty { cairo_set_dash(cr, nil, 0, 0) }
    }

    func clip(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        cairo_save(cr); cairo_rectangle(cr, x, y, w, h); cairo_clip(cr)
    }
    func restore() { cairo_restore(cr) }

    /// Draws text with its left edge at x, vertically centered on midY. Returns its width.
    @discardableResult
    func text(_ s: String, x: Double, midY: Double, maxWidth: Double? = nil, font: String = "Sans 10",
              color c: RGBA, bold: Bool = false, align: Double = 0) -> Double {
        guard !s.isEmpty else { return 0 }
        let layout = pango_cairo_create_layout(cr)!
        defer { g_object_unref(RP(layout)) }
        let desc = pango_font_description_from_string(bold ? font + " Bold" : font)
        pango_layout_set_font_description(layout, desc)
        pango_font_description_free(desc)
        pango_layout_set_text(layout, s, -1)
        pango_layout_set_single_paragraph_mode(layout, 1)
        if let maxWidth {
            pango_layout_set_width(layout, Int32(max(0, maxWidth) * Double(PANGO_SCALE)))
            pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END)
        }
        var w: Int32 = 0, h: Int32 = 0
        pango_layout_get_pixel_size(layout, &w, &h)
        color(c)
        cairo_move_to(cr, x - Double(w) * align, midY - Double(h) / 2)
        pango_cairo_show_layout(cr, layout)
        return Double(w)
    }

    static func measure(_ s: String, font: String = "Sans 10", bold: Bool = false, cr: OpaquePointer) -> Double {
        let layout = pango_cairo_create_layout(cr)!
        defer { g_object_unref(RP(layout)) }
        let desc = pango_font_description_from_string(bold ? font + " Bold" : font)
        pango_layout_set_font_description(layout, desc)
        pango_font_description_free(desc)
        pango_layout_set_text(layout, s, -1)
        var w: Int32 = 0, h: Int32 = 0
        pango_layout_get_pixel_size(layout, &w, &h)
        return Double(w)
    }
}

/// Round avatar with initials in the person's color.
@MainActor
func avatar(_ name: String, email: String, size: Int32 = 20) -> Widget {
    let l = Label(name.initials, "gc-avatar")
    l.xalign(0.5)
    l.size(size, size)
    l.valign(GTK_ALIGN_CENTER)
    let c = Theme.personColor(email)
    let provider = gtk_css_provider_new()!
    gtk_css_provider_load_from_string(provider, "label { background: \(c.hex); color: \(c.readableText.hex); }")
    gtk_style_context_add_provider(gtk_widget_get_style_context(l.w), OP(provider), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    g_object_unref(RP(provider))
    return l
}

/// A small colored chip (labels, status).
@MainActor
func chip(_ text: String, color c: RGBA, filled: Bool = false) -> Widget {
    let l = Label(text, "gc-chip")
    let provider = gtk_css_provider_new()!
    let css = filled
        ? "label { background: \(c.hex); color: \(c.readableText.hex); }"
        : "label { background: alpha(\(c.hex), 0.18); color: \(c.mix(RGBA(0, 0, 0), Theme.dark ? -0.3 : 0.25).hex); }"
    gtk_css_provider_load_from_string(provider, css)
    gtk_style_context_add_provider(gtk_widget_get_style_context(l.w), OP(provider), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    g_object_unref(RP(provider))
    return l
}

/// Relative date like the macOS app shows ("5 min ago", "yesterday", "12 Mar").
func relativeDate(_ date: Date, now: Date = Date()) -> String {
    let s = now.timeIntervalSince(date)
    if s < 60 { return L("just now") }
    if s < 3600 { return String(localized: "\(Int(s / 60)) min ago") }
    if s < 86400 { return String(localized: "\(Int(s / 3600)) h ago") }
    if s < 7 * 86400 { return String(localized: "\(Int(s / 86400)) d ago") }
    let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
    return (sameYear ? DateFormats.dayMonth : DateFormats.dayMonthYear).string(from: date)
}

func fullDate(_ date: Date) -> String {
    DateFormats.full.string(from: date)
}

/// Formatters are expensive to make; these are made once (main thread only).
private enum DateFormats {
    nonisolated(unsafe) static let dayMonth = make { $0.setLocalizedDateFormatFromTemplate("d MMM") }
    nonisolated(unsafe) static let dayMonthYear = make { $0.setLocalizedDateFormatFromTemplate("d MMM yyyy") }
    nonisolated(unsafe) static let full = make { $0.dateStyle = .medium; $0.timeStyle = .short }

    private static func make(_ configure: (DateFormatter) -> Void) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: Localization.shared.language)
        configure(f)
        return f
    }
}
