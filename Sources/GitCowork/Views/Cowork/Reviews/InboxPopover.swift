import GitCoworkCore
import SwiftUI

/// Content of the toolbar inbox popover: things teammates did that concern me.
/// Clicking an item opens it on the board or in the review list and marks it read.
struct InboxPopover: View {
    let model: RepoModel

    @State private var seen: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    private var repoKey: String { model.mainWorktreePath ?? model.root.path }
    private var store: CoworkStore { model.cowork }

    var body: some View {
        let items = store.inbox
        let unread = items.filter { !seen.contains($0.id) }.count
        VStack(spacing: 0) {
            PanelBar {
                Text("Inbox").font(Theme.Font.headline)
                if unread > 0 {
                    Text(verbatim: "\(unread) new")
                        .font(Theme.Font.small.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Button("Mark All as Read") { markSeen(items.map(\.id)) }
                    .buttonStyle(.link)
                    .font(Theme.Font.small)
                    .disabled(unread == 0)
            }
            if items.isEmpty {
                EmptyState(symbol: "tray", title: "Nothing new",
                           message: "Assignments, review requests, @mentions and comments on your things show up here.")
                    .frame(height: 220)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            InboxRow(item: item, unread: !seen.contains(item.id), actor: store.person(item.actor)) {
                                open(item)
                            }
                        }
                    }
                    .padding(.vertical, Theme.Space.s)
                }
                .frame(maxHeight: 420)
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { seen = CoworkNotifier.shared.seen(repo: repoKey) }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            if store.syncing {
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            } else if let error = store.syncError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Sync failed").help(error)
            } else if let last = store.lastSync {
                Text("Synced \(Formatters.relative(last))").help(Formatters.full(last))
            } else {
                Text(model.defaultRemote == nil ? "No remote: tasks stay on this Mac" : "Not synced yet")
            }
            Spacer()
            Button("Sync Now") { Task { await model.syncCowork() } }
                .buttonStyle(.link)
                .disabled(store.syncing || model.defaultRemote == nil)
        }
        .font(Theme.Font.small)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Metrics.panelPadding)
        .frame(height: Theme.Metrics.rowHeight + Theme.Space.m)
    }

    private func markSeen(_ ids: [String]) {
        CoworkNotifier.shared.markSeen(ids, repo: repoKey)
        seen.formUnion(ids)
    }

    private func open(_ item: InboxItem) {
        markSeen([item.id])
        openCoworkTarget(item.target, model: model)
        dismiss()
    }
}

private struct InboxRow: View {
    let item: InboxItem
    let unread: Bool
    let actor: TeamMember?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Circle()
                    .fill(unread ? Color.accentColor : .clear)
                    .frame(width: 6, height: 6)
                    .padding(.top, 7)
                ZStack(alignment: .bottomTrailing) {
                    PersonAvatar(person: actor, size: 24)
                    Image(systemName: symbol)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(color, in: Circle())
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: 4, y: 4)
                }
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                        Text(item.title)
                            .font(Theme.Font.body.weight(unread ? .semibold : .regular))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Text(Formatters.relative(item.date))
                            .font(Theme.Font.small)
                            .foregroundStyle(.secondary)
                            .help(Formatters.full(item.date))
                    }
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(Theme.Font.small)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.leading, Theme.Space.m)
            .padding(.trailing, Theme.Metrics.panelPadding)
            .padding(.vertical, Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverFillStyle.row)
    }

    private var symbol: String {
        switch item.kind {
        case .assigned: "person.fill"
        case .reviewRequested: "eye.fill"
        case .reviewVerdict: item.id.hasSuffix(ReviewVerdict.approved.rawValue) ? "checkmark" : "exclamationmark"
        case .mention: "at"
        case .comment: "text.bubble.fill"
        }
    }

    private var color: Color {
        switch item.kind {
        case .assigned: TaskStatus.doing.color
        case .reviewRequested: TaskStatus.review.color
        case .reviewVerdict: item.id.hasSuffix(ReviewVerdict.approved.rawValue) ? ReviewVerdict.approved.color : ReviewVerdict.changesRequested.color
        case .mention: Color.accentColor
        case .comment: Color(nsColor: .systemGray)
        }
    }
}
