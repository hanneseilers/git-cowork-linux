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
    static let indent: CGFloat = 14
    static let rowHeight = Theme.Metrics.rowHeight
    static let summaryLimit = 72
    static let descriptionHeight: CGFloat = 72
    static let cardBackground = Theme.cardFill
    static let cardBorder = Theme.cardBorder
    static let bannerTint = Color.accentColor
    static let commitTint = Color(nsColor: .systemGreen)
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
        case .path: L("Path")
        case .name: L("File Name")
        case .status: L("Status")
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
