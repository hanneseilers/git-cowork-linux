import GitCoworkCore
import SwiftUI

/// The Clone sheet's list of the signed-in accounts' repos. Picking one fills
/// in its HTTPS URL; double-clicking clones it.
struct CloneRepoList: View {
    let accounts: [HostAccount]
    @Binding var url: String
    let onOpen: (String) -> Void

    @State private var host: String
    @State private var loaded: [String: [HostRepo]] = [:]
    @State private var errors: [String: String] = [:]
    @State private var filter = ""
    @State private var selection: HostRepo.ID?

    init(accounts: [HostAccount], url: Binding<String>, onOpen: @escaping (String) -> Void) {
        self.accounts = accounts
        _url = url
        self.onOpen = onOpen
        _host = State(initialValue: accounts.first?.host ?? "")
    }

    private var account: HostAccount? { accounts.first { $0.host == host } ?? accounts.first }
    private var all: [HostRepo]? { account.flatMap { loaded[$0.host] } }
    private var shown: [HostRepo] { (all ?? []).filter { $0.matches(filter) } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("Your Repositories").font(Theme.Font.caption).foregroundStyle(.secondary)
                Spacer()
                if accounts.count > 1 {
                    Picker("Account", selection: $host) {
                        ForEach(accounts) { Text(label($0)).tag($0.host) }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else if let account {
                    Text(label(account)).foregroundStyle(.secondary)
                }
            }
            .font(Theme.Font.small)
            TextField("Filter repositories", text: $filter)
                .textFieldStyle(.roundedBorder)
                .onExitCommand { filter = "" }
            List(shown, selection: $selection) { repo in
                CloneRepoRow(repo: repo).listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, Theme.Metrics.rowHeight)
            .contextMenu(forSelectionType: HostRepo.ID.self, menu: { _ in }) { ids in
                if let id = ids.first, let repo = all?.first(where: { $0.id == id }) { onOpen(repo.cloneURL) }
            }
            .overlay { status }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.cardBorder))
        }
        .task(id: host) { await load() }
        .onChange(of: host) { selection = nil }
        .onChange(of: selection) {
            if let selection, let repo = all?.first(where: { $0.id == selection }) { url = repo.cloneURL }
        }
        .onChange(of: url) {
            // Typing a different URL drops the highlighted repo.
            if let selection, all?.first(where: { $0.id == selection })?.cloneURL != url { self.selection = nil }
        }
    }

    /// Plain text for loading, errors and empty results, as in the other sheets.
    @ViewBuilder private var status: some View {
        if let account {
            if let error = errors[account.host] {
                VStack(spacing: Theme.Space.m) {
                    Text(error).font(Theme.Font.small).foregroundStyle(.red).multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Button("Try Again") {
                        errors[account.host] = nil
                        Task { await load() }
                    }
                    .controlSize(.small)
                }
                .padding(Theme.Space.l)
            } else if all == nil {
                Text("Loading repositories…").font(Theme.Font.small).foregroundStyle(.secondary)
            } else if all?.isEmpty == true {
                Text("No repositories on \(account.host)").font(Theme.Font.small).foregroundStyle(.secondary)
            } else if shown.isEmpty {
                Text("No matches").font(Theme.Font.small).foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ account: HostAccount) -> String { "\(account.username) on \(account.host)" }

    private func load() async {
        guard let account, loaded[account.host] == nil, errors[account.host] == nil else { return }
        do {
            loaded[account.host] = try await RepoList.fetch(for: account)
        } catch is CancellationError {
            // The sheet closed or the account changed; the next .task loads again.
        } catch {
            errors[account.host] = error.localizedDescription
        }
    }
}

private struct CloneRepoRow: View {
    let repo: HostRepo

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: repo.isPrivate ? "lock" : "book.closed")
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .help(repo.isPrivate ? "Private" : "Public")
            Text(repo.fullPath).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Theme.Space.m)
            if let date = repo.updatedAt {
                Text(Formatters.relative(date))
                    .font(Theme.Font.small)
                    .foregroundStyle(.secondary)
                    .help(Formatters.full(date))
            }
        }
        .font(Theme.Font.body)
        .help(repo.cloneURL)
    }
}
