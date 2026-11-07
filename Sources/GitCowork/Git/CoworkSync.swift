import CoworkKit
import Foundation
import GitCoworkCore

/// Syncing refs/cowork/main with the remote (fetch, merge, push in CoworkRepo).
extension CoworkStore {
    func schedulePush() {
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    /// Fetch the remote's cowork ref, merge with ours, push the result.
    /// Calls queue up behind a running sync, so when this returns a full
    /// sync has happened after the call.
    func sync() async {
        let previous = syncChain
        let task = Task { @MainActor in
            await previous?.value
            await syncOnce()
        }
        syncChain = task
        await task.value
    }

    func syncOnce() async {
        guard let remote else { await reload(); return }
        syncing = true
        defer { syncing = false }
        do {
            if try await repo.sync(remote: remote) {
                syncError = nil
                lastSync = Date()
            } else {
                syncError = L("Couldn't push cowork changes: the remote kept moving. Will retry.")
            }
        } catch {
            syncError = error.localizedDescription
        }
        await reload()
    }
}

/// The app's git runner (login-shell PATH, signed-in accounts) for CoworkRepo.
struct AppGit: GitExecutor {
    func git(_ args: [String], in dir: URL, input: Data?, env: [String: String]) async -> GitOutput {
        let r = await GitRunner.shared.executeData(args, in: dir, input: input, env: env)
        return GitOutput(stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode)
    }
}
