import GitCoworkCore
import SwiftUI

// Small building blocks shared by all screens.

/// Pill showing a branch or tag name.
struct RefBadge: View {
    let ref: Ref
    var color: Color = .accentColor

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: ref.symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(ref.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(Theme.Font.small.weight(ref.isHead ? .semibold : .regular))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(Theme.Tint.chip), in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
        .help(ref.name)
    }
}

extension Ref {
    var symbol: String {
        switch kind {
        case .localBranch: isHead ? "checkmark" : "arrow.triangle.branch"
        case .remoteBranch: "cloud"
        case .tag: "tag"
        }
    }
}

/// A count. Styles:
/// - `.plain`: small grey number (section headers, folders).
/// - `.accent`: white on an accent capsule (reviews waiting for me).
/// - `.warning`: tinted capsule (uncommitted changes of a worktree).
/// - `.toolbar`: tiny filled badge on a toolbar icon (commits to push, unread).
struct CountBadge: View {
    enum Style { case plain, accent, warning, toolbar }
    let count: Int
    var style: Style = .plain
    /// Fixed column width, so counts line up across rows (sidebar headers).
    var column: CGFloat?
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        switch style {
        case .plain:
            number
                .foregroundStyle(.secondary)
                .frame(minWidth: column, minHeight: column == nil ? nil : 16, alignment: .trailing)
        case .accent:
            number
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Space.s)
                .frame(minWidth: column, minHeight: 16)
                .background(Capsule().fill(Color.accentColor))
        case .warning:
            number
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 1)
                .background(Theme.Status.warning.opacity(Theme.Tint.chip), in: Capsule())
                .foregroundStyle(Theme.Status.warning)
        case .toolbar:
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .frame(minWidth: 13, minHeight: 13)
                .background(Capsule().fill(Color.accentColor))
                .opacity(enabled ? 1 : 0.4)
        }
    }

    private var number: some View {
        Text(verbatim: "\(count)").font(Theme.Font.caption.monospacedDigit())
    }
}

/// "↑2 ↓1" next to a branch or worktree. Shows nothing when in sync.
struct AheadBehind: View {
    let ahead: Int
    let behind: Int

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if ahead > 0 { Text(verbatim: "↑\(ahead)") }
            if behind > 0 { Text(verbatim: "↓\(behind)") }
        }
        .font(Theme.Font.small.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

/// Initials in a colored circle. No network lookups.
struct Avatar: View {
    let name: String
    let email: String
    var size: CGFloat = 28

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(nsColor: Theme.personColor(email)), in: Circle())
    }

    var initials: String { name.initials }
}


/// Top bar of a panel: `panelHeaderHeight` tall, content inset by
/// `panelPadding`, one hairline underneath. Every panel uses it, so the
/// bars' bottom borders form one line across the window.
struct PanelBar<Content: View>: View {
    var spacing = Theme.Space.m
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: spacing) { content }
                .padding(.horizontal, Theme.Metrics.panelPadding)
                .frame(height: Theme.Metrics.panelHeaderHeight)
            Divider()
        }
    }
}

/// Caption above a group: "Description", "Comments 3", "Unstaged files 3".
/// With `collapsed` it gets a chevron and clicking the title toggles it.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    var collapsed: Binding<Bool>?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if let collapsed {
                Button {
                    collapsed.wrappedValue.toggle()
                } label: {
                    HStack(spacing: Theme.Space.s) {
                        DisclosureChevron(expanded: !collapsed.wrappedValue).frame(width: 10)
                        label
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
            } else {
                label.layoutPriority(1)
            }
            Spacer(minLength: Theme.Space.s)
            trailing
        }
        .frame(minHeight: Theme.Metrics.chipHeight)
    }

    private var label: some View {
        HStack(spacing: Theme.Space.s) {
            Text(ui: title)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let count { CountBadge(count: count) }
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// Disclosure chevron of collapsible sections, folders and tree rows.
struct DisclosureChevron: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(Theme.Glyph.chevron)
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
    }
}

/// Lays out children left to right, wrapping onto new lines. A child wider
/// than the row is narrowed to the row width (its text truncates).
struct FlowRow: Layout {
    var spacing: CGFloat = Theme.Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = size(of: v, maxWidth: width)
            if x > 0 && x + s.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            maxX = max(maxX, x + s.width)
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for v in subviews {
            let s = size(of: v, maxWidth: bounds.width)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }

    private func size(of v: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let ideal = v.sizeThatFits(.unspecified)
        guard ideal.width > maxWidth, maxWidth.isFinite else { return ideal }
        let s = v.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        return CGSize(width: min(s.width, maxWidth), height: s.height)
    }
}

/// Centered placeholder for empty panels.
struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(ui: title).font(Theme.Font.body.weight(.medium))
            if let message {
                Text(ui: message)
                    .font(Theme.Font.small)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Standard sheet layout: title, content, Cancel + primary button.
struct SheetScaffold<Content: View>: View {
    let title: String
    let confirmTitle: String
    var confirmDisabled = false
    let onConfirm: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(ui: title).font(Theme.Font.title)
            content
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(LocalizedStringKey(confirmTitle)) {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(confirmDisabled)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 440)
    }
}

// MARK: Buttons

/// The one button family used inside panels (the toolbar has its own flat
/// `ChromeButtonStyle`):
/// - `.primary`: filled with the tint, white text. The main action of a block
///   (New Task, Commit, Approve). Use at most one or two per block.
/// - `.secondary`: small bordered button, tinted text on a soft tinted fill.
///   Without a tint it is neutral (label color, separator border).
/// - Inline text actions use `.buttonStyle(.link)`.
struct ActionButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .secondary
    var tint: Color?

    static func primary(_ tint: Color = .accentColor) -> ActionButtonStyle { .init(kind: .primary, tint: tint) }
    static func secondary(_ tint: Color? = nil) -> ActionButtonStyle { .init(kind: .secondary, tint: tint) }

    func makeBody(configuration: Configuration) -> some View {
        ActionButtonBody(label: configuration.label, kind: kind, tint: tint, pressed: configuration.isPressed)
    }
}

/// Draws the `ActionButtonStyle` look. Also used directly as the label of
/// menus (`actionButtonLabel`), which can't take a custom button style.
private struct ActionButtonBody<Label: View>: View {
    let label: Label
    let kind: ActionButtonStyle.Kind
    let tint: Color?
    var pressed = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control)
        label
            .labelStyle(ActionLabelStyle())
            .font(Theme.Font.small.weight(kind == .primary ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, Theme.Space.m + Theme.Space.xs)
            .frame(minHeight: Theme.Metrics.buttonHeight)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(border, lineWidth: Theme.Metrics.hairline))
            .overlay(shape.fill(Color.black.opacity(pressed ? 0.12 : 0)))
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.45)
            .fixedSize()
            .onHover { hovering = $0 }
    }

    private var color: Color { tint ?? .primary }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: tint?.readableTint(scheme) ?? .primary
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: (tint ?? .accentColor).opacity(hovering && enabled ? 0.88 : 1)
        case .secondary: tint == nil
            ? color.opacity(hovering && enabled ? 0.16 : 0.05)
            : color.opacity(hovering && enabled ? Theme.Tint.chip + 0.07 : Theme.Tint.chip)
        }
    }

    private var border: Color {
        switch kind {
        case .primary: .clear
        case .secondary: tint == nil ? Color(nsColor: .separatorColor) : .clear  // tinted: the fill is enough
        }
    }
}

/// Icon and title close together, icon a little smaller than the text.
private struct ActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Space.s) {
            configuration.icon.font(.system(size: 9, weight: .semibold))
            configuration.title
        }
    }
}

extension View {
    /// The `ActionButtonStyle` look for a menu's label. Use with
    /// `.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)`.
    func actionButtonLabel(_ kind: ActionButtonStyle.Kind = .secondary, tint: Color? = nil) -> some View {
        ActionButtonBody(label: self, kind: kind, tint: tint)
    }
}
