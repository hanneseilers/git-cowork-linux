import GitCoworkCore
import SwiftUI

/// Links from the inspector into the shared tasks and reviews.
extension RepoModel {
    /// Tasks linked to any of these branch names.
    func inspectorTasks(branches: Set<String>) -> [CoworkTask] {
        guard !branches.isEmpty else { return [] }
        return cowork.tasks.filter { t in t.branch.map { branches.contains($0) } ?? false }
    }

    /// Open review requests for any of these branch names.
    func inspectorReviews(branches: Set<String>) -> [ReviewRequest] {
        guard !branches.isEmpty else { return [] }
        return cowork.reviews.filter { $0.status == .open && branches.contains($0.branch) }
    }

    func showTask(_ id: String) {
        centerMode = .board
        coworkSelection = .task(id)
    }

    func showReview(_ id: String) {
        centerMode = .reviews
        coworkSelection = .review(id)
    }
}

/// Branch names a ref may be linked by: "feat/x" for both the local branch and
/// "origin/feat/x".
func linkableBranchNames(_ refs: [Ref]) -> Set<String> {
    var names = Set<String>()
    for r in refs {
        switch r.kind {
        case .localBranch:
            names.insert(r.name)
        case .remoteBranch:
            names.insert(r.name)
            if let slash = r.name.firstIndex(of: "/") { names.insert(String(r.name[r.name.index(after: slash)...])) }
        case .tag:
            break
        }
    }
    return names
}

/// "Task   [In Progress] CW-a3f9 Cache sessions" — one compact clickable row.
struct CoworkLinkRow<Chip: View>: View {
    let label: String
    var id: String?
    let title: String
    let help: String
    @ViewBuilder var chip: Chip
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Text(label)
                    .font(Theme.Font.small)
                    .foregroundStyle(.secondary)
                    .frame(width: InspectorStyle.linkLabelWidth, alignment: .leading)
                chip.fixedSize()
                if let id { TaskIDText(id: id).fixedSize() }
                Text(title)
                    .font(Theme.Font.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .underline(hovering)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(height: Theme.Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Task and review rows for a set of branches. Empty when nothing is linked.
struct CoworkLinks: View {
    let model: RepoModel
    let branches: Set<String>

    var body: some View {
        let tasks = model.inspectorTasks(branches: branches)
        let reviews = model.inspectorReviews(branches: branches)
        if !tasks.isEmpty || !reviews.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(tasks) { t in
                    CoworkLinkRow(label: "Task", id: t.id, title: t.title,
                                  help: "Show \(t.id) on the board") {
                        StatusChip(status: t.status)
                    } action: { model.showTask(t.id) }
                }
                ForEach(reviews) { r in
                    CoworkLinkRow(label: "Review", title: r.title,
                                  help: "Show the review of \(r.branch)") {
                        VerdictChip(verdict: r.overall)
                    } action: { model.showReview(r.id) }
                }
            }
        }
    }
}
