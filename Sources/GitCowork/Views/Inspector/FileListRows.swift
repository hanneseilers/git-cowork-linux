import GitCoworkCore
import SwiftUI

/// Button that appears on a row while the mouse is over it ("Stage", "Unstage").
struct RowAction {
    let title: String
    let tint: Color
    let run: () -> Void
}

/// A changed file: status icon, grey folder + file name (path mode) or just the
/// name (tree mode), optional hover button.
struct ChangedFileRow: View {
    let change: FileChange
    var depth = 0
    var showDirectory = true
    var action: RowAction?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ChangeIcon(status: change.status)
            FileName(directory: showDirectory ? change.directory : "", name: change.fileName)
            if let old = change.oldPath {
                Text("← " + (showDirectory ? old : (old as NSString).lastPathComponent))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            if let action, hovering {
                TintedButton(title: action.title, tint: action.tint, action: action.run)
            }
        }
        .font(Theme.Font.body)
        .padding(.leading, CGFloat(depth) * InspectorStyle.indent)
        .frame(minHeight: InspectorStyle.rowHeight)
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
            Image(systemName: "chevron.right")
                .font(Theme.Glyph.chevron)
                .rotationEffect(.degrees(folder.collapsed ? 0 : 90))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(folder.name)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if let action, hovering {
                TintedButton(title: action.title, tint: action.tint, action: action.run)
            } else {
                CountBadge(count: folder.files.count)
            }
        }
        .font(Theme.Font.body)
        .padding(.leading, CGFloat(folder.depth) * InspectorStyle.indent + 3)
        .frame(minHeight: InspectorStyle.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
    }
}
