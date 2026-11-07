import Foundation
import GitCoworkCore

struct GitResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

struct GitError: LocalizedError {
    let command: String
    let result: GitResult

    var errorDescription: String? {
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if CredentialConfig.isAuthFailure(err) {
            return err + "\n\nThe server wants you to sign in. Add your account under git-cowork > Settings > Accounts (for SSH remotes, also Create SSH Key there), or set up an SSH key or credential helper for git."
        }
        if !err.isEmpty { return err }
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "git exited with code \(result.exitCode)" : out
    }
}

/// Runs the git CLI. Every call is a plain `git <args>` in the repo folder,
/// so behaviour matches the terminal: same config, SSH keys, credential
/// helpers and hooks. The one addition: hosts signed in under Settings >
/// Accounts get their token (and SSH key, if one was made) from the app
/// (see Credentials).
final class GitRunner: @unchecked Sendable {
    static let shared = GitRunner()

    private let lock = NSLock()
    private var env: [String: String]
    let gitPath: String

    private init() {
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        gitPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"

        var e = ProcessInfo.processInfo.environment
        // Apps started from Finder get a minimal PATH. Hooks (husky, lefthook,
        // lint-staged) need node etc., so start with the usual places and
        // replace with the login shell's PATH once we know it.
        let base = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        e["PATH"] = [e["PATH"], base].compactMap { $0 }.joined(separator: ":")
        e["GIT_TERMINAL_PROMPT"] = "0"     // fail instead of waiting for a password on a missing tty
        e["GIT_OPTIONAL_LOCKS"] = "0"      // `git status` must not touch the index (would retrigger file watching)
        e["GIT_EDITOR"] = "true"           // accept default messages (merge, rebase --continue)
        e["GIT_MERGE_AUTOEDIT"] = "no"
        #if os(Linux)
        e["LC_ALL"] = "C.UTF-8"            // always installed on Debian/Ubuntu; en_US.UTF-8 may not be
        #else
        e["LC_ALL"] = "en_US.UTF-8"
        #endif
        env = e

        Task.detached(priority: .utility) { [weak self] in self?.loadLoginShellPath() }
    }

    private func loadLoginShellPath() {
        #if os(Linux)
        // Desktop launchers start apps without the PATH set in ~/.profile or ~/.bashrc.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/bash"
        guard let r = try? Subprocess.run(shell, ["-l", "-c", "printf %s \"$PATH\""], timeout: 5), r.status == 0 else { return }
        let path = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.contains("/") else { return }
        lock.lock()
        env["PATH"] = path + ":" + (env["PATH"] ?? "")
        lock.unlock()
        #else
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        // Don't let a slow shell profile hang anything.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, path.contains("/") else { return }
        lock.lock()
        env["PATH"] = path + ":" + (env["PATH"] ?? "")
        lock.unlock()
        #endif
    }

    private var environment: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return env
    }

    /// Runs git and returns stdout. Throws `GitError` on an unexpected exit code.
    /// `logged` puts the command in the command log (use it for anything that
    /// changes the repo; reads would only add noise).
    @discardableResult
    func run(_ args: [String], in dir: URL, logged: Bool = false, okCodes: Set<Int32> = [0],
             input: Data? = nil, env extra: [String: String] = [:]) async throws -> String {
        let start = Date()
        let result = await execute(args, in: dir, input: input, env: extra)
        if logged {
            let entry = CommandLog.Entry(args: args, directory: dir, start: start,
                                         duration: Date().timeIntervalSince(start), result: result)
            await MainActor.run { CommandLog.shared.add(entry) }
        }
        guard okCodes.contains(result.exitCode) else {
            throw GitError(command: "git " + args.joined(separator: " "), result: result)
        }
        return result.stdout
    }

    /// Like `run` but never throws; for best-effort reads.
    func tryRun(_ args: [String], in dir: URL) async -> String? {
        let r = await execute(args, in: dir)
        return r.exitCode == 0 ? r.stdout : nil
    }

    /// `input` is written to git's stdin; `extra` adds environment variables
    /// (e.g. GIT_INDEX_FILE for writing trees without touching the real index).
    func execute(_ args: [String], in dir: URL, input: Data? = nil, env extra: [String: String] = [:]) async -> GitResult {
        let r = await executeData(args, in: dir, input: input, env: extra)
        return GitResult(stdout: String(decoding: r.stdout, as: UTF8.self),
                         stderr: String(decoding: r.stderr, as: UTF8.self),
                         exitCode: r.exitCode)
    }

    /// Like `execute`, but stdout stays raw bytes. Diffs need this: decoding
    /// non-UTF-8 content would corrupt patches built from it.
    func executeData(_ args: [String], in dir: URL, input: Data? = nil,
                     env extra: [String: String] = [:]) async -> (stdout: Data, stderr: Data, exitCode: Int32) {
        var env = environment.merging(extra) { _, new in new }
        let gitPath = gitPath
        let credentials = Credentials.shared
        if CredentialConfig.needsCredentials(args) {
            await credentials.prepare(gitPath: gitPath, env: env)
            // An SSH key made under Settings > Accounts, unless the person
            // already picked an ssh command themselves.
            if let ssh = credentials.sshCommand, env["GIT_SSH_COMMAND"] == nil, env["GIT_SSH"] == nil,
               await tryRun(["config", "--get", "core.sshCommand"], in: dir) == nil {
                env["GIT_SSH_COMMAND"] = ssh
            }
        }
        #if os(Linux)
        // The account's SSH key: its passphrase comes from the Secret Service
        // through the app's askpass helper (no UseKeychain on Linux).
        if let ssh = credentials.sshCommand, env["GIT_SSH_COMMAND"] == ssh {
            env.merge(credentials.sshAskpassEnvironment) { _, new in new }
        }
        #endif
        let processEnv = env
        let configArgs = GitDefaults.configArgs + credentials.configArgs
        #if os(Linux)
        // Subprocess, not Foundation's Process: that one leaks a descriptor into
        // daemons git starts (credential-cache, ssh ControlMaster) and would wait for them.
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let r = try Subprocess.run(gitPath, configArgs + args, currentDirectory: dir.path,
                                               environment: processEnv, input: input)
                    cont.resume(returning: (r.stdout, r.stderr, r.status))
                } catch {
                    cont.resume(returning: (Data(), Data(error.localizedDescription.utf8), -1))
                }
            }
        }
        #else
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: gitPath)
                p.arguments = configArgs + args
                p.currentDirectoryURL = dir
                p.environment = processEnv
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                let inPipe = input.map { _ in Pipe() }
                p.standardInput = inPipe ?? FileHandle.nullDevice
                do {
                    try p.run()
                } catch {
                    cont.resume(returning: (Data(), Data(error.localizedDescription.utf8), -1))
                    return
                }
                if let inPipe, let input {
                    // Write on another thread so a large input can't deadlock against git's output.
                    DispatchQueue.global(qos: .userInitiated).async {
                        try? inPipe.fileHandleForWriting.write(contentsOf: input)
                        try? inPipe.fileHandleForWriting.close()
                    }
                }
                // Read both pipes at once so a full stderr buffer can't block git.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: (outData, errData, p.terminationStatus))
            }
        }
        #endif
    }
}
