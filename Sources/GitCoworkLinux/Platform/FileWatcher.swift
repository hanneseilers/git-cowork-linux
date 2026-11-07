import Foundation
import Glibc
import GitCoworkCore

/// Watches folders with inotify (no polling) and reports changed paths in
/// batches on the main queue. Linux counterpart of the FSEvents watcher.
///
/// inotify isn't recursive, so every folder gets its own watch. Folders git
/// ignores (node_modules, build output) and the object store are skipped:
/// nothing the app shows depends on them, and they would use up the
/// per-user watch limit. New folders are picked up as they appear.
final class FileWatcher: @unchecked Sendable {
    /// Upper bound so a huge tree can't take every watch the system allows.
    static let maxWatches = 40_000

    private let handler: ([String]) -> Void
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "git-cowork.filewatcher")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var paths: [Int32: String] = [:]
    private var ignored: [String] = []
    private var pending = Set<String>()
    private var flushScheduled = false
    private var stopped = false

    init(paths roots: [String], latency: TimeInterval = 0.3, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        self.latency = latency
        guard !roots.isEmpty else { return }
        fd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard fd >= 0 else { return }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readEvents() }
        source = src
        src.resume()
        queue.async { [weak self] in
            guard let self else { return }
            self.ignored = roots.flatMap(Self.ignoredFolders)
            for root in roots { self.addTree(root) }
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            source?.cancel()
            source = nil
            if fd >= 0 { close(fd); fd = -1 }
            paths.removeAll()
        }
    }

    deinit {
        source?.cancel()
        if fd >= 0 { close(fd) }
    }

    // MARK: Watches

    private static let mask: UInt32 = UInt32(IN_CREATE | IN_DELETE | IN_MODIFY | IN_CLOSE_WRITE
        | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR)

    /// Folders under a worktree that git ignores (one `git ls-files` call).
    private static func ignoredFolders(in root: String) -> [String] {
        guard let r = try? Subprocess.run("/usr/bin/env", ["git", "ls-files", "--others", "--ignored", "--exclude-standard",
                                                           "--directory", "-z"],
                                          currentDirectory: root, timeout: 10), r.status == 0 else { return [] }
        return String(decoding: r.stdout, as: UTF8.self).split(separator: "\0")
            .filter { $0.hasSuffix("/") }
            .map { root + "/" + $0.dropLast() }
    }

    private func skip(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        // The object store and reflogs change on every git command and say
        // nothing new; refs, HEAD and the index are what matter.
        if path.hasSuffix("/.git/objects") || path.hasSuffix("/.git/logs") || path.hasSuffix("/.git/lfs") { return true }
        if (path.contains("/.git/") || path.hasSuffix(".git")) && (name == "objects" || name == "logs" || name == "lfs") { return true }
        if path.contains("/.git/modules/") && name == "objects" { return true }
        return ignored.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func addTree(_ root: String) {
        var stack = [root]
        while let dir = stack.popLast() {
            guard !stopped, paths.count < Self.maxWatches else { return }
            guard !skip(dir) else { continue }
            let wd = inotify_add_watch(fd, dir, Self.mask)
            guard wd >= 0 else { continue }
            paths[wd] = dir
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in entries {
                let child = dir + "/" + name
                var st = stat()
                // lstat: don't follow symlinks out of the tree (or into loops).
                if lstat(child, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR { stack.append(child) }
            }
        }
    }

    // MARK: Events

    private func readEvents() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            var offset = 0
            while offset + 16 <= n {
                let wd = buffer.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Int32.self) }
                let mask = buffer.withUnsafeBytes { $0.load(fromByteOffset: offset + 4, as: UInt32.self) }
                let len = Int(buffer.withUnsafeBytes { $0.load(fromByteOffset: offset + 12, as: UInt32.self) })
                var name = ""
                if len > 0 {
                    let bytes = buffer[(offset + 16)..<min(offset + 16 + len, n)]
                    name = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                }
                offset += 16 + len
                handle(wd: wd, mask: mask, name: name)
            }
        }
    }

    private func handle(wd: Int32, mask: UInt32, name: String) {
        if mask & UInt32(IN_Q_OVERFLOW) != 0 {
            // Missed events: report every watched root so the app does a full refresh.
            pending.formUnion(paths.values)
            scheduleFlush()
            return
        }
        guard let dir = paths[wd] else { return }
        if mask & UInt32(IN_IGNORED) != 0 { paths[wd] = nil; return }
        let path = name.isEmpty ? dir : dir + "/" + name
        if mask & UInt32(IN_ISDIR) != 0, mask & UInt32(IN_CREATE | IN_MOVED_TO) != 0 {
            addTree(path)
        }
        pending.insert(path)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + latency) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard !self.stopped, !self.pending.isEmpty else { return }
            let batch = Array(self.pending)
            self.pending.removeAll()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.handler(batch)
            }
        }
    }
}
