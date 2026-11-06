import GitCoworkCore
import SwiftUI

/// Task board (center area when centerMode == .board): a header with filters,
/// then one column per status. Cards drag between and within columns.
struct BoardView: View {
    let model: RepoModel

    @AppStorage("board.mineOnly") private var mineOnly = false
    @State private var labelFilter: String?
    @State private var query = ""
    @State private var showAllDone = false
    @State private var dropSpot: DropSpot?
    @State private var draggingID: String?
    @FocusState private var boardFocused: Bool

    /// Done shows this many until "Show all".
    private static let doneLimit = 20

    enum DropSpot: Equatable {
        case card(String)
        case column(TaskStatus)
    }

    var body: some View {
        let data = BoardData(store: model.cowork, mineOnly: mineOnly, label: labelFilter, query: query)
        VStack(spacing: 0) {
            header(data)
            Divider()
            if model.cowork.loaded && model.cowork.tasks.isEmpty {
                emptyState
            } else {
                columns(data)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Header

    private func header(_ data: BoardData) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text("Tasks")
                .font(InspectorStyle.headerFont)
            CountBadge(count: data.visibleCount)
                .padding(.trailing, Theme.Space.s)

            Picker("Show", selection: $mineOnly) {
                Text("Mine").tag(true)
                Text("All").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Show only tasks assigned to you")

            labelMenu(data.allLabels)

            Spacer(minLength: Theme.Space.m)

            searchField
            Button {
                model.sheet = .newTask(status: .todo)
            } label: {
                Label("New Task", systemImage: "plus")
            }
            .buttonStyle(ActionButtonStyle.primary())
            .help("New task in To Do (N)")
        }
        .padding(.horizontal, Theme.Metrics.panelPadding)
        .frame(height: Theme.Metrics.panelHeaderHeight)
    }

    private func labelMenu(_ labels: [String]) -> some View {
        Menu {
            Button("All Labels") { labelFilter = nil }
            if !labels.isEmpty { Divider() }
            ForEach(labels, id: \.self) { label in
                Toggle(label, isOn: Binding(
                    get: { labelFilter == label },
                    set: { labelFilter = $0 ? label : nil }))
            }
        } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "tag").font(.system(size: 9, weight: .bold))
                Text(labelFilter ?? "Labels")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .actionButtonLabel(tint: labelFilter == nil ? nil : .accentColor)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(labels.isEmpty && labelFilter == nil)
        .help("Filter by label")
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search tasks", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Font.small)
                .onExitCommand { query = ""; boardFocused = true }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(minWidth: 100, idealWidth: 200, maxWidth: 200)
        .frame(height: Theme.Metrics.buttonHeight)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Color(nsColor: .separatorColor)))
    }

    // MARK: Columns

    private func columns(_ data: BoardData) -> some View {
        GeometryReader { geo in
            let inset = Theme.Metrics.panelPadding
            let gap = Self.columnGap
            let count = CGFloat(TaskStatus.allCases.count)
            let width = max(Self.minColumnWidth, (geo.size.width - inset * 2 - gap * (count - 1)) / count)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        column(status, data: data)
                            .frame(width: width)
                    }
                }
                .padding(inset)
                .frame(height: geo.size.height)
            }
            .scrollIndicators(.automatic)
        }
        .contentShape(Rectangle())
        .onTapGesture { boardFocused = true }
        .focusable()
        .focusEffectDisabled()
        .focused($boardFocused)
        .onKeyPress("n") {
            model.sheet = .newTask(status: .todo)
            return .handled
        }
        .onKeyPress(.upArrow) { moveSelection(data, dx: 0, dy: -1) }
        .onKeyPress(.downArrow) { moveSelection(data, dx: 0, dy: 1) }
        .onKeyPress(.leftArrow) { moveSelection(data, dx: -1, dy: 0) }
        .onKeyPress(.rightArrow) { moveSelection(data, dx: 1, dy: 0) }
        .onKeyPress(.escape) {
            guard model.coworkSelection != nil else { return .ignored }
            model.coworkSelection = nil
            return .handled
        }
    }

    /// Small enough that all five columns fit next to the sidebar and the
    /// inspector at the default window size; narrower than this, the board scrolls.
    private static let minColumnWidth: CGFloat = 164
    private static let columnGap: CGFloat = Theme.Space.m

    private func column(_ status: TaskStatus, data: BoardData) -> some View {
        let all = data.columns[status] ?? []
        let limited = status == .done && !showAllDone && all.count > Self.doneLimit
        let shown = limited ? Array(all.prefix(Self.doneLimit)) : all
        let targeted = dropSpot == .column(status) || dropSpot.map { spot in
            if case .card(let id) = spot { return data.statusByID[id] == status }
            return false
        } ?? false

        return VStack(spacing: 0) {
            columnHeader(status, count: all.count)
            ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { t in
                        card(t, data: data).id(t.id)
                    }
                    if status == .done && all.count > Self.doneLimit {
                        Button(showAllDone ? "Show fewer" : "Show all \(all.count)") { showAllDone.toggle() }
                            .buttonStyle(.link)
                            .font(Theme.Font.small)
                            .padding(.vertical, Theme.Space.s)
                    }
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.bottom, Theme.Space.m)
            }
            .scrollIndicators(.automatic)
            // Keep the selected card visible when moving with the arrow keys.
            .onChange(of: model.coworkSelection) { _, sel in
                guard case .task(let id) = sel, data.statusByID[id] == status else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius + 2)
                .fill(targeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius + 2)
                .strokeBorder(Color.accentColor.opacity(dropSpot == .column(status) ? 0.6 : 0), lineWidth: 1.5))
        .dropDestination(for: String.self) { ids, _ in
            defer { endDrag() }
            guard let id = ids.first else { return false }
            return BoardActions.drop(id, into: status, onto: nil, model: model)
        } isTargeted: { inside in
            if inside { dropSpot = .column(status) } else if dropSpot == .column(status) { dropSpot = nil }
        }
    }

    private func columnHeader(_ status: TaskStatus, count: Int) -> some View {
        HStack(spacing: Theme.Space.s + Theme.Space.xs) {
            Image(systemName: status.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(status.color)
                .frame(width: 14)
            Text(status.title)
                .font(Theme.Font.body.weight(.semibold))
                .lineLimit(1)
            CountBadge(count: count)
            Spacer(minLength: 0)
            Button {
                model.sheet = .newTask(status: status)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: Theme.Metrics.chipHeight, height: Theme.Metrics.chipHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("New task in \(status.title)")
        }
        // Icon lines up with the card titles below.
        .padding(.leading, Theme.Space.m + BoardCard.accentWidth + Theme.Metrics.cardPadding)
        .padding(.trailing, Theme.Space.s)
        .frame(height: Theme.Metrics.panelHeaderHeight)
    }

    private func card(_ t: CoworkTask, data: BoardData) -> some View {
        let spot = dropSpot == .card(t.id) && draggingID != t.id
        // Dragging down inside the same column drops below the target.
        let below = spot && draggingID.flatMap { d in
            guard data.statusByID[d] == t.status, let a = data.indexByID[d], let b = data.indexByID[t.id] else { return nil }
            return a < b
        } == true

        return BoardCard(
            task: t,
            assignee: data.person(t.assignee),
            verdict: data.verdict(for: t),
            comments: data.commentCount(t),
            selected: model.coworkSelection == .task(t.id)
        )
        .equatable()
        .onTapGesture {
            model.coworkSelection = .task(t.id)
            boardFocused = true
        }
        .contextMenu { BoardCardMenu(model: model, task: t) }
        .draggable(dragPayload(t.id))
        .overlay(alignment: below ? .bottom : .top) {
            if spot {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .offset(y: below ? Self.cardGap / 2 + 1 : -(Self.cardGap / 2 + 1))
                    .allowsHitTesting(false)
            }
        }
        .padding(.bottom, Self.cardGap)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { ids, _ in
            defer { endDrag() }
            guard let id = ids.first else { return false }
            return BoardActions.drop(id, into: t.status, onto: t.id, model: model)
        } isTargeted: { inside in
            if inside { dropSpot = .card(t.id) } else if dropSpot == .card(t.id) { dropSpot = nil }
        }
    }

    private static let cardGap: CGFloat = Theme.Space.m

    /// Called by SwiftUI when a drag starts; remembers which card is moving.
    private func dragPayload(_ id: String) -> String {
        DispatchQueue.main.async { draggingID = id }
        return id
    }

    private func endDrag() {
        dropSpot = nil
        draggingID = nil
    }

    // MARK: Keyboard

    private func moveSelection(_ data: BoardData, dx: Int, dy: Int) -> KeyPress.Result {
        let statuses = TaskStatus.allCases
        let visible: [[CoworkTask]] = statuses.map { s in
            let all = data.columns[s] ?? []
            return s == .done && !showAllDone ? Array(all.prefix(Self.doneLimit)) : all
        }
        guard case .task(let id) = model.coworkSelection,
              let col = visible.firstIndex(where: { $0.contains { $0.id == id } }),
              let row = visible[col].firstIndex(where: { $0.id == id }) else {
            if let first = visible.first(where: { !$0.isEmpty })?.first {
                model.coworkSelection = .task(first.id)
                return .handled
            }
            return .ignored
        }
        if dy != 0 {
            let r = row + dy
            guard visible[col].indices.contains(r) else { return .handled }
            model.coworkSelection = .task(visible[col][r].id)
            return .handled
        }
        var c = col + dx
        while visible.indices.contains(c), visible[c].isEmpty { c += dx }
        guard visible.indices.contains(c) else { return .handled }
        model.coworkSelection = .task(visible[c][min(row, visible[c].count - 1)].id)
        return .handled
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No tasks yet")
                .font(Theme.Font.body.weight(.medium))
            Text("Tasks are stored in this repository on refs/cowork/main and sync with your teammates through the remote.")
                .font(Theme.Font.small)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Create First Task") { model.sheet = .newTask(status: .todo) }
                .buttonStyle(ActionButtonStyle.primary())
                .padding(.top, Theme.Space.s)
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { boardFocused = true }
        .focusable()
        .focusEffectDisabled()
        .focused($boardFocused)
        .onKeyPress("n") {
            model.sheet = .newTask(status: .todo)
            return .handled
        }
    }
}

/// Everything the board shows, worked out once per render: filtered columns
/// and lookup tables, so cards don't search the store themselves.
@MainActor
struct BoardData {
    var columns: [TaskStatus: [CoworkTask]] = [:]
    var statusByID: [String: TaskStatus] = [:]
    var indexByID: [String: Int] = [:]
    var allLabels: [String] = []
    var visibleCount = 0
    private var people: [String: TeamMember] = [:]
    private var verdictByBranch: [String: ReviewVerdict] = [:]
    private var comments: [String: [CoworkComment]] = [:]

    init(store: CoworkStore, mineOnly: Bool, label: String?, query: String) {
        let snapshot = store.snapshot
        let me = store.me.id
        let q = query.trimmingCharacters(in: .whitespaces)
        var labels = Set<String>()
        var grouped: [TaskStatus: [CoworkTask]] = [:]
        for t in snapshot.tasks {
            labels.formUnion(t.labels)
            if mineOnly && t.assignee?.lowercased() != me { continue }
            if let label, !t.labels.contains(label) { continue }
            if !BoardLogic.matches(t, query: q) { continue }
            grouped[t.status, default: []].append(t)
        }
        for s in TaskStatus.allCases {
            let list = BoardLogic.sorted(grouped[s] ?? [], status: s)
            columns[s] = list
            visibleCount += list.count
            for (i, t) in list.enumerated() {
                statusByID[t.id] = s
                indexByID[t.id] = i
            }
        }
        allLabels = labels.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for p in store.people { people[p.id] = p }
        for r in snapshot.reviews where r.status == .open {
            verdictByBranch[r.branch] = r.overall
        }
        comments = snapshot.comments
    }

    func person(_ email: String?) -> TeamMember? {
        guard let email, !email.isEmpty else { return nil }
        return people[email.lowercased()]
            ?? TeamMember(handle: String(email.split(separator: "@").first ?? ""), name: email, email: email)
    }

    func verdict(for t: CoworkTask) -> ReviewVerdict? {
        if let b = t.branch, !b.isEmpty, let v = verdictByBranch[b] { return v }
        return nil
    }

    func commentCount(_ t: CoworkTask) -> Int { comments[t.commentParent]?.count ?? 0 }
}
