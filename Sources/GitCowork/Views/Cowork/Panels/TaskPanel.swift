import GitCoworkCore
import SwiftUI

/// Right panel for a selected task: title, status, assignee, labels, linked
/// branch, description and comments. Every change is one commit on the cowork
/// ref, so text fields save on Enter / when they lose focus (the description
/// also a few seconds after typing stops), never per keystroke.
struct TaskPanel: View {
    let model: RepoModel
    let taskID: String

    var body: some View {
        if let task = model.cowork.task(taskID) {
            TaskPanelContent(model: model, task: task)
                .id(taskID)
        } else {
            VStack(spacing: 0) {
                PanelBar { TaskIDText(id: taskID); Spacer() }
                EmptyState(symbol: "checklist", title: "Task not found",
                           message: model.cowork.loaded ? "It may have been deleted by a teammate." : nil)
            }
        }
    }
}

private struct TaskPanelContent: View {
    let model: RepoModel
    let task: CoworkTask

    private enum Field: Hashable { case title, body }

    @State private var title = ""
    @State private var bodyText = ""
    @State private var bodySave: Task<Void, Never>?
    /// What this view last wrote, so a save that fires twice (Enter, then the
    /// focus change; blur, then disappear) writes once.
    @State private var savedTitle = ""
    @State private var savedBody = ""
    @State private var copied = false
    @FocusState private var focus: Field?

    private var store: CoworkStore { model.cowork }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.sectionGap) {
                    titleField
                    properties
                    description
                    meta
                    Divider()
                    CommentList(model: model, parent: task.commentParent)
                }
                .padding(Theme.Metrics.panelPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            CommentComposer(model: model, parent: task.commentParent)
        }
        .onAppear {
            title = task.title
            bodyText = task.body
            savedTitle = task.title
            savedBody = task.body
        }
        .onChange(of: task) { _, t in
            // A teammate's edit arrived: take it unless the field is being edited.
            if focus != .title { title = t.title; savedTitle = t.title }
            if focus != .body && bodySave == nil { bodyText = t.body; savedBody = t.body }
        }
        .onChange(of: focus) { old, _ in
            if old == .title { saveTitle() }
            if old == .body { saveBody() }
        }
        .onDisappear {
            saveTitle()
            saveBody()
        }
    }

    // MARK: Header

    private var header: some View {
        PanelBar {
            TaskIDText(id: task.id)
            Spacer()
            if copied {
                Text("Copied").font(Theme.Font.small).foregroundStyle(.secondary)
            }
            Menu {
                Button("Copy ID") { copy(task.id) }
                Button("Copy Title") { copy("\(task.id) \(task.title)") }
                if let branch = task.branch {
                    Button("Copy Branch Name") { copy(branch) }
                }
                Divider()
                Button("Delete Task…", role: .destructive) { confirmDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }

    private func copy(_ s: String) {
        External.copy(s)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    private func confirmDelete() {
        let t = task
        model.confirmation = Confirmation(
            title: String(localized: "Delete \(t.id)?"),
            message: String(localized: "“\(t.title)” and its comments are removed for everyone on the next sync. Linked branches are kept."),
            confirmTitle: "Delete Task"
        ) {
            await model.cowork.deleteTask(t)
            if model.coworkSelection == .task(t.id) { model.coworkSelection = nil }
        }
    }

    // MARK: Title

    private var titleField: some View {
        TextField("Task title", text: $title, axis: .vertical)
            .textFieldStyle(.plain)
            .font(InspectorStyle.subjectFont)
            .lineLimit(1...4)
            .focused($focus, equals: .title)
            .onSubmit { focus = nil }   // the focus change saves
    }

    private func saveTitle() {
        let t = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { title = task.title; return }
        title = t
        guard t != savedTitle else { return }
        savedTitle = t
        update { $0.title = t }
    }

    // MARK: Properties

    private var properties: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            PropertyRow(label: "Status") {
                StatusMenu(status: task.status) { s in update { $0.status = s } }
            }
            PropertyRow(label: "Assignee") {
                AssigneeMenu(store: store, assignee: task.assignee) { a in update { $0.assignee = a } }
            }
            PropertyRow(label: "Labels") {
                LabelEditor(labels: task.labels, known: store.allLabels,
                            onAdd: { new in update { t in t.labels += new.filter { n in !t.labels.contains { $0.lowercased() == n.lowercased() } } } },
                            onRemove: { l in update { $0.labels.removeAll { $0 == l } } })
                    .padding(.vertical, Theme.Space.s)
            }
            PropertyRow(label: "Branch") {
                TaskBranchRow(model: model, task: task) { b in update { $0.branch = b } }
                    .padding(.vertical, Theme.Space.s)
            }
        }
    }

    // MARK: Description

    private var description: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Description") {
                if bodySave != nil {
                    Text("Saving…").font(Theme.Font.small).foregroundStyle(.tertiary)
                }
            }
            PlaceholderEditor(text: $bodyText, placeholder: "Add a description",
                              minHeight: 80, focused: focus == .body)
                .focused($focus, equals: .body)
                .onChange(of: bodyText) { _, new in
                    guard new != savedBody else { return }
                    scheduleBodySave()
                }
            if focus == .body {
                MentionSuggestions(text: $bodyText, people: store.people)
            }
        }
    }

    private func scheduleBodySave() {
        bodySave?.cancel()
        bodySave = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            saveBody()
        }
    }

    private func saveBody() {
        bodySave?.cancel()
        bodySave = nil
        let b = bodyText
        guard b != savedBody else { return }
        savedBody = b
        update { $0.body = b }
    }

    // MARK: Meta

    private var meta: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                PersonAvatar(person: store.person(task.author), size: 14)
                Text("Created by \(displayName(task.author, in: store)) · \(Formatters.full(task.created))")
            }
            Text("Updated \(Formatters.relative(task.updated))")
                .help(Formatters.full(task.updated))
        }
        .font(Theme.Font.small)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    // MARK: Writing

    /// The store applies the change to the stored copy of the task at write
    /// time (not the one this view was built with), so concurrent edits to
    /// other fields survive.
    private func update(_ change: @escaping (inout CoworkTask) -> Void) {
        let id = task.id
        Task { await store.updateTask(id, change) }
    }
}

/// Linked branch with its actions, or "Start Task" / link an existing branch.
private struct TaskBranchRow: View {
    let model: RepoModel
    let task: CoworkTask
    let onLink: (String?) -> Void
    @Environment(\.windowActions) private var windowActions

    var body: some View {
        if let branch = task.branch {
            linked(branch)
        } else {
            unlinked
        }
    }

    private func linked(_ branch: String) -> some View {
        let ref = model.branch(named: branch)
        let isHead = model.currentBranch == branch
        return VStack(alignment: .leading, spacing: Theme.Space.s + 2) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: isHead ? "checkmark" : "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHead ? Color.accentColor : .secondary)
                Text(branch)
                    .font(Theme.Font.mono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if ref == nil {
                    Text("not found").font(Theme.Font.small).foregroundStyle(.orange)
                        .help("No local or remote branch with this name. Fetch, or link another branch.")
                }
                Spacer(minLength: 0)
                Button { onLink(nil) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Unlink branch")
            }
            FlowRow {
                if let ref, !isHead {
                    Button("Checkout") { Task { await model.checkout(ref) } }
                }
                if let ref {
                    Button("Show in History") {
                        model.openDiff = nil
                        model.centerMode = .history
                        model.reveal(ref.target)
                    }
                    if let wt = model.worktree(of: task), wt.path != model.root.path {
                        Button("Open Worktree") { windowActions?.open(wt.path) }
                    } else if model.worktree(of: task) == nil {
                        Button("Open in New Worktree") { model.startTaskInWorktree(task.id) { windowActions?.open($0) } }
                            .help("Check out \(branch) in its own folder and open it in a new tab")
                    }
                    Button("Request Review…") { model.sheet = .requestReview(branch: branch) }
                }
            }
            .buttonStyle(ActionButtonStyle.secondary())
            .disabled(model.busy != nil)
        }
    }

    private var unlinked: some View {
        HStack(spacing: Theme.Space.s) {
            Button { model.startTask(task.id) } label: { Label("Start Task", systemImage: "play.fill") }
                .buttonStyle(ActionButtonStyle.primary())
                .help("Check out \(RefName.branch(for: task)) here (created if needed), then link it")
            Button { model.startTaskInWorktree(task.id) { windowActions?.open($0) } } label: {
                Label("In New Worktree", systemImage: "folder.badge.plus")
            }
            .buttonStyle(ActionButtonStyle.secondary())
            .help("Create \(RefName.branch(for: task)) in its own folder and open it in a new tab, e.g. for an agent")
            Menu {
                ForEach(model.localBranches) { b in
                    Button(b.name) { onLink(b.name) }
                }
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Text("Link Branch")
                    Image(systemName: "chevron.down").font(Theme.Glyph.dropdown)
                }
                .actionButtonLabel()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.localBranches.isEmpty)
            .help("Link an existing local branch")
        }
        .disabled(model.busy != nil)
    }
}
