#if os(Linux)
import Foundation
import Glibc

/// A folder only this user can reach, for the credential-cache socket, the
/// app's ssh config and temporary index files (Linux only).
///
/// On macOS NSTemporaryDirectory() is already per user. On Linux it is the
/// shared /tmp, where another local user could create "git-cowork" first and
/// then read tokens or swap in an ssh config (ProxyCommand runs commands).
/// So: $XDG_RUNTIME_DIR (per user, 0700, cleared at logout), else
/// ~/.cache; the folder is created 0700 and used only if it's a real folder
/// (no symlink) owned by us with no group or other access.
public enum PrivateDirectory {
    /// `<base>/git-cowork`, or nil if no safe folder could be made.
    public static func app(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var bases: [String] = []
        if let runtime = environment["XDG_RUNTIME_DIR"], runtime.hasPrefix("/") { bases.append(runtime) }
        if let cache = environment["XDG_CACHE_HOME"], cache.hasPrefix("/") { bases.append(cache) }
        bases.append(NSHomeDirectory() + "/.cache")
        for base in bases where isPrivateOrSafeParent(base) {
            let dir = base + "/git-cowork"
            if ensurePrivate(dir) { return URL(fileURLWithPath: dir, isDirectory: true) }
        }
        return nil
    }

    /// Creates `path` with mode 0700 if missing, then checks it.
    public static func ensurePrivate(_ path: String) -> Bool {
        if mkdir(path, 0o700) != 0 && errno != EEXIST { return false }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { return false }
        if st.st_mode & 0o077 != 0 {
            // Ours but too open (e.g. made by an older version): tighten it.
            guard chmod(path, 0o700) == 0 else { return false }
        }
        return true
    }

    /// The parent must exist and belong to us or root (e.g. /run/user/<uid>, ~/.cache).
    private static func isPrivateOrSafeParent(_ path: String) -> Bool {
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        // Writable by others only if sticky (like /tmp) is not good enough: we need our own folder.
        return st.st_uid == getuid() || (st.st_uid == 0 && st.st_mode & 0o022 == 0)
    }
}
#endif
