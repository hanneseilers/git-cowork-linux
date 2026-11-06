import AppKit
import GitCoworkCore
import SwiftUI

// Building blocks shared by the task panel, review panel, review list, inbox and sheets.

/// Top bar of a cowork panel: `panelHeaderHeight` tall, content inset by
/// `panelPadding`, one hairline divider underneath. Lines up with the other
/// panels' top bars.
struct CoworkPanelBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) { content }
                .padding(.horizontal, Theme.Metrics.panelPadding)
                .frame(height: Theme.Metrics.panelHeaderHeight)
            Divider()
        }
    }
}

/// Small caption above a group: "Description", "Comments 3".
struct CoworkSectionTitle<Trailing: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
            if let count { CountBadge(count: count) }
            Spacer(minLength: 0)
            trailing
        }
        .frame(minHeight: Theme.Metrics.chipHeight)
    }
}

extension CoworkSectionTitle where Trailing == EmptyView {
    init(_ title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// "Status   [In Progress]" row of the property grid. The label column has a
/// fixed width so values line up; rows are at least `rowHeight` tall.
struct PropertyRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    static var labelWidth: CGFloat { 72 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(label)
                .font(Theme.Font.small)
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: Theme.Metrics.rowHeight)
    }
}

/// Wrapping row of chips.
struct ChipFlow: Layout {
    var spacing: CGFloat = Theme.Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            line = max(line, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

/// Rounded box behind text editors and composers.
struct EditorBox: ViewModifier {
    var focused = false

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.8) : Color(nsColor: .separatorColor),
                                  lineWidth: focused ? 2 : Theme.Metrics.hairline))
    }
}

extension View {
    func editorBox(focused: Bool = false) -> some View { modifier(EditorBox(focused: focused)) }
}

/// Multi-line text editor with a placeholder, inside an `EditorBox`.
struct PlaceholderEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 64
    var maxHeight: CGFloat = .infinity
    var focused = false

    var body: some View {
        TextEditor(text: $text)
            .font(Theme.Font.body)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.s + 2)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: maxHeight == .infinity)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(Theme.Font.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Theme.Space.m + 1)
                        .padding(.vertical, Theme.Space.s + 2)
                        .allowsHitTesting(false)
                }
            }
            .editorBox(focused: focused)
    }
}

/// SF Symbol tinted for use in NSMenu items (SwiftUI menus drop foreground colors).
func menuSymbol(_ name: String, _ color: Color) -> Image {
    let config = NSImage.SymbolConfiguration(paletteColors: [NSColor(color)])
    if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        return Image(nsImage: img)
    }
    return Image(systemName: name)
}

/// Person icon in their avatar color, for menu items.
func menuPersonIcon(_ person: TeamMember) -> Image {
    menuSymbol("person.crop.circle.fill", Color(nsColor: Theme.personColor(person.email)))
}

extension TeamMember {
    /// What to type after "@": the team handle, or the part of the email before "@".
    var mentionHandle: String {
        handle.isEmpty ? String(email.split(separator: "@").first ?? "") : handle
    }

    var displayName: String { name.isEmpty ? email : name }
}

/// Short display name for an email: team name, else commit author name, else local part.
@MainActor
func displayName(_ email: String?, in store: CoworkStore) -> String {
    guard let email, !email.isEmpty else { return "Unassigned" }
    if email.lowercased() == store.me.id { return store.me.displayName + " (me)" }
    return store.person(email)?.displayName ?? email
}

/// Navigates to the board or review list and selects the thing behind a
/// cowork path such as "tasks/CW-a3f9" or "reviews/R-7k2p".
@MainActor
func openCoworkTarget(_ target: String, model: RepoModel) {
    if target.hasPrefix("tasks/") {
        model.openDiff = nil
        model.centerMode = .board
        model.coworkSelection = .task(String(target.dropFirst("tasks/".count)))
    } else if target.hasPrefix("reviews/") {
        model.openDiff = nil
        let id = String(target.dropFirst("reviews/".count))
        if let r = model.cowork.review(id) { ReviewsView.showFilter(for: r, store: model.cowork) }
        model.centerMode = .reviews
        model.coworkSelection = .review(id)
    }
}

