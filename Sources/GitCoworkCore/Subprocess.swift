#if os(Linux)
import Foundation
import Glibc

/// Runs a child process with `posix_spawn` (Linux only).
///
/// Foundation's `Process` on Linux leaks an internal socket into the child,
/// and from there into anything the child leaves running. git does exactly
/// that with `credential-cache--daemon` (the usual credential helper on
/// Linux) and with ssh's ControlMaster: the caller then waits for output or
/// exit until that daemon quits, up to 15 minutes. Here every descriptor
/// above stderr is closed in the child, so a daemon can't hold us up.
public enum Subprocess {
    public struct Result: Sendable {
        public let stdout: Data
        public let stderr: Data
        public let status: Int32
    }

    public struct SpawnError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Runs `executable` (an absolute path) with `arguments` and waits for it.
    /// `environment` replaces the whole environment. `input`, if any, is
    /// written to stdin; otherwise stdin is /dev/null.
    public static func run(_ executable: String, _ arguments: [String],
                           currentDirectory: String? = nil,
                           environment: [String: String]? = nil,
                           input: Data? = nil) throws -> Result {
        ignoreSIGPIPE

        var inFDs: [Int32] = [-1, -1], outFDs: [Int32] = [-1, -1], errFDs: [Int32] = [-1, -1]
        defer { for fd in inFDs + outFDs + errFDs where fd >= 0 { close(fd) } }
        func makePipe(_ fds: inout [Int32]) throws {
            guard pipe(&fds) == 0 else { throw SpawnError(message: "pipe: \(String(cString: strerror(errno)))") }
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        }
        if input != nil { try makePipe(&inFDs) }
        try makePipe(&outFDs)
        try makePipe(&errFDs)

        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if input != nil {
            posix_spawn_file_actions_adddup2(&actions, inFDs[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outFDs[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errFDs[1], 2)
        posix_spawn_file_actions_addclosefrom_np(&actions, 3)
        if let currentDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, currentDirectory)
        }

        // The child gets default signal handling and an empty mask, whatever
        // the parent (GTK, Dispatch) set up.
        var attr = posix_spawnattr_t()
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t()
        sigfillset(&defaults)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &empty)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let env = environment ?? ProcessInfo.processInfo.environment
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        guard rc == 0 else {
            throw SpawnError(message: "\(executable): \(String(cString: strerror(rc)))")
        }
        // Close the child's ends here so EOF arrives when the child is done.
        if inFDs[0] >= 0 { close(inFDs[0]); inFDs[0] = -1 }
        close(outFDs[1]); outFDs[1] = -1
        close(errFDs[1]); errFDs[1] = -1

        var stdout = Data(), stderr = Data()
        pump(input: input, inFD: &inFDs[1], outFD: &outFDs[0], errFD: &errFDs[0], stdout: &stdout, stderr: &stderr)

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return Result(stdout: stdout, stderr: stderr, status: exitCode(status))
    }

    /// Writes stdin and reads stdout/stderr at the same time, so a child that
    /// fills one pipe while we write the other can't deadlock.
    private static func pump(input: Data?, inFD: inout Int32, outFD: inout Int32, errFD: inout Int32,
                             stdout: inout Data, stderr: inout Data) {
        let bytes = [UInt8](input ?? Data())
        var written = 0
        if inFD >= 0 {
            _ = fcntl(inFD, F_SETFL, fcntl(inFD, F_GETFL) | O_NONBLOCK)
            if bytes.isEmpty { close(inFD); inFD = -1 }
        }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while outFD >= 0 || errFD >= 0 {
            var fds: [pollfd] = []
            if outFD >= 0 { fds.append(pollfd(fd: outFD, events: Int16(POLLIN), revents: 0)) }
            if errFD >= 0 { fds.append(pollfd(fd: errFD, events: Int16(POLLIN), revents: 0)) }
            if inFD >= 0 { fds.append(pollfd(fd: inFD, events: Int16(POLLOUT), revents: 0)) }
            let n = poll(&fds, nfds_t(fds.count), -1)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            for p in fds where p.revents != 0 {
                if p.fd == inFD {
                    let r = bytes.withUnsafeBytes { raw in
                        write(inFD, raw.baseAddress! + written, bytes.count - written)
                    }
                    if r > 0 { written += r }
                    if r < 0 && errno != EAGAIN && errno != EINTR || written >= bytes.count {
                        close(inFD); inFD = -1
                    }
                    continue
                }
                let r = read(p.fd, &buffer, buffer.count)
                if r > 0 {
                    if p.fd == outFD { stdout.append(contentsOf: buffer[0..<r]) } else { stderr.append(contentsOf: buffer[0..<r]) }
                } else if r == 0 || (errno != EINTR && errno != EAGAIN) {
                    if p.fd == outFD { close(outFD); outFD = -1 } else { close(errFD); errFD = -1 }
                }
            }
        }
        if inFD >= 0 { close(inFD); inFD = -1 }
    }

    /// Exit code, or 128 + signal number like a shell.
    private static func exitCode(_ status: Int32) -> Int32 {
        let low = status & 0x7f
        if low == 0 { return (status >> 8) & 0xff }
        return 128 + low
    }

    /// Writing to a child that already quit must fail with EPIPE, not kill us.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN); return () }()

    /// First executable named `name` on `PATH`.
    public static func which(_ name: String, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        if name.contains("/") { return access(name, X_OK) == 0 ? name : nil }
        for dir in (path ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return nil
    }
}
#endif
