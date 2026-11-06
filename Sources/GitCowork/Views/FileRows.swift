import GitCoworkCore
import SwiftUI

// Changed files: status icon, rows, folder rows and the per-status summary.
// Used by the commit and changes panels and the review panel.

/// File status as a colored SF Symbol (see `FileStatus.symbol`).
struct FileStatusIcon: View {
    let status: FileStatus

    var body: some View {
        Image(systemName: status.symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(status.color)
            .frame(width: Theme.Metrics.iconWidth, height: Theme.Metrics.iconWidth)
            .help(status.label)
    }
}

/// "✎ 2 modified  + 1 added  − 1 deleted  → 1 renamed"
struct ChangeSummary: View {
    let files: [FileChange]

    var body: some View {
        let groups = ChangeCounts(files).groups
        // Drop the words when the panel is too narrow for them.
        ViewThatFits(in: .horizontal) {
            row(groups, labels: true)
            row(groups, labels: false)
        }
        .font(Theme.Font.small.monospacedDigit())
    }

    private func row(_ groups: [(status: FileStatus, label: String, count: Int)], labels: Bool) -> some View {
        HStack(spacing: labels ? Theme.Space.l : Theme.Space.m) {
            ForEach(groups, id: \.label) { g in
                HStack(spacing: Theme.Space.xs) {
                    FileStatusIcon(status: g.status)
                    Text(labels ? "\(g.count) \(g.label)" : "\(g.count)")
                        .foregroundStyle(.secondary)
                }
                .help("\(g.count) \(g.label)")
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Button that appears on a row while the mouse is over it ("Stage", "Unstage").
struct RowAction {
    let title: String
    let tint: Color
    let run: () -> Void
}

private func button(_ action: RowAction) -> some View {
    Button(action.title, action: action.run)
        .buttonStyle(ActionButtonStyle.secondary(action.tint))
}

/// A changed file: status icon, grey folder + file name (path mode) or just the
/// name (tree mode), optional hover button.
struct FileRow: View {
    let change: FileChange
    var depth = 0
    var showDirectory = true
    var action: RowAction?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            FileStatusIcon(status: change.status)
            FileName(directory: showDirectory ? change.directory : "", name: change.fileName)
            if let old = change.oldPath {
                Text("← " + (showDirectory ? old : (old as NSString).lastPathComponent))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            if let action, hovering { button(action) }
        }
        .font(Theme.Font.body)
        .padding(.leading, CGFloat(depth) * InspectorStyle.indent)
        .frame(minHeight: Theme.Metrics.rowHeight)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(change.path)
    }
}

/// "dir/sub/name.ext" in one line. When space runs out the folder part is
/// shortened from the front ("…/sub/name.ext"); the file name is only cut when
/// it doesn't fit on its own. Never leaves a stray clipped letter of the folder.
struct FileName: View {
    let directory: String
    let name: String
    /// Room kept for at least "…/" in front of the name.
    private let minDirectory: CGFloat = 24

    var body: some View {
        if directory.isEmpty {
            nameOnly
        } else {
            ViewThatFits(in: .horizontal) {
                full
                // Name fits with room for "…/": the whole path, truncated at the head.
                Text(name)
                    .padding(.leading, minDirectory)
                    .hidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        full.truncationMode(.head)
                    }
                nameOnly
            }
        }
    }

    private var full: some View {
        (Text(directory + "/").foregroundColor(.secondary) + Text(name))
            .lineLimit(1)
    }

    private var nameOnly: some View {
        Text(name)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// A folder in tree mode. Clicking it collapses or expands it.
struct FolderRow: View {
    let folder: FileListItem.Folder
    let toggle: () -> Void
    var action: RowAction?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            DisclosureChevron(expanded: !folder.collapsed).frame(width: 10)
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(folder.name)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if let action, hovering {
                button(action)
            } else {
                CountBadge(count: folder.files.count)
            }
        }
        .font(Theme.Font.body)
        .padding(.leading, CGFloat(folder.depth) * InspectorStyle.indent + 3)
        .frame(minHeight: Theme.Metrics.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
    }
}
