// Linux only. A tiny stand-in for the few AppKit calls made by the macOS
// app's model files (Sources/GitCowork/Git, …), which the Linux app compiles
// unchanged so upstream changes merge cleanly. Nothing here draws UI: the
// GTK app (Sources/GitCoworkLinux) plugs its own handlers in at startup.
//
// It is named AppKit so that `import AppKit` in those shared files resolves
// on Linux. It only exists in Linux builds (see the end of Package.swift).
import Foundation

public final class NSApplication: @unchecked Sendable {
    /// Posted by the GTK app when one of its windows gets focus.
    public static let didBecomeActiveNotification = Notification.Name("NSApplicationDidBecomeActiveNotification")
    public static let didResignActiveNotification = Notification.Name("NSApplicationDidResignActiveNotification")

    private let lock = NSLock()
    private var _isActive = true
    /// Set by the GTK app when it quits for real.
    public var terminateHandler: (() -> Void)?

    public init() {}

    /// Whether a window of the app has focus.
    public var isActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isActive }
        set {
            lock.lock()
            let changed = _isActive != newValue
            _isActive = newValue
            lock.unlock()
            guard changed else { return }
            NotificationCenter.default.post(name: newValue ? Self.didBecomeActiveNotification : Self.didResignActiveNotification,
                                            object: self)
        }
    }

    public func terminate(_ sender: Any?) {
        if let terminateHandler { terminateHandler() } else { exit(0) }
    }
}

nonisolated(unsafe) public let NSApp = NSApplication()

/// Opening URLs and folders with the desktop's default apps (xdg-open).
public final class NSWorkspace: @unchecked Sendable {
    public static let shared = NSWorkspace()
    /// Replaced by the GTK app (it uses GtkUriLauncher / GtkFileLauncher).
    public var openHandler: ((URL) -> Bool)?
    public var revealHandler: (([URL]) -> Void)?

    @discardableResult
    public func open(_ url: URL) -> Bool {
        if let openHandler { return openHandler(url) }
        return Self.spawnDetached("/usr/bin/xdg-open", [url.isFileURL ? url.path : url.absoluteString])
    }

    /// Shows the items in the file manager (selected, where it supports that).
    public func activateFileViewerSelecting(_ urls: [URL]) {
        if let revealHandler { revealHandler(urls); return }
        for url in urls { _ = open(url.deletingLastPathComponent()) }
    }

    /// Starts a program without waiting for it and without handing it our
    /// file descriptors. Returns false if it couldn't start.
    @discardableResult
    public static func spawnDetached(_ path: String, _ args: [String], currentDirectory: String? = nil) -> Bool {
        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclosefrom_np(&actions, 3)
        if let currentDirectory { posix_spawn_file_actions_addchdir_np(&actions, currentDirectory) }
        var attr = posix_spawnattr_t()
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t(); sigfillset(&defaults)
        var empty = sigset_t(); sigemptyset(&empty)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &empty)
        // Own session: closing the app doesn't take the editor or terminal with it.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | 0x80))   // 0x80: POSIX_SPAWN_SETSID (glibc)
        let argv = ([path] + args).map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &actions, &attr, argv, envp) == 0 else { return false }
        let child = pid
        // Reap it in the background so it doesn't linger as a zombie.
        DispatchQueue.global(qos: .background).async {
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        }
        return true
    }
}

/// Clipboard. The GTK app sets `writer` to put text on the display's clipboard.
public final class NSPasteboard: @unchecked Sendable {
    public struct PasteboardType: Hashable, Sendable {
        public let rawValue: String
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let string = PasteboardType("public.utf8-plain-text")
    }

    public static let general = NSPasteboard()
    public var writer: ((String) -> Void)?
    public private(set) var lastString: String?

    public func clearContents() { lastString = nil }

    @discardableResult
    public func setString(_ string: String, forType type: PasteboardType) -> Bool {
        lastString = string
        writer?(string)
        return true
    }

    public func string(forType type: PasteboardType) -> String? { lastString }
}
