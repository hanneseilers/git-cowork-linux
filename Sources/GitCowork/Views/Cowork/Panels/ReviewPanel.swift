import GitCoworkCore
import SwiftUI

/// Right panel for a selected review request: branch → base, verdicts,
/// my review actions, the files changed on the branch, and the comment thread.
struct ReviewPanel: View {
    let model: RepoModel
    let reviewID: String

    var body: some View {
        if let review = model.cowork.review(reviewID) {
            ReviewPanelContent(model: model, review: review)
                .id(reviewID)
        } else {
            VStack(spacing: 0) {
                CoworkPanelBar { TaskIDText(id: reviewID); Spacer() }
                EmptyState(symbol: "checkmark.bubble", title: "Review not found",
                           message: model.cowork.loaded ? "It may have been removed by a teammate." : nil)
            }
        }
    }
}

/// "Open" / "Closed" capsule.
struct ReviewStateChip: View {
    let status: ReviewStatus
    var body: some View {
        switch status {
        case .open: Chip(text: "Open", symbol: "circle", color: .accentColor)
        case .closed: Chip(text: "Closed", symbol: "lock", color: .secondary)
        }
    }
}

private struct ReviewPanelContent: View {
    let model: RepoModel
    let review: ReviewRequest

    @State private var sending = false
    @State private var changes = BranchChanges()

    private var store: CoworkStore { model.cowork }
    /// Unsent review note, kept in the store so a selection change doesn't drop it.
    private var note: String {
        get { store.drafts["note:" + review.id] ?? "" }
        nonmutating set { store.drafts["note:" + review.id] = newValue.isEmpty ? nil : newValue }
    }
    private var me: String { store.me.id }
    private var isRequester: Bool { review.requester.lowercased() == me }
    private var myVerdict: ReviewVerdict? {
        review.reviewers.first { $0.key.lowercased() == me }?.value
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.sectionGap) {
                    summary
                    people
                    if review.status == .open, myVerdict != nil { myReview }
                    links
                    Divider()
                    changesList
                    Divider()
                    CommentList(model: model, parent: review.commentParent)
                }
                .padding(Theme.Metrics.panelPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            CommentComposer(model: model, parent: review.commentParent)
        }
        .task(id: changesKey) { changes = await model.branchChanges(branch: review.branch, base: review.base) }
    }

    // MARK: Header

    private var header: some View {
        CoworkPanelBar {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: Theme.Space.s) {
                Text(review.branch).foregroundStyle(.primary)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                Text(review.base).foregroundStyle(.secondary)
            }
            .font(Theme.Font.mono)
            .lineLimit(1)
            .truncationMode(.middle)
            .help("\(review.branch) into \(review.base)")
            Spacer(minLength: Theme.Space.s)
            VerdictChip(verdict: review.overall)
            ReviewStateChip(status: review.status)
            Menu {
                Button("Copy Branch Name") { External.copy(review.branch) }
                Button("Copy Review ID") { External.copy(review.id) }
                if isRequester {
                    Divider()
                    if review.status == .open {
                        Button("Close Review") { setStatus(.closed) }
                    } else {
                        Button("Reopen Review") { setStatus(.open) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(review.title)
                .font(InspectorStyle.subjectFont)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !review.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MentionText(text: review.body.trimmingCharacters(in: .whitespacesAndNewlines), handles: store.mentionHandles)
            }
            HStack(spacing: Theme.Space.s) {
                PersonAvatar(person: store.person(review.requester), size: 14)
                Text("Requested by \(displayName(review.requester, in: store)) · \(Formatters.relative(review.created))")
                    .help(Formatters.full(review.created))
            }
            .font(Theme.Font.small)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    // MARK: Reviewers

    private var sortedReviewers: [(email: String, verdict: ReviewVerdict)] {
        review.reviewers.map { ($0.key, $0.value) }
            .sorted { displayName($0.email, in: store).localizedCaseInsensitiveCompare(displayName($1.email, in: store)) == .orderedAscending }
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            CoworkSectionTitle(title: "Reviewers", count: review.reviewers.count) {
                if isRequester && review.status == .open { addReviewerMenu }
            }
            if review.reviewers.isEmpty {
                Text("Nobody asked yet.").font(Theme.Font.small).foregroundStyle(.secondary)
                    .frame(minHeight: Theme.Metrics.rowHeight)
            }
            ForEach(sortedReviewers, id: \.email) { r in
                HStack(spacing: Theme.Space.m) {
                    PersonAvatar(person: store.person(r.email), size: 20)
                    Text(displayName(r.email, in: store)).lineLimit(1)
                    Spacer(minLength: Theme.Space.s)
                    VerdictChip(verdict: r.verdict)
                }
                .font(Theme.Font.body)
                .frame(height: Theme.Metrics.rowHeight)
                .contextMenu {
                    if isRequester {
                        Button("Remove Reviewer") {
                            let key = r.email.lowercased()
                            Task { await store.updateReview(review.id) { rv in rv.reviewers = rv.reviewers.filter { $0.key.lowercased() != key } } }
                        }
                    }
                }
            }
            linkedTask
        }
    }

    private var addReviewerMenu: some View {
        let candidates = store.people.filter { p in
            p.id != review.requester.lowercased() && !review.reviewers.keys.contains { $0.lowercased() == p.id }
        }
        return Menu {
            ForEach(candidates) { p in
                Button {
                    let key = p.id   // lowercased, like the verdicts written by setVerdict
                    Task {
                        await store.updateReview(review.id) { rv in
                            if !rv.reviewers.keys.contains(where: { $0.lowercased() == key }) { rv.reviewers[key] = .requested }
                        }
                    }
                } label: {
                    Label { Text(p.displayName) } icon: { menuPersonIcon(p) }
                }
            }
        } label: {
            Label("Add", systemImage: "plus")
                .font(Theme.Font.small.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(candidates.isEmpty)
        .help("Add reviewer")
    }

    @ViewBuilder
    private var linkedTask: some View {
        if let id = review.taskID {
            let task = store.task(id)
            Button {
                openCoworkTarget("tasks/\(id)", model: model)
            } label: {
                HStack(spacing: Theme.Space.m) {
                    Text("Task").font(Theme.Font.small).foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                    TaskIDText(id: id)
                    Text(task?.title ?? "Not found")
                        .foregroundStyle(task == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.s)
                    if let task { StatusChip(status: task.status) }
                    Image(systemName: "chevron.right").font(Theme.Glyph.chevron).foregroundStyle(.tertiary)
                }
                .font(Theme.Font.body)
                .frame(height: Theme.Metrics.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, Theme.Space.s)
            .help("Open task")
        }
    }

    // MARK: My review

    private var myReview: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            CoworkSectionTitle(title: "Your review") {
                if let v = myVerdict, v != .requested {
                    Text("You: \(v.title.lowercased())").font(Theme.Font.small).foregroundStyle(.secondary)
                }
            }
            TextField("Add a note (optional)", text: Binding(get: { note }, set: { note = $0 }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
            HStack(spacing: Theme.Space.m) {
                Button { verdict(.approved) } label: { Label("Approve", systemImage: "checkmark") }
                    .buttonStyle(ActionButtonStyle.primary(ReviewVerdict.approved.color))
                Button { verdict(.changesRequested) } label: { Label("Request Changes", systemImage: "exclamationmark") }
                    .buttonStyle(ActionButtonStyle.secondary(ReviewVerdict.changesRequested.color))
                Button("Comment") { verdict(.commented) }
                    .buttonStyle(ActionButtonStyle.secondary())
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer(minLength: 0)
                if sending { ProgressView().controlSize(.small) }
            }
            .disabled(sending)
        }
        .padding(Theme.Metrics.cardPadding)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.cardBorder))
    }

    private func verdict(_ v: ReviewVerdict) {
        guard let latest = store.review(review.id) else { return }
        let text = note
        sending = true
        note = ""
        let key = "note:" + latest.id
        Task {
            if await store.setVerdict(v, on: latest, comment: text) == false, (store.drafts[key] ?? "").isEmpty {
                store.drafts[key] = text.isEmpty ? nil : text
            }
            sending = false
        }
    }

    private func setStatus(_ s: ReviewStatus) {
        let id = review.id
        Task { await store.updateReview(id) { $0.status = s } }
    }

    // MARK: Links

    @ViewBuilder
    private var links: some View {
        let branch = model.branch(named: review.branch)
        let web = model.links(for: nil)
        let pr = web?.newPullRequestURL(branch: review.branch, base: review.base)
        if branch != nil || pr != nil {
            ChipFlow(spacing: Theme.Space.s) {
                if let branch {
                    Button("Show in History") {
                        model.openDiff = nil
                        model.centerMode = .history
                        model.reveal(branch.target)
                    }
                    if model.currentBranch != review.branch {
                        Button("Checkout") { Task { await model.checkout(branch) } }
                            .disabled(model.busy != nil)
                    }
                }
                if let web, let pr {
                    Button { External.browse(pr) } label: {
                        Label("Open \(web.pullRequestTerm) on \(web.host)", systemImage: "arrow.up.right.square")
                    }
                    .help(pr.absoluteString)
                }
            }
            .buttonStyle(ActionButtonStyle.secondary())
        }
    }

    // MARK: Changes

    /// Reloads when the branch or base tip moves.
    private var changesKey: String {
        func targets(_ name: String) -> String {
            let local = model.localBranches.first { $0.name == name }?.target ?? ""
            let remote = model.remoteBranch(named: name)?.target ?? ""
            return "\(name)@\(local)/\(remote)"
        }
        return targets(review.branch) + "|" + targets(review.base)
    }

    private static let fileLimit = 300

    private var changesList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            CoworkSectionTitle(title: "Changes", count: changes.loaded ? changes.files.count : nil) {
                if changes.loaded, changes.error == nil {
                    Text("since \(review.base)").font(Theme.Font.small).foregroundStyle(.secondary)
                }
            }
            if !changes.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: Theme.Metrics.rowHeight)
            } else if let error = changes.error {
                Text(error).font(Theme.Font.small).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if changes.files.isEmpty {
                Text("No changes between \(review.base) and \(review.branch).")
                    .font(Theme.Font.small).foregroundStyle(.secondary)
            } else if let detail = changes.detail {
                VStack(spacing: 0) {
                    ForEach(changes.files.prefix(Self.fileLimit)) { f in
                        changeRow(f, detail: detail)
                    }
                }
                .padding(.horizontal, -Theme.Space.s)
                if changes.files.count > Self.fileLimit {
                    Text("and \(changes.files.count - Self.fileLimit) more files")
                        .font(Theme.Font.small).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func changeRow(_ f: FileChange, detail: CommitDetail) -> some View {
        let selected: Bool = {
            if case .commit(let d, let file) = model.openDiff { return d.id == detail.id && d.parents == detail.parents && file.id == f.id }
            return false
        }()
        return Button { model.openDiff = .commit(detail, f) } label: {
            FileRow(change: f)
                .padding(.horizontal, Theme.Space.s)
                .frame(height: Theme.Metrics.rowHeight)
                .contentShape(Rectangle())
                .background(selected ? Color.accentColor.opacity(Theme.Tint.selection) : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
        }
        .buttonStyle(HoverRowStyle())
        .help(f.path)
    }
}
