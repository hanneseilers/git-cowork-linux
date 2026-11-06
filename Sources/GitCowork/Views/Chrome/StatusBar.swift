import SwiftUI

/// Bottom bar. Left: what's running or what last ran.
/// Right: paused background fetch, task sync, upstream sync, commit count, worktree path, command log toggle.
struct StatusBar: View {
    @Bindable var model: RepoModel
    private let log = CommandLog.shared

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            activity
            Spacer(minLength: Theme.Space.l)
            AutoFetchStatus(model: model)
            CoworkSyncStatus(model: model)
            upstream
            Text(commitCount)
                .foregroundStyle(.tertiary)
            Text(abbreviated(model.root.path))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 360, alignment: .trailing)
                .foregroundStyle(.secondary)
                .help(model.root.path)
            Button {
                model.showCommandLog.toggle()
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(model.showCommandLog ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(model.showCommandLog ? "Hide command log (⌘J)" : "Show command log (⌘J)")
        }
        .font(Theme.Font.small)
        .padding(.horizontal, Theme.Metrics.panelPadding)
        .frame(height: Theme.Metrics.rowHeight)   // lines up with list rows above
        .background(.bar)
    }

    @ViewBuilder
    private var activity: some View {
        if let busy = model.busy {
            HStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.mini)
                Text("\(busy)…")
            }
        } else if let last = log.entries.last(where: { $0.directory == model.root }) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: last.succeeded ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(last.succeeded ? Color.secondary : Color.red)
                Text(last.commandLine)
                    .font(Theme.Font.monoSmall)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(String(format: "%.1fs", last.duration))
                    .foregroundStyle(.tertiary)
            }
            .help(last.succeeded ? last.commandLine : last.output)
        }
    }

    /// "↑2 ↓1 origin/main", or a note when the branch has no upstream.
    @ViewBuilder
    private var upstream: some View {
        if let up = model.status.upstream {
            HStack(spacing: Theme.Space.s) {
                if model.status.ahead == 0 && model.status.behind == 0 {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tertiary)
                } else {
                    AheadBehind(ahead: model.status.ahead, behind: model.status.behind)
                }
                Text(up).foregroundStyle(.secondary)
            }
            .help(syncHelp(up))
        } else if model.currentBranch != nil {
            Text("No upstream").foregroundStyle(.tertiary)
        }
    }

    private func syncHelp(_ up: String) -> String {
        let s = model.status
        if s.ahead == 0 && s.behind == 0 { return "Up to date with \(up)" }
        return "\(s.ahead) ahead, \(s.behind) behind \(up)"
    }

    private var commitCount: String {
        let count = model.commits.count
        let n = count.formatted()
        if model.hasMoreCommits { return "\(n)+ commits" }
        return count == 1 ? "1 commit" : "\(n) commits"
    }

    private func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// "Tasks synced 2m ago", a spinner while syncing, or a warning with the
/// error as tooltip. Click to sync now.
private struct CoworkSyncStatus: View {
    let model: RepoModel

    var body: some View {
        let store = model.cowork
        Button {
            Task { await model.syncCowork() }
        } label: {
            HStack(spacing: Theme.Space.s) {
                if store.syncing {
                    ProgressView().controlSize(.mini)
                } else if store.syncError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Status.warning)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.tertiary)
                }
                label(store)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(store.syncing)
        .help(help(store))
    }

    @ViewBuilder
    private func label(_ store: CoworkStore) -> some View {
        if store.syncError != nil {
            Text("Task sync failed")
        } else if let last = store.lastSync {
            // Re-renders once a minute so "2m ago" stays true; nothing else ticks.
            TimelineView(.periodic(from: last, by: 60)) { context in
                Text(Self.synced(last, now: context.date))
            }
        } else if store.syncing {
            Text("Syncing tasks…")
        } else {
            Text("Tasks not synced")
        }
    }

    static func synced(_ date: Date, now: Date) -> String {
        "Tasks synced \(Formatters.relative(date, now: now))"
    }

    private func help(_ store: CoworkStore) -> String {
        if let error = store.syncError { return "Task sync failed: \(error)\nClick to try again." }
        let remote = store.remote.map { " with \($0)" } ?? " (no remote: tasks stay on this Mac)"
        if let last = store.lastSync { return "Tasks and reviews synced\(remote) at \(Formatters.full(last)). Click to sync now." }
        return "Sync tasks and reviews\(remote) now"
    }
}

/// Shown only when background fetching paused because signing in failed.
/// Click to fetch now (which also resumes it once it works).
private struct AutoFetchStatus: View {
    let model: RepoModel

    var body: some View {
        if let reason = model.autoFetchPaused {
            Button {
                Task { await model.fetch() }
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Status.warning)
                    Text("Auto-fetch paused")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.busy != nil)
            .help("Automatic fetch couldn't sign in and stopped, so it doesn't retry with the same credentials:\n\(reason)\n\nClick to fetch now. It resumes after you sign in under Settings › Accounts or a fetch, pull or push works.")
        }
    }
}
