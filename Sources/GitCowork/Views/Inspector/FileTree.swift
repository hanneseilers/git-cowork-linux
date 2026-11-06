import GitCoworkCore

/// One visible row in a changed-files list: a folder (tree mode) or a file.
enum FileListItem: Identifiable {
    case folder(Folder)
    case file(FileChange, depth: Int)

    struct Folder {
        let id: String
        let name: String        // may be "a/b/c" when single-child folders are merged
        let path: String        // full path from the repo root
        let depth: Int
        let files: [FileChange] // everything below this folder
        let collapsed: Bool
    }

    var id: String {
        switch self {
        case .folder(let f): f.id
        case .file(let c, _): c.id
        }
    }
}

/// Turns a flat list of changes into rows for path or tree mode.
enum FileTree {
    /// `scope` keeps folder ids unique when one list shows several sections.
    static func items(_ files: [FileChange], mode: FileViewMode, sort: FileSortMode,
                      collapsed: Set<String>, scope: String = "") -> [FileListItem] {
        switch mode {
        case .path:
            return sorted(files, by: sort).map { .file($0, depth: 0) }
        case .tree:
            let root = Node()
            for f in files {
                var node = root
                node.all.append(f)
                let dir = f.directory
                if !dir.isEmpty {
                    for part in dir.split(separator: "/") {
                        let key = String(part)
                        let next = node.children[key] ?? Node()
                        node.children[key] = next
                        node = next
                        node.all.append(f)
                    }
                }
                node.files.append(f)
            }
            var out: [FileListItem] = []
            emit(root, path: "", depth: 0, sort: sort, collapsed: collapsed, scope: scope, into: &out)
            return out
        }
    }

    static func toggle(_ id: String, in set: inout Set<String>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    static func sorted(_ files: [FileChange], by sort: FileSortMode) -> [FileChange] {
        switch sort {
        case .path:
            return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        case .name:
            return files.sorted {
                let c = $0.fileName.localizedStandardCompare($1.fileName)
                return c == .orderedSame ? $0.path < $1.path : c == .orderedAscending
            }
        case .status:
            return files.sorted {
                let a = statusRank($0.status), b = statusRank($1.status)
                return a == b ? $0.path.localizedStandardCompare($1.path) == .orderedAscending : a < b
            }
        }
    }

    private final class Node {
        var children: [String: Node] = [:]
        var files: [FileChange] = []
        var all: [FileChange] = []
    }

    private static func emit(_ node: Node, path: String, depth: Int, sort: FileSortMode,
                             collapsed: Set<String>, scope: String, into out: inout [FileListItem]) {
        for name in node.children.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            var child = node.children[name]!
            var label = name
            var full = path.isEmpty ? name : path + "/" + name
            // Merge chains like "Sources/GitCowork/Views" into one row.
            while child.files.isEmpty, child.children.count == 1, let (n, next) = child.children.first {
                label += "/" + n
                full += "/" + n
                child = next
            }
            let id = "dir:\(scope):\(full)"
            let isCollapsed = collapsed.contains(id)
            out.append(.folder(.init(id: id, name: label, path: full, depth: depth, files: child.all, collapsed: isCollapsed)))
            if !isCollapsed {
                emit(child, path: full, depth: depth + 1, sort: sort, collapsed: collapsed, scope: scope, into: &out)
            }
        }
        for f in sorted(node.files, by: sort == .path ? .name : sort) {
            out.append(.file(f, depth: depth))
        }
    }

    private static func statusRank(_ s: FileStatus) -> Int {
        switch s {
        case .conflicted: 0
        case .modified, .typeChanged, .unknown: 1
        case .added, .copied, .untracked: 2
        case .deleted: 3
        case .renamed: 4
        }
    }
}
