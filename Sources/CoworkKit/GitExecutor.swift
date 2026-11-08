import Foundation
#if os(Linux)
import GitCoworkCore
#endif

/// What a git call returned. Output stays raw bytes; callers decode.
public struct GitOutput: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32

    public init(stdout: Data, stderr: Data, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public var ok: Bool { exitCode == 0 }
    public var text: String { String(decoding: stdout, as: UTF8.self) }
    public var errorText: String { String(decoding: stderr, as: UTF8.self) }
    /// stdout without the trailing newline.
    public var line: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Runs git. The app passes its own runner (login-shell PATH, signed-in
/// accounts); the command-line tool uses `ProcessGit`.
public protocol GitExecutor: Sendable {
    func git(_ args: [String], in dir: URL, input: Data?, env: [String: String]) async -> GitOutput
}

extension GitExecutor {
    public func git(_ args: [String], in dir: URL, input: Data? = nil) async -> GitOutput {
        await git(args, in: dir, input: input, env: [:])
    }
}

/// Plain `git` from PATH, never prompting for a password.
public struct ProcessGit: GitExecutor {
    public init() {}

    public func git(_ args: [String], in dir: URL, input: Data?, env extra: [String: String]) async -> GitOutput {
        #if os(Linux)
        // Foundation's Process leaks a descriptor into daemons git starts
        // (credential-cache), which would block us until they exit.
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["GIT_OPTIONAL_LOCKS"] = "0"
                env.merge(extra) { _, new in new }
                do {
                    let r = try Subprocess.run("/usr/bin/env", ["git"] + args, currentDirectory: dir.path,
                                               environment: env, input: input)
                    cont.resume(returning: GitOutput(stdout: r.stdout, stderr: r.stderr, exitCode: r.status))
                } catch {
                    cont.resume(returning: GitOutput(stdout: Data(), stderr: Data(error.localizedDescription.utf8), exitCode: -1))
                }
            }
        }
        #else
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = ["git"] + args
                p.currentDirectoryURL = dir
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["GIT_OPTIONAL_LOCKS"] = "0"
                p.environment = env.merging(extra) { _, new in new }
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                let inPipe = input.map { _ in Pipe() }
                p.standardInput = inPipe ?? FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: GitOutput(stdout: Data(), stderr: Data(error.localizedDescription.utf8), exitCode: -1))
                    return
                }
                if let inPipe, let input {
                    DispatchQueue.global().async {
                        try? inPipe.fileHandleForWriting.write(contentsOf: input)
                        try? inPipe.fileHandleForWriting.close()
                    }
                }
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: GitOutput(stdout: outData, stderr: errData, exitCode: p.terminationStatus))
            }
        }
        #endif
    }
}
