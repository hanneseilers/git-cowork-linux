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

/// Small grey number, used in section headers and rows.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text(verbatim: "\(count)")
            .font(Theme.Font.caption.monospacedDigit())
            .foregroundStyle(.secondary)
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

/// One-letter file status in a colored square: M, A, D, R, U, ?
struct StatusGlyph: View {
    let status: FileStatus

    var body: some View {
        Text(String(status == .untracked ? "+" : status.rawValue))
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(color.opacity(Theme.Tint.chip), in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
            .help(label)
    }

    var color: Color {
        switch status {
        case .added, .copied: Theme.Status.added
        case .modified, .typeChanged: Theme.Status.modified
        case .deleted: Theme.Status.deleted
        case .renamed: Theme.Status.renamed
        case .conflicted: Theme.Status.conflicted
        case .untracked: Theme.Status.untracked
        case .unknown: .secondary
        }
    }

    var label: String {
        switch status {
        case .added: "Added"
        case .copied: "Copied"
        case .modified: "Modified"
        case .typeChanged: "Type changed"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .conflicted: "Conflicted"
        case .untracked: "New file"
        case .unknown: "Changed"
        }
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
            .background(Color(nsColor: Theme.lane(abs(email.lowercased().hashValueStable))), in: Circle())
    }

    var initials: String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
        let letters = parts.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}

extension String {
    /// Same value on every launch (Swift's hashValue is randomized).
    var hashValueStable: Int {
        var h: UInt32 = 2_166_136_261
        for b in utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return Int(h % 10_000)
    }
}

/// Header for a block inside the inspector: "Staged  3   [Unstage all]"
struct PanelHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
            if let count { CountBadge(count: count) }
            Spacer()
            trailing
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
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
            Text(title).font(Theme.Font.body.weight(.medium))
            if let message {
                Text(message)
                    .font(Theme.Font.small)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Row for a changed file: status glyph, file name, dimmed folder.
struct FileRow: View {
    let change: FileChange

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            StatusGlyph(status: change.status)
            Text(change.fileName)
                .lineLimit(1)
                .layoutPriority(1)
            Text(change.oldPath.map { "← \($0)" } ?? change.directory)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .font(Theme.Font.body)
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
            Text(title).font(Theme.Font.title)
            content
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
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
        case .secondary: color.opacity(hovering && enabled ? 0.16 : (tint == nil ? 0.05 : 0.10))
        }
    }

    private var border: Color {
        switch kind {
        case .primary: .clear
        case .secondary: tint.map { $0.opacity(0.55) } ?? Color(nsColor: .separatorColor)
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
