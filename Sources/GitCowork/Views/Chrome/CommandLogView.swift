import SwiftUI

/// Every git command the app ran that changed something, with its output.
struct CommandLogView: View {
    let root: URL
    @State private var onlyThisRepo = true
    private let log = CommandLog.shared

    private var entries: [CommandLog.Entry] {
        onlyThisRepo ? log.entries.filter { $0.directory == root } : log.entries
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Command log", count: entries.count) {
                Toggle("This worktree only", isOn: $onlyThisRepo)
                    .toggleStyle(.checkbox)
                    .font(Theme.Font.small)
                Button("Clear") { log.clear() }
                    .buttonStyle(.link)
                    .font(Theme.Font.small)
            }
            .frame(height: Theme.Metrics.panelHeaderHeight)
            Divider()
            if entries.isEmpty {
                EmptyState(symbol: "terminal", title: "No commands yet",
                           message: "Fetch, push, commit and other actions show up here with git's output.")
            } else {
                ScrollViewReader { proxy in
                    List(entries) { e in
                        LogRow(entry: e).id(e.id)
                    }
                    .listStyle(.plain)
                    .onAppear { proxy.scrollTo(entries.last?.id, anchor: .bottom) }
                    .onChange(of: entries.count) { proxy.scrollTo(entries.last?.id, anchor: .bottom) }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct LogRow: View {
    let entry: CommandLog.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: entry.succeeded ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(entry.succeeded ? Color.green : Color.red)
                Text("$ " + entry.commandLine)
                    .font(Theme.Font.mono)
                    .textSelection(.enabled)
                Spacer()
                Text(entry.directory.lastPathComponent).foregroundStyle(.tertiary)
                Text(String(format: "%.2fs", entry.duration)).foregroundStyle(.tertiary)
                Text(entry.start, style: .time).foregroundStyle(.tertiary)
            }
            .font(Theme.Font.small)
            if !entry.output.isEmpty {
                Text(entry.output)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(entry.succeeded ? .secondary : Color.red)
                    .textSelection(.enabled)
                    .padding(.leading, 22)
            }
        }
        .padding(.vertical, 2)
    }
}
