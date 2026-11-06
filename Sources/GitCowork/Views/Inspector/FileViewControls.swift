import SwiftUI

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
