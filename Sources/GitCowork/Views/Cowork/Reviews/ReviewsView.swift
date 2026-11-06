import GitCoworkCore
import SwiftUI

/// Review requests list (center area when centerMode == .reviews).
struct ReviewsView: View {
    let model: RepoModel

    enum Filter: String, CaseIterable, Identifiable {
        case waiting, mine, open, closed
        var id: String { rawValue }

        var title: String {
            switch self {
            case .waiting: "Waiting for me"
            case .mine: "Mine"
            case .open: "All open"
            case .closed: "Closed"
            }
        }
    }

    static let filterKey = "reviews.filter"
    @AppStorage(ReviewsView.filterKey) private var filterRaw = Filter.waiting.rawValue

    private var filter: Filter { Filter(rawValue: filterRaw) ?? .waiting }
    private var store: CoworkStore { model.cowork }

    /// Switches the list filter so `review` is visible (keeps the current one if it already is).
    @MainActor
    static func showFilter(for review: ReviewRequest, store: CoworkStore) {
        let current = Filter(rawValue: UserDefaults.standard.string(forKey: filterKey) ?? "") ?? .waiting
        if matches(review, current, me: store.me.id) { return }
        let next = Filter.allCases.first { matches(review, $0, me: store.me.id) } ?? .open
        UserDefaults.standard.set(next.rawValue, forKey: filterKey)
    }

    /// Repositories whose filter was already settled this session: picked by
    /// the user, by navigation, or by `settleDefaultFilter` once.
    @MainActor private static var settledFilter: Set<String> = []

    /// The first time the list shows for a repo, "Waiting for me" with nothing
    /// in it while other reviews are open switches to "All open". Never
    /// overrides a choice made in this session.
    private func settleDefaultFilter() {
        let key = model.root.path
        guard store.loaded, !Self.settledFilter.contains(key) else { return }
        Self.settledFilter.insert(key)
        if filter == .waiting, reviews(.waiting).isEmpty, !reviews(.open).isEmpty {
            filterRaw = Filter.open.rawValue
        }
    }

    private var filterSelection: Binding<String> {
        Binding(get: { filterRaw }, set: { new in
            Self.settledFilter.insert(model.root.path)
            filterRaw = new
        })
    }

    private static func matches(_ r: ReviewRequest, _ f: Filter, me: String) -> Bool {
        switch f {
        case .waiting:
            r.status == .open && r.requester.lowercased() != me
                && r.reviewers.contains { $0.key.lowercased() == me && ($0.value == .requested || $0.value == .commented) }
        case .mine: r.status == .open && r.requester.lowercased() == me
        case .open: r.status == .open
        case .closed: r.status == .closed
        }
    }

    private func reviews(_ f: Filter) -> [ReviewRequest] {
        let me = store.me.id
        return store.reviews.filter { Self.matches($0, f, me: me) }.sorted { $0.updated > $1.updated }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { if case .review(let id) = model.coworkSelection { id } else { nil } },
            set: { id in
                if let id { model.coworkSelection = .review(id) }
                else if case .review = model.coworkSelection { model.coworkSelection = nil }
            })
    }

    var body: some View {
        let items = reviews(filter)
        VStack(spacing: 0) {
            header
            if !store.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                empty
            } else {
                List(selection: selection) {
                    ForEach(items) { r in
                        ReviewRow(review: r, store: store, comments: store.comments(on: r.commentParent).count)
                            .tag(r.id)
                            .listRowInsets(EdgeInsets())
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { settleDefaultFilter() }
        .onChange(of: store.loaded) { settleDefaultFilter() }
    }

    private var header: some View {
        CoworkPanelBar {
            Text("Reviews").font(InspectorStyle.headerFont)
            Spacer(minLength: Theme.Space.m)
            Picker("Filter", selection: filterSelection) {
                ForEach(Filter.allCases) { f in
                    let n = f == .closed ? 0 : reviews(f).count
                    Text(n > 0 ? "\(f.title) \(n)" : f.title).tag(f.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Spacer(minLength: Theme.Space.m)
            Button {
                if let b = model.currentBranch { model.sheet = .requestReview(branch: b) }
            } label: {
                Label("Request Review", systemImage: "plus")
            }
            .buttonStyle(ActionButtonStyle.primary())
            .disabled(model.currentBranch == nil)
            .help(model.currentBranch.map { "Ask teammates to review \($0)" } ?? "Check out a branch first")
        }
    }

    @ViewBuilder
    private var empty: some View {
        switch filter {
        case .waiting:
            EmptyState(symbol: "checkmark.bubble", title: "Nothing waiting for you",
                       message: "Review requests from teammates show up here.")
        case .mine:
            EmptyState(symbol: "arrow.triangle.branch", title: "No open requests from you",
                       message: "Right-click a branch and choose Request Review, or use the button above.")
        case .open:
            EmptyState(symbol: "checkmark.bubble", title: "No open reviews")
        case .closed:
            EmptyState(symbol: "lock", title: "No closed reviews")
        }
    }
}

/// Two-line row: branch → base and verdict; title, people, comments and age.
private struct ReviewRow: View {
    let review: ReviewRequest
    let store: CoworkStore
    let comments: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(review.branch).font(Theme.Font.mono.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                Text(review.base).font(Theme.Font.mono).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: Theme.Space.m)
                if review.status == .closed {
                    ReviewStateChip(status: .closed)
                } else {
                    VerdictChip(verdict: review.overall)
                }
            }
            HStack(spacing: Theme.Space.m) {
                Text(review.title).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: Theme.Space.m)
                PersonAvatar(person: store.person(review.requester), size: 16)
                if !review.reviewers.isEmpty {
                    Image(systemName: "arrow.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    HStack(spacing: Theme.Space.xs) {
                        ForEach(review.reviewers.keys.sorted(), id: \.self) { email in
                            ReviewerAvatar(person: store.person(email), verdict: review.reviewers[email] ?? .requested)
                        }
                    }
                }
                if comments > 0 {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "text.bubble").font(.system(size: 9))
                        Text(verbatim: "\(comments)")
                    }
                    .foregroundStyle(.secondary)
                    .help("\(comments) comments")
                }
                Text(Formatters.relative(review.updated))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 48, alignment: .trailing)
                    .help("Updated \(Formatters.full(review.updated))")
            }
            .font(Theme.Font.small)
        }
        .font(Theme.Font.body)
        .padding(.vertical, Theme.Space.m)
        .padding(.horizontal, Theme.Space.s)
    }
}

/// Avatar with a small verdict-colored dot at the bottom right.
private struct ReviewerAvatar: View {
    let person: TeamMember?
    let verdict: ReviewVerdict

    var body: some View {
        PersonAvatar(person: person, size: 16)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(verdict.color)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(Color(nsColor: .textBackgroundColor), lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
            .help("\(person?.displayName ?? "Unknown"): \(verdict.title)")
    }
}
