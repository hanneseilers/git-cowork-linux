import GitCoworkCore
import SwiftUI

/// Sizes and fonts used only by the right-hand panel.
enum InspectorStyle {
    static let padding = Theme.Metrics.panelPadding
    static let headerHeight = Theme.Metrics.panelHeaderHeight
    static let sectionGap = Theme.Metrics.sectionGap
    static let linkLabelWidth: CGFloat = 48
    /// Secondary bars inside a panel ("2 modified  Path | Tree").
    static let subheaderHeight: CGFloat = 34
    static let subjectFont = SwiftUI.Font.system(size: 17, weight: .semibold)
    static let headerFont = SwiftUI.Font.system(size: 13, weight: .semibold)
    static let avatarSize: CGFloat = 40
    static let coAuthorAvatarSize: CGFloat = 18
    static let messageMaxHeight: CGFloat = 220
    static let iconWidth: CGFloat = 16
    static let indent: CGFloat = 14
    static let rowHeight = Theme.Metrics.rowHeight
    static let summaryLimit = 72
    static let descriptionHeight: CGFloat = 72
    static let cardBackground = Theme.cardFill
    static let cardBorder = Theme.cardBorder
    static let bannerTint = Color.accentColor
    static let commitTint = Color(nsColor: .systemGreen)
}

/// File status as a colored SF Symbol, GitKraken style: pencil, plus, minus, arrow.
struct ChangeIcon: View {
    let status: FileStatus

    var body: some View {
        Image(systemName: Self.symbol(status))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Self.color(status))
            .frame(width: InspectorStyle.iconWidth, height: InspectorStyle.iconWidth)
            .help(Self.label(status))
    }

    static func symbol(_ s: FileStatus) -> String {
        switch s {
        case .modified, .typeChanged, .unknown: "pencil"
        case .added, .copied, .untracked: "plus"
        case .deleted: "minus"
        case .renamed: "arrow.right"
        case .conflicted: "exclamationmark.triangle"
        }
    }

    static func color(_ s: FileStatus) -> Color {
        switch s {
        case .added, .copied: Theme.Status.added
        case .modified, .typeChanged: Theme.Status.modified
        case .deleted: Theme.Status.deleted
        case .renamed: Theme.Status.renamed
        case .conflicted: Theme.Status.conflicted
        case .untracked: Theme.Status.untracked
        case .unknown: .secondary
        }
    }

    static func label(_ s: FileStatus) -> String {
        switch s {
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

/// "✎ 2 modified  + 1 added  − 1 deleted  → 1 renamed"
struct ChangeSummary: View {
    let files: [FileChange]

    var body: some View {
        let groups = Self.groups(files)
        // Drop the words when the panel is too narrow for them.
        ViewThatFits(in: .horizontal) {
            row(groups, labels: true)
            row(groups, labels: false)
        }
        .font(Theme.Font.small.monospacedDigit())
    }

    private func row(_ groups: [Group], labels: Bool) -> some View {
        HStack(spacing: labels ? Theme.Space.l : Theme.Space.m) {
            ForEach(groups, id: \.label) { g in
                HStack(spacing: Theme.Space.xs) {
                    ChangeIcon(status: g.status)
                    Text(labels ? "\(g.count) \(g.label)" : "\(g.count)")
                        .foregroundStyle(.secondary)
                }
                .help("\(g.count) \(g.label)")
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private struct Group { let status: FileStatus; let label: String; let count: Int }

    private static func groups(_ files: [FileChange]) -> [Group] {
        var modified = 0, added = 0, deleted = 0, renamed = 0, conflicted = 0
        for f in files {
            switch f.status {
            case .added, .copied, .untracked: added += 1
            case .deleted: deleted += 1
            case .renamed: renamed += 1
            case .conflicted: conflicted += 1
            default: modified += 1
            }
        }
        return [
            Group(status: .conflicted, label: "conflicted", count: conflicted),
            Group(status: .modified, label: "modified", count: modified),
            Group(status: .added, label: "added", count: added),
            Group(status: .deleted, label: "deleted", count: deleted),
            Group(status: .renamed, label: "renamed", count: renamed),
        ].filter { $0.count > 0 }
    }
}

/// How changed files are listed. Persisted under "inspector.fileView".
enum FileViewMode: String, CaseIterable {
    case path, tree

    static let storageKey = "inspector.fileView"
}

/// How files are ordered. Persisted under "inspector.fileSort".
enum FileSortMode: String, CaseIterable {
    case path, name, status

    static let storageKey = "inspector.fileSort"

    var title: String {
        switch self {
        case .path: "Path"
        case .name: "File Name"
        case .status: "Status"
        }
    }
}

/// Sort menu + segmented "Path | Tree".
struct FileViewControls: View {
    @AppStorage(FileViewMode.storageKey) private var mode: FileViewMode = .path
    @AppStorage(FileSortMode.storageKey) private var sort: FileSortMode = .path

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(FileSortMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort files")

            Picker("View", selection: $mode) {
                Text("Path").tag(FileViewMode.path)
                Text("Tree").tag(FileViewMode.tree)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .controlSize(.small)
    }
}

/// Small button tinted with a status color: "Stage All Changes".
struct TintedButton: View {
    let title: String
    var symbol: String?
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
        .buttonStyle(ActionButtonStyle.secondary(tint))
    }
}

/// Accent-tinted strip at the top of the commit panel: "4 file changes in working directory".
struct WorkingCopyBanner: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "pencil.line")
                .foregroundStyle(InspectorStyle.bannerTint)
            Text(verbatim: "\(count) file change\(count == 1 ? "" : "s") in working directory")
                .font(Theme.Font.body.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            Button("View Changes", action: action)
                .buttonStyle(ActionButtonStyle.secondary(InspectorStyle.bannerTint))
        }
        .padding(.horizontal, InspectorStyle.padding)
        .padding(.vertical, Theme.Space.m)
        .background(InspectorStyle.bannerTint.opacity(Theme.Tint.banner))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// "Unstaged files (3)" with a collapse chevron and trailing buttons.
struct SectionHeader<Trailing: View>: View {
    let title: String
    let count: Int
    @Binding var collapsed: Bool
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Button {
                collapsed.toggle()
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "chevron.right")
                        .font(Theme.Glyph.chevron)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(title)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    CountBadge(count: count)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            Spacer(minLength: Theme.Space.s)
            trailing
        }
        .padding(.vertical, Theme.Space.s)
    }
}
